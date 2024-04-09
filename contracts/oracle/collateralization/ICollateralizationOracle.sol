// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../IOracle.sol";

/// @title Collateralization ratio oracle interface for Essence Finance
interface ICollateralizationOracle is IOracle {
    // ----------- Getters -----------

    // returns the PCV value, User-circulating Chi, and Protocol Equity, as well
    // as a validity status.
    function pcvStats() external view returns ( uint256 protocolControlledValue, uint256 userCirculatingChi, int256 protocolEquity, bool validityStatus );

    // true if Protocol Equity > 0
    function isOvercollateralized() external view returns (bool);

    function isPcvDeposit (address _pcvDeposit) external view returns (address);
    // function depositToToken(address)
}
