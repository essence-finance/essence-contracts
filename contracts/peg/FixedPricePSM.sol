pragma solidity ^0.8.4;

import "./PriceBoundPSM.sol";

contract FixedPricePSM is PriceBoundPSM {
    using Decimal for Decimal.D256;

    constructor(
        uint256 _floor,
        uint256 _ceiling,
        OracleParams memory _params,
        uint256 _mintFeeBasisPoints,
        uint256 _redeemFeeBasisPoints,
        uint256 _reservesThreshold,
        uint256 _chiLimitPerSecond,
        uint256 _mintingBufferCap,
        IERC20 _underlyingToken,
        IPCVDeposit _surplusTarget
    )
        PriceBoundPSM(
            _floor,
            _ceiling,
            _params,
            _mintFeeBasisPoints,
            _redeemFeeBasisPoints,
            _reservesThreshold,
            _chiLimitPerSecond,
            _mintingBufferCap,
            _underlyingToken,
            _surplusTarget
        )
    {}

    // ----------- Internal Methods -----------

    /// @notice helper function to get mint amount out based on current market prices
    /// @dev will revert if price is outside of bounds and bounded PSM is being used
    function _getMintAmountOut(uint256 amountIn) internal view virtual override returns (uint256 amountChiOut) {
        Decimal.D256 memory price = readOracle();
        _validatePriceRange(price);

        amountChiOut = Decimal
            .one()
            .mul(amountIn)
            .mul(Constants.BASIS_POINTS_GRANULARITY - mintFeeBasisPoints)
            .div(Constants.BASIS_POINTS_GRANULARITY)
            .asUint256();
    }

    /// @notice helper function to get redeem amount out based on current market prices
    /// @dev will revert if price is outside of bounds and bounded PSM is being used
    function _getRedeemAmountOut(uint256 amountChiIn) internal view virtual override returns (uint256 amountTokenOut) {
        Decimal.D256 memory price = readOracle();
        _validatePriceRange(price);

        amountTokenOut = Decimal
            .one()
            .mul(amountChiIn)
            .mul(Constants.BASIS_POINTS_GRANULARITY - redeemFeeBasisPoints)
            .div(Constants.BASIS_POINTS_GRANULARITY)
            .asUint256();
    }
}
