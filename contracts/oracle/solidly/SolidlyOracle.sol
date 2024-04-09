// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../IOracle.sol";
import "../../refs/CoreRef.sol";
import "./IRouter.sol";

/// @title oracle wrapper for tokens with no oracle
/// @notice Reads quote from router a oracle value & wrap it under the standard Essence oracle interface
contract OracleWrapper is IOracle, CoreRef {
    using Decimal for Decimal.D256;

    /// @notice the router
    IRouter public router;
    /// @notice the token to price
    address public tokenA;
    /// @notice the base assest which token is priced in
    address public tokenB;
    /// @notice conversion value for tokens with diff decimals
    uint public CONVERSION_MULTI;
    /// @notice if the pool is stable
    bool public stable;

    /// @notice OracleWrapper constructor
    /// @param _core Essence Core for reference
    constructor(
        address _core,
        address _router,
        address _tokenA,
        address _tokenB,
        uint256 _CONVERSION_MULTI,
        bool _stable
    ) CoreRef(_core) {
        router = IRouter(_router);
        tokenA = address(_tokenA);
        tokenB = address(_tokenB);
        CONVERSION_MULTI = _CONVERSION_MULTI;
        stable = _stable;
    }

    /// @notice updates the oracle price
    /// @dev no-op is updated automatically
    function update() external view override whenNotPaused {}

    /// @notice NO-OP
    /// @return false
    function isOutdated() external pure override returns (bool) {
        return false;
    }

    /// @notice read the oracle price
    /// @return oracle price
    /// @return true if price is valid
    function read() external view override returns (Decimal.D256 memory, bool) {
        uint256 liquidity = 0.01 ether;
        (uint256 amountA, uint256 amountB) = router.quoteRemoveLiquidity(
            address(tokenA),
            address(tokenB),
            stable,
            liquidity
        );
        bool valid = !paused();

        Decimal.D256 memory value = Decimal.ratio((amountB * CONVERSION_MULTI), amountA);
        return (value, valid);
    }
}
