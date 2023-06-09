// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./IPSMRouter.sol";
import "./PegStabilityModule.sol";
import "../Constants.sol";
import "../utils/RateLimited.sol";
import "../pcv/IPCVDepositBalances.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice the PSM router is an ungoverned, non custodial contract that allows user to seamlessly wrap and unwrap their WETH
/// for trading against the PegStabilityModule.
contract PSMRouter is IPSMRouter {
    using SafeERC20 for IERC20;

    /// @notice reference to the PegStabilityModule that this router interacts with
    IPegStabilityModule public immutable override psm;
    /// @notice reference to the CHI contract used. Does not reference core to save on gas
    /// Router can be redeployed if CHI address changes
    IChi public immutable override chi;

    constructor(IPegStabilityModule _psm, IChi _chi) {
        psm = _psm;
        chi = _chi;
        IERC20(address(Constants.WETH)).approve(address(_psm), type(uint256).max);
        _chi.approve(address(_psm), type(uint256).max);
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "PSMRouter: order expired");
        _;
    }

    // ----------- Public View-Only API ----------

    /// @notice view only pass through function to get amount of CHI out with given amount of ETH in
    function getMintAmountOut(uint256 amountIn) public view override returns (uint256 amountChiOut) {
        amountChiOut = psm.getMintAmountOut(amountIn);
    }

    /// @notice view only pass through function to get amount of ETH out with given amount of CHI in
    function getRedeemAmountOut(uint256 amountChiIn) public view override returns (uint256 amountTokenOut) {
        amountTokenOut = psm.getRedeemAmountOut(amountChiIn);
    }

    /// @notice the maximum mint amount out
    function getMaxMintAmountOut() external view override returns (uint256) {
        return psm.getMaxMintAmountOut();
    }

    /// @notice the maximum redeem amount out
    function getMaxRedeemAmountOut() external view override returns (uint256) {
        return IPCVDepositBalances(address(psm)).balance();
    }

    // ---------- Public State-Changing API ----------

    /// @notice Mints chi to the given address, with a minimum amount required
    /// @dev This wraps ETH and then calls into the PSM to mint the chi. We return the amount of chi minted.
    /// @param to The address to mint chi to
    /// @param minAmountOut The minimum amount of chi to mint
    function mint(
        address to,
        uint256 minAmountOut,
        uint256 ethAmountIn
    ) external payable override returns (uint256) {
        return _mint(to, minAmountOut, ethAmountIn);
    }

    /// @notice Mints chi to the given address, with a minimum amount required and a deadline
    /// @dev This wraps ETH and then calls into the PSM to mint the chi. We return the amount of chi minted.
    /// @param to The address to mint chi to
    /// @param minAmountOut The minimum amount of chi to mint
    /// @param deadline The deadline for this order to be filled
    function mint(
        address to,
        uint256 minAmountOut,
        uint256 deadline,
        uint256 ethAmountIn
    ) external payable ensure(deadline) returns (uint256) {
        return _mint(to, minAmountOut, ethAmountIn);
    }

    /// @notice Redeems chi for ETH
    /// First pull user CHI into this contract
    /// Then call redeem on the PSM to turn the CHI into weth
    /// Withdraw all weth to eth in the router
    /// Send the eth to the specified recipient
    /// @param to the address to receive the eth
    /// @param amountChiIn the amount of CHI to redeem
    /// @param minAmountOut the minimum amount of weth to receive
    function redeem(
        address to,
        uint256 amountChiIn,
        uint256 minAmountOut
    ) external override returns (uint256) {
        return _redeem(to, amountChiIn, minAmountOut);
    }

    /// @notice Redeems chi for ETH
    /// First pull user CHI into this contract
    /// Then call redeem on the PSM to turn the CHI into weth
    /// Withdraw all weth to eth in the router
    /// Send the eth to the specified recipient
    /// @param to the address to receive the eth
    /// @param amountChiIn the amount of CHI to redeem
    /// @param minAmountOut the minimum amount of weth to receive
    /// @param deadline The deadline for this order to be filled
    function redeem(
        address to,
        uint256 amountChiIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external ensure(deadline) returns (uint256) {
        return _redeem(to, amountChiIn, minAmountOut);
    }

    /// @notice function to receive ether from the weth contract when the redeem function is called
    /// will not accept eth unless there is an active redemption.
    fallback() external payable {
        require(msg.sender == address(Constants.WETH), "PSMRouter: fallback sender must be WETH contract");
    }

    // ---------- Internal Methods ----------

    /// @notice helper function to wrap eth and handle mint call to PSM
    function _mint(
        address _to,
        uint256 _minAmountOut,
        uint256 _ethAmountIn
    ) internal returns (uint256) {
        require(_ethAmountIn == msg.value, "PSMRouter: ethAmountIn and msg.value mismatch");
        Constants.WETH.deposit{value: msg.value}();
        return psm.mint(_to, msg.value, _minAmountOut);
    }

    /// @notice helper function to deposit user CHI, unwrap weth and send eth to the user
    /// the PSM router receives the weth, then sends it to the specified recipient.
    function _redeem(
        address to,
        uint256 amountChiIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        IERC20(chi).safeTransferFrom(msg.sender, address(this), amountChiIn);
        amountOut = psm.redeem(address(this), amountChiIn, minAmountOut);

        Constants.WETH.withdraw(amountOut);

        (bool success, ) = to.call{value: amountOut}("");
        require(success, "PSMRouter: eth transfer failed");
    }
}
