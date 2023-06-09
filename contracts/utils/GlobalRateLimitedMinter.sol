// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import {MultiRateLimited} from "./MultiRateLimited.sol";
import {IGlobalRateLimitedMinter} from "./IGlobalRateLimitedMinter.sol";
import {CoreRef} from "./../refs/CoreRef.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice global contract to handle rate limited minting of Chi on a global level
/// allows whitelisted minters to call in and specify the address to mint Chi to within
/// that contract's limits
contract GlobalRateLimitedMinter is MultiRateLimited, IGlobalRateLimitedMinter {
    /// @param coreAddress address of the core contract
    /// @param _globalMaxRateLimitPerSecond maximum amount of Chi that can replenish per second ever, this amount cannot be changed by governance
    /// @param _perAddressRateLimitMaximum maximum rate limit per second per address
    /// @param _maxRateLimitPerSecondPerAddress maximum rate limit per second per address in multi rate limited
    /// @param _maxBufferCap maximum buffer cap in multi rate limited contract
    /// @param _globalBufferCap maximum global buffer cap
    constructor(
        address coreAddress,
        uint256 _globalMaxRateLimitPerSecond,
        uint256 _perAddressRateLimitMaximum,
        uint256 _maxRateLimitPerSecondPerAddress,
        uint256 _maxBufferCap,
        uint256 _globalBufferCap
    )
        CoreRef(coreAddress)
        MultiRateLimited(
            _globalMaxRateLimitPerSecond,
            _perAddressRateLimitMaximum,
            _maxRateLimitPerSecondPerAddress,
            _maxBufferCap,
            _globalBufferCap
        )
    {}

    /// @notice mint Chi to the target address and deplete the buffer
    /// pausable and depletes the msg.sender's buffer
    /// @param to the recipient address of the minted Chi
    /// @param amount the amount of Chi to mint
    function mint(address to, uint256 amount) external virtual override whenNotPaused {
        _depleteIndividualBuffer(msg.sender, amount);
        _mintChi(to, amount);
    }

    /// @notice mint Chi to the target address and deplete the whole rate limited
    ///  minter's buffer, pausable and completely depletes the msg.sender's buffer
    /// @param to the recipient address of the minted Chi
    /// mints all Chi that msg.sender has in the buffer
    function mintMaxAllowableChi(address to) external virtual override whenNotPaused {
        uint256 amount = Math.min(individualBuffer(msg.sender), buffer());

        _depleteIndividualBuffer(msg.sender, amount);
        _mintChi(to, amount);
    }
}
