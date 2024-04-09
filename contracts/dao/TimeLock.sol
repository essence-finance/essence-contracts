// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";

contract Timelock is TimelockController {
    constructor(address[] memory proposers, address[] memory executors)
        TimelockController(24 hours, proposers, executors, msg.sender)
    {}
}