// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../chi/IChi.sol";

interface IZen is IERC20 {
    function delegate(address delegatee) external;
}

/// @title TimelockedDelegator interface
interface ITimelockedDelegator {
    // ----------- Events -----------

    event Delegate(address indexed _delegatee, uint256 _amount);

    event Undelegate(address indexed _delegatee, uint256 _amount);

    // ----------- Beneficiary only state changing api -----------

    function delegate(address delegatee, uint256 amount) external;

    function undelegate(address delegatee) external returns (uint256);

    // ----------- Getters -----------

    function delegateContract(address delegatee) external view returns (address);

    function delegateAmount(address delegatee) external view returns (uint256);

    function totalDelegated() external view returns (uint256);

    function zen() external view returns (IZen);
}
