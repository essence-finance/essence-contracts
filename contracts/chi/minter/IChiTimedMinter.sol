// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @title a Chi Timed Minter
interface IChiTimedMinter {
    // ----------- Events -----------

    event ChiMinting(address indexed caller, uint256 chiAmount);

    event TargetUpdate(address oldTarget, address newTarget);

    event MintAmountUpdate(uint256 oldMintAmount, uint256 newMintAmount);

    // ----------- State changing api -----------

    function mint() external;

    // ----------- Governor only state changing api -----------

    function setTarget(address newTarget) external;

    // ----------- Governor or Admin only state changing api -----------

    function setFrequency(uint256 newFrequency) external;

    function setMintAmount(uint256 newMintAmount) external;

    // ----------- Getters -----------

    function mintAmount() external view returns (uint256);

    function MIN_MINT_FREQUENCY() external view returns (uint256);

    function MAX_MINT_FREQUENCY() external view returns (uint256);

    function target() external view returns (address);
}
