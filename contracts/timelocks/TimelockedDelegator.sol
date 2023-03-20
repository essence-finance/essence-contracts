// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./ITimelockedDelegator.sol";
import "./LinearTokenTimelock.sol";

/// @title a proxy delegate contract for ZEN
contract Delegatee is Ownable {
    IZen public zen;

    /// @notice Delegatee constructor
    /// @param _delegatee the address to delegate ZEN to
    /// @param _zen the ZEN token address
    constructor(address _delegatee, address _zen) {
        zen = IZen(_zen);
        zen.delegate(_delegatee);
    }

    /// @notice send ZEN back to timelock and selfdestruct
    function withdraw() public onlyOwner {
        IZen _zen = zen;
        uint256 balance = _zen.balanceOf(address(this));
        _zen.transfer(owner(), balance);
        selfdestruct(payable(owner()));
    }
}

/// @title a timelock for ZEN allowing for sub-delegation
/// @notice allows the timelocked ZEN to be delegated by the beneficiary while locked
contract TimelockedDelegator is ITimelockedDelegator, LinearTokenTimelock {
    /// @notice associated delegate proxy contract for a delegatee
    mapping(address => address) public override delegateContract;

    /// @notice associated delegated amount of ZEN for a delegatee
    /// @dev Using as source of truth to prevent accounting errors by transferring to Delegate contracts
    mapping(address => uint256) public override delegateAmount;

    /// @notice the ZEN token contract
    IZen public override zen;

    /// @notice the total delegated amount of ZEN
    uint256 public override totalDelegated;

    /// @notice Delegatee constructor
    /// @param _zen the ZEN token address
    /// @param _beneficiary default delegate, admin, and timelock beneficiary
    /// @param _duration duration of the token timelock window
    constructor(
        address _zen,
        address _beneficiary,
        uint256 _duration
    ) LinearTokenTimelock(_beneficiary, _duration, _zen, 0, address(0), 0) {
        zen = IZen(_zen);
        zen.delegate(_beneficiary);
    }

    /// @notice delegate locked ZEN to a delegatee
    /// @param delegatee the target address to delegate to
    /// @param amount the amount of ZEN to delegate. Will increment existing delegated ZEN
    function delegate(address delegatee, uint256 amount) public override onlyBeneficiary {
        require(amount <= _zenBalance(), "TimelockedDelegator: Not enough Zen");

        // withdraw and include an existing delegation
        if (delegateContract[delegatee] != address(0)) {
            amount = amount + undelegate(delegatee);
        }

        IZen _zen = zen;
        address _delegateContract = address(new Delegatee(delegatee, address(_zen)));
        delegateContract[delegatee] = _delegateContract;

        delegateAmount[delegatee] = amount;
        totalDelegated = totalDelegated + amount;

        _zen.transfer(_delegateContract, amount);

        emit Delegate(delegatee, amount);
    }

    /// @notice return delegated ZEN to the timelock
    /// @param delegatee the target address to undelegate from
    /// @return the amount of ZEN returned
    function undelegate(address delegatee) public override onlyBeneficiary returns (uint256) {
        address _delegateContract = delegateContract[delegatee];
        require(_delegateContract != address(0), "TimelockedDelegator: Delegate contract nonexistent");

        Delegatee(_delegateContract).withdraw();

        uint256 amount = delegateAmount[delegatee];
        totalDelegated = totalDelegated - amount;

        delegateContract[delegatee] = address(0);
        delegateAmount[delegatee] = 0;

        emit Undelegate(delegatee, amount);

        return amount;
    }

    /// @notice calculate total ZEN held plus delegated
    /// @dev used by LinearTokenTimelock to determine the released amount
    function totalToken() public view override returns (uint256) {
        return _zenBalance() + totalDelegated;
    }

    /// @notice accept beneficiary role over timelocked ZEN. Delegates all held (non-subdelegated) zen to beneficiary
    function acceptBeneficiary() public override {
        _setBeneficiary(msg.sender);
        zen.delegate(msg.sender);
    }

    function _zenBalance() internal view returns (uint256) {
        return zen.balanceOf(address(this));
    }
}
