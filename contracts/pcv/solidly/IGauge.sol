// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IGauge {
    function deposit(uint amount) external;
    function getReward() external;
    function notifyRewardAmount(uint amount) external;
    function withdraw(uint shares) external;
    function balanceOf(address account) external view returns (uint);
}