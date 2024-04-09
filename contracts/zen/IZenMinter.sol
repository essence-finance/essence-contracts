// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IZen is IERC20 {
    function mint(address to, uint256 amount) external;

    function setMinter(address newMinter) external;
}

/// @title ZenMinter interface
interface IZenMinter {
    // ----------- Events -----------
    event AnnualMaxInflationUpdate(uint256 oldAnnualMaxInflationBasisPoints, uint256 newAnnualMaxInflationBasisPoints);
    event ZenTreasuryUpdate(address indexed oldZenTreasury, address indexed newZenTreasury);
    event ZenRewardsDripperUpdate(address indexed oldZenRewardsDripper, address indexed newZenRewardsDripper);

    // ----------- Public state changing api -----------

    function poke() external;

    // ----------- Owner only state changing api -----------

    function setMinter(address newMinter) external;

    // ----------- Governor or Admin only state changing api -----------

    function mint(address to, uint256 amount) external;

    function setZenTreasury(address newZenTreasury) external;

    function setZenRewardsDripper(address newZenRewardsDripper) external;

    function setAnnualMaxInflationBasisPoints(uint256 newAnnualMaxInflationBasisPoints) external;

    // ----------- Getters -----------

    function annualMaxInflationBasisPoints() external view returns (uint256);

    function idealBufferCap() external view returns (uint256);

    function zenCirculatingSupply() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function isPokeNeeded() external view returns (bool);

    function zenTreasury() external view returns (address);

    function zenRewardsDripper() external view returns (address);
}
