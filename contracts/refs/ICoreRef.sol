// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../core/ICore.sol";

/// @title CoreRef interface
interface ICoreRef {
    // ----------- Events -----------

    event CoreUpdate(address indexed oldCore, address indexed newCore);

    // ----------- Governor or Guardian only state changing api -----------

    function pause() external;

    function unpause() external;

    // ----------- Getters -----------

    function core() external view returns (ICore);

    function chi() external view returns (IChi);

    function zen() external view returns (IERC20);

    function chiBalance() external view returns (uint256);

    function zenBalance() external view returns (uint256);
}
