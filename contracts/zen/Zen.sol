// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Zen is ERC20Burnable {
    /// @notice The address of the Zen Minter
    address public minter;

    /// @notice An event thats emitted when the minter address is changed
    event MinterChanged(address minter, address newMinter);

    constructor(address _initialMintAccount, address _minter) ERC20("Zen", "ZEN") {
        _mint(_initialMintAccount, 1_000_000_000e18); // mint inital supply of 1 billion
        minter = _minter;
        emit MinterChanged(address(0), minter);
    }

    function setMinter(address _minter) external {
        require(msg.sender == minter, "Zen: only the minter can change the minter address");
        minter = _minter;
        emit MinterChanged(address(0), minter);
    }

    function mint(address account, uint256 amount) external returns (bool) {
        require(msg.sender == minter, "Zen: only the minter can mint");
        _mint(account, amount);

        return true;
    }
}
