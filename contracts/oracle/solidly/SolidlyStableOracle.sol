// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../IOracle.sol";
import "../../refs/CoreRef.sol";
import "./IRouter.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IPair {

    function pairFee() external view returns (uint256);
}

/// @title oracle wrapper for tokens with no oracle
/// @notice Reads quote from router & wrap it under the standard Essence oracle interface
contract StableOracleWrapper is IOracle, CoreRef {
    using Decimal for Decimal.D256;
    using Math for uint256;

    /// @notice the router
    IRouter public router;
    /// @notice the token to price
    address public tokenA;
    /// @notice the base assest which token is priced in
    address public tokenB;
    /// @notice the pool address for the pair
    address public poolAddress;
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
        address _poolAddress,
        uint256 _CONVERSION_MULTI,
        bool _stable
    ) CoreRef(_core) {
        router = IRouter(_router);
        tokenA = address(_tokenA);
        tokenB = address(_tokenB);
        poolAddress = address(_poolAddress);
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
        uint256 one = 1e18/CONVERSION_MULTI;
        uint256 poolFee = IPair(poolAddress).pairFee();
        (uint256 amount,) = router.getAmountOut(
            one,
            address(tokenB),
            address(tokenA)
        );
        uint256 outAccountingForFee = amount + ((poolFee).mulDiv(one*CONVERSION_MULTI, 1e18));
        bool valid = !paused();

        Decimal.D256 memory value = Decimal.ratio((one * CONVERSION_MULTI),outAccountingForFee);
        return (value, valid);
    }
}
