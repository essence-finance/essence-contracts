// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./IZenMinter.sol";
import "../utils/RateLimited.sol";
import "../Constants.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/** 
  @title implementation for a ZEN Minter Contract

  This contract will be the unique ZEN minting contract. 
  All minting is subject to an annual inflation rate limit.
  For example if circulating supply is 1m and inflation is capped at 10%, then no more than 100k ZEN can enter circulation in the following year.

  The contract will increase (decrease) the rate limit proportionally as supply increases (decreases)

  Governance and admins can only lower the max inflation %. 
  They can also exclude (unexclude) addresses' ZEN balances from the circulating supply. 
  The minter's balance is excluded by default.

  ACCESS_CONTROL:
  This contract follows a somewhat unique access control pattern. 
  It has a contract admin which is NOT intended for optimistic approval, but rather for contracts such as the ZenReserveStabilizer.
  An additional potential contract admin is one which automates the inclusion and removal of excluded deposits from on-chain timelocks.

  Additionally, the ability to transfer the zen minter role is held by the contract *owner* rather than governor or admin.
  The owner will intially be the DAO timelock.
  This keeps the power to transfer or burn ZEN minting rights isolated.
*/
contract ZenMinter is IZenMinter, RateLimited, Ownable {
    /// @notice the max inflation in ZEN circulating supply per year in basis points (1/10000)
    uint256 public override annualMaxInflationBasisPoints;

    /// @notice the zen treasury address used to exclude from circulating supply
    address public override zenTreasury;

    /// @notice the zen rewards dripper address used to exclude from circulating supply
    address public override zenRewardsDripper;

    /// @notice Zen Reserve Stabilizer constructor
    /// @param _core Essence Core to reference
    /// @param _annualMaxInflationBasisPoints the max inflation in ZEN circulating supply per year in basis points (1/10000)
    /// @param _owner the owner, capable of changing the zen minter address.
    /// @param _zenTreasury the zen treasury address used to exclude from circulating supply
    /// @param _zenRewardsDripper the zen rewards dripper address used to exclude from circulating supply
    constructor(
        address _core,
        uint256 _annualMaxInflationBasisPoints,
        address _owner,
        address _zenTreasury,
        address _zenRewardsDripper
    ) RateLimited(0, 0, 0, false) CoreRef(_core) {
        _setAnnualMaxInflationBasisPoints(_annualMaxInflationBasisPoints);
        poke();

        // start with a full buffer
        _resetBuffer();

        transferOwnership(_owner);

        if (_zenTreasury != address(0)) {
            zenTreasury = _zenTreasury;
            emit ZenTreasuryUpdate(address(0), _zenTreasury);
        }

        if (_zenRewardsDripper != address(0)) {
            zenRewardsDripper = _zenRewardsDripper;
            emit ZenRewardsDripperUpdate(address(0), _zenRewardsDripper);
        }
    }

    /// @notice update the rate limit per second and buffer cap
    function poke() public override {
        uint256 newBufferCap = idealBufferCap();
        uint256 oldBufferCap = bufferCap;
        require(newBufferCap != oldBufferCap, "ZenMinter: No rate limit change needed");

        _setBufferCap(newBufferCap);
        _setRateLimitPerSecond(newBufferCap / Constants.ONE_YEAR);
    }

    /// @dev no-op, reverts. Prevent admin or governor from overwriting ideal rate limit
    function setRateLimitPerSecond(uint256) external pure override {
        revert("no-op");
    }

    /// @dev no-op, reverts. Prevent admin or governor from overwriting ideal buffer cap
    function setBufferCap(uint256) external pure override {
        revert("no-op");
    }

    /// @notice mints ZEN to the target address, subject to rate limit
    /// @param to the address to send ZEN to
    /// @param amount the amount of ZEN to send
    function mint(address to, uint256 amount) external override onlyGovernor {
        // first apply rate limit
        _depleteBuffer(amount);

        // then mint
        _mint(to, amount);
    }

    /// @notice sets the new ZEN treasury address
    function setZenTreasury(address newZenTreasury) external override onlyGovernor {
        address oldZenTreasury = zenTreasury;
        zenTreasury = newZenTreasury;
        emit ZenTreasuryUpdate(oldZenTreasury, newZenTreasury);
    }

    /// @notice sets the new ZEN treasury rewards dripper
    function setZenRewardsDripper(address newZenRewardsDripper) external override onlyGovernor {
        address oldZenRewardsDripper = zenRewardsDripper;
        zenRewardsDripper = newZenRewardsDripper;
        emit ZenTreasuryUpdate(oldZenRewardsDripper, newZenRewardsDripper);
    }

    /// @notice changes the ZEN minter address
    /// @param newMinter the new minter address
    function setMinter(address newMinter) external override onlyOwner {
        require(newMinter != address(0), "ZenReserveStabilizer: zero address");
        IZen _zen = IZen(address(zen()));
        _zen.setMinter(newMinter);
    }

    /// @notice sets the max annual inflation relative to current supply
    /// @param newAnnualMaxInflationBasisPoints the new max inflation % denominated in basis points (1/10000)
    function setAnnualMaxInflationBasisPoints(uint256 newAnnualMaxInflationBasisPoints)
        external
        override
        onlyGovernor
    {
        _setAnnualMaxInflationBasisPoints(newAnnualMaxInflationBasisPoints);
    }

    /// @notice return the ideal buffer cap based on ZEN circulating supply
    function idealBufferCap() public view override returns (uint256) {
        return (zenCirculatingSupply() * annualMaxInflationBasisPoints) / Constants.BASIS_POINTS_GRANULARITY;
    }

    /// @notice return the ZEN supply, subtracting locked ZEN
    function zenCirculatingSupply() public view override returns (uint256) {
        IERC20 _zen = zen();

        // Remove all locked ZEN from total supply calculation
        uint256 lockedZen = _zen.balanceOf(address(this));

        if (zenTreasury != address(0)) {
            lockedZen += _zen.balanceOf(zenTreasury);
        }

        if (zenRewardsDripper != address(0)) {
            lockedZen += _zen.balanceOf(zenRewardsDripper);
        }

        return _zen.totalSupply() - lockedZen;
    }

    /// @notice alias for zenCirculatingSupply
    /// @dev for compatibility with ERC-20 standard for off-chain 3rd party sites
    function totalSupply() public view override returns (uint256) {
        return zenCirculatingSupply();
    }

    /// @notice return whether a poke is needed or not i.e. is buffer cap != ideal cap
    function isPokeNeeded() external view override returns (bool) {
        return idealBufferCap() != bufferCap;
    }

    // Transfer held ZEN first, then mint to cover remainder
    function _mint(address to, uint256 amount) internal {
        IZen _zen = IZen(address(zen()));

        uint256 _zenBalance = _zen.balanceOf(address(this));
        uint256 mintAmount = amount;

        // First transfer maximum amount of held ZEN
        if (_zenBalance != 0) {
            uint256 transferAmount = Math.min(_zenBalance, amount);

            _zen.transfer(to, transferAmount);

            mintAmount = mintAmount - transferAmount;
            assert(mintAmount + transferAmount == amount);
        }

        // Then mint if any more is needed
        if (mintAmount != 0) {
            _zen.mint(to, mintAmount);
        }
    }

    function _setAnnualMaxInflationBasisPoints(uint256 newAnnualMaxInflationBasisPoints) internal {
        uint256 oldAnnualMaxInflationBasisPoints = annualMaxInflationBasisPoints;
        require(newAnnualMaxInflationBasisPoints != 0, "ZenMinter: cannot have 0 inflation");

        // make sure the new inflation is strictly lower, unless the old inflation is 0 (which is only true upon construction)
        require(
            newAnnualMaxInflationBasisPoints < oldAnnualMaxInflationBasisPoints ||
                oldAnnualMaxInflationBasisPoints == 0,
            "ZenMinter: cannot increase max inflation"
        );

        annualMaxInflationBasisPoints = newAnnualMaxInflationBasisPoints;

        emit AnnualMaxInflationUpdate(oldAnnualMaxInflationBasisPoints, newAnnualMaxInflationBasisPoints);
    }
}
