// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../../utils/RateLimited.sol";

/// @title abstract contract for putting a rate limit on how fast a contract can mint CHI
abstract contract RateLimitedMinter is RateLimited {
    uint256 private constant MAX_CHI_LIMIT_PER_SECOND = 10_000e18; // 10000 CHI/s or ~860m CHI/day

    constructor(
        uint256 _chiLimitPerSecond,
        uint256 _mintingBufferCap,
        bool _doPartialMint
    ) RateLimited(MAX_CHI_LIMIT_PER_SECOND, _chiLimitPerSecond, _mintingBufferCap, _doPartialMint) {}

    /// @notice override the CHI minting behavior to enforce a rate limit
    function _mintChi(address to, uint256 amount) internal virtual override {
        uint256 mintAmount = _depleteBuffer(amount);
        super._mintChi(to, mintAmount);
    }
}
