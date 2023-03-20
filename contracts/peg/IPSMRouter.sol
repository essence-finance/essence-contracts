pragma solidity ^0.8.4;

import "./IPegStabilityModule.sol";
import "../chi/IChi.sol";

interface IPSMRouter {
    // ---------- View-Only API ----------

    /// @notice reference to the PegStabilityModule that this router interacts with
    function psm() external returns (IPegStabilityModule);

    /// @notice reference to the CHI contract used.
    function chi() external returns (IChi);

    /// @notice calculate the amount of CHI out for a given `amountIn` of underlying
    function getMintAmountOut(uint256 amountIn) external view returns (uint256 amountChiOut);

    /// @notice calculate the amount of underlying out for a given `amountChiIn` of CHI
    function getRedeemAmountOut(uint256 amountChiIn) external view returns (uint256 amountOut);

    /// @notice the maximum mint amount out
    function getMaxMintAmountOut() external view returns (uint256);

    /// @notice the maximum redeem amount out
    function getMaxRedeemAmountOut() external view returns (uint256);

    // ---------- State-Changing API ----------

    /// @notice Mints chi to the given address, with a minimum amount required
    /// @dev This wraps ETH and then calls into the PSM to mint the chi. We return the amount of chi minted.
    /// @param _to The address to mint chi to
    /// @param _minAmountOut The minimum amount of chi to mint
    function mint(
        address _to,
        uint256 _minAmountOut,
        uint256 ethAmountIn
    ) external payable returns (uint256);

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
    ) external returns (uint256 amountOut);
}
