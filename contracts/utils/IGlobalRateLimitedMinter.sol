// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "./IMultiRateLimited.sol";

/// @notice global contract to handle rate limited minting of Chi on a global level
/// allows whitelisted minters to call in and specify the address to mint Chi to within
/// the calling contract's limits
interface IGlobalRateLimitedMinter is IMultiRateLimited {
    /// @notice function that all Chi minters call to mint Chi
    /// pausable and depletes the msg.sender's buffer
    /// @param to the recipient address of the minted Chi
    /// @param amount the amount of Chi to mint
    function mint(address to, uint256 amount) external;

    /// @notice mint Chi to the target address and deplete the whole rate limited
    ///  minter's buffer, pausable and completely depletes the msg.sender's buffer
    /// @param to the recipient address of the minted Chi
    /// mints all Chi that msg.sender has in the buffer
    function mintMaxAllowableChi(address to) external;
}
