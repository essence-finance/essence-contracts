pragma solidity ^0.8.0;

import "./ChiTimedMinter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title OwnableTimedMinter
/// @notice A ChiTimedMinter that mints only when called by an owner
contract OwnableTimedMinter is ChiTimedMinter, Ownable {
    /**
        @notice constructor for OwnableTimedMinter
        @param _core the Core address to reference
        @param _owner the minter and target to receive minted CHI
        @param _frequency the frequency buybacks happen
        @param _initialMintAmount the initial CHI amount to mint
    */
    constructor(
        address _core,
        address _owner,
        uint256 _frequency,
        uint256 _initialMintAmount
    ) ChiTimedMinter(_core, _owner, 0, _frequency, _initialMintAmount) {
        transferOwnership(_owner);
    }

    /// @notice triggers a minting of CHI by owner
    function mint() public override onlyOwner {
        super.mint();
    }
}
