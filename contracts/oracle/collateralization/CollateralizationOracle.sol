// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../IOracle.sol";
import "./ICollateralizationOracle.sol";
import "../../refs/CoreRef.sol";
import "../../pcv/IPCVDepositBalances.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IPausable {
    function paused() external view returns (bool);
}

/// @title Essence Finance's Collateralization Oracle
/// @notice Reads a list of PCVDeposit that report their amount of collateral
///         and the amount of protocol-owned CHI they manage, to deduce the
///         protocol-wide collateralization ratio.
contract CollateralizationOracle is ICollateralizationOracle, CoreRef {
    using Decimal for Decimal.D256;
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ----------- Events -----------

    event DepositAdd(address from, address indexed deposit, address indexed token);
    event DepositRemove(address from, address indexed deposit);
    event OracleUpdate(address from, address indexed token, address indexed oldOracle, address indexed newOracle);

    // ----------- Properties -----------

    /// @notice Map of oracles to use to get USD values of assets held in
    ///         PCV deposits. This map is used to get the oracle address from
    ///         and ERC20 address.
    mapping(address => address) public tokenToOracle;
    /// @notice Map from token address to an array of deposit addresses. It is
    //          used to iterate on all deposits while making oracle requests
    //          only once.
    mapping(address => EnumerableSet.AddressSet) private tokenToDeposits;
    /// @notice Map from deposit address to token address. It is used like an
    ///         indexed version of the pcvDeposits array, to check existence
    ///         of a PCVdeposit in the current config.
    mapping(address => address) public depositToToken;
    /// @notice Map from token address to converion multi if needed
    mapping(address => uint256) public tokenToConverMulti;
    /// @notice Array of all tokens held in the PCV. Used for iteration on tokens
    ///         and oracles.
    EnumerableSet.AddressSet private tokensInPcv;

    // ----------- Constructor -----------

    /// @notice CollateralizationOracle constructor
    /// @param _core Essence Core for reference
    /// @param _deposits the initial list of PCV deposits
    /// @param _tokens the initial supported tokens for oracle
    /// @param _oracles the matching set of oracles for _tokens
    constructor(
        address _core,
        address[] memory _deposits,
        address[] memory _tokens,
        address[] memory _oracles,
        uint256[] memory _converMultis
    ) CoreRef(_core) {
        _setOracles(_tokens, _oracles);
        _addDeposits(_deposits);
        _setConverMultis(_tokens, _converMultis);
    }

    // ----------- Convenience getters -----------

    /// @notice returns true if a token is held in the pcv
    function isTokenInPcv(address token) external view returns (bool) {
        return tokensInPcv.contains(token);
    }

    /// @notice returns an array of the addresses of tokens held in the pcv.
    function getTokensInPcv() external view returns (address[] memory) {
        return tokensInPcv.values();
    }

    /// @notice returns token at index i of the array of PCV tokens
    function getTokenInPcv(uint256 i) external view returns (address) {
        return tokensInPcv.at(i);
    }

    /// @notice returns an array of the deposits holding a given token.
    function getDepositsForToken(address _token) external view returns (address[] memory) {
        return tokenToDeposits[_token].values();
    }

    /// @notice returns the address of deposit at index i of token _token
    function getDepositForToken(address token, uint256 i) external view returns (address) {
        return tokenToDeposits[token].at(i);
    }

    /// @notice returns the address of token is true, else address(0)
    function isPcvDeposit(address _pcvDeposit) external view returns (address) {
        return depositToToken[_pcvDeposit];
    }
    // ----------- State-changing methods -----------

    /// @notice Add a PCVDeposit to the list of deposits inspected by the
    ///         collateralization ratio oracle.
    ///         note : this function reverts if the deposit is already in the list.
    ///         note : this function reverts if the deposit's token has no oracle.
    /// @param _deposit : the PCVDeposit to add to the list.
    function addDeposit(address _deposit) external onlyGuardianOrGovernor {
        _addDeposit(_deposit);
    }

    /// @notice adds a list of multiple PCV deposits. See addDeposit.
    function addDeposits(address[] memory _deposits) external onlyGuardianOrGovernor {
        _addDeposits(_deposits);
    }

    function _addDeposits(address[] memory _deposits) internal {
        for (uint256 i = 0; i < _deposits.length; i++) {
            _addDeposit(_deposits[i]);
        }
    }

    function _addDeposit(address _deposit) internal {
        // if the PCVDeposit is already listed, revert.
        require(depositToToken[_deposit] == address(0), "CollateralizationOracle: deposit duplicate");

        // get the token in which the deposit reports its token
        address _token = IPCVDepositBalances(_deposit).balanceReportedIn();

        // revert if there is no oracle of this deposit's token
        require(tokenToOracle[_token] != address(0), "CollateralizationOracle: no oracle");

        // update maps & arrays for faster access
        depositToToken[_deposit] = _token;
        tokenToDeposits[_token].add(_deposit);
        tokensInPcv.add(_token);

        // emit event
        emit DepositAdd(msg.sender, _deposit, _token);
    }

    /// @notice Remove a PCVDeposit from the list of deposits inspected by
    ///         the collateralization ratio oracle.
    ///         note : this function reverts if the input deposit is not found.
    /// @param _deposit : the PCVDeposit address to remove from the list.
    function removeDeposit(address _deposit) external onlyGuardianOrGovernor {
        _removeDeposit(_deposit);
    }

    /// @notice removes a list of multiple PCV deposits. See removeDeposit.
    function removeDeposits(address[] memory _deposits) external onlyGuardianOrGovernor {
        for (uint256 i = 0; i < _deposits.length; i++) {
            _removeDeposit(_deposits[i]);
        }
    }

    function _removeDeposit(address _deposit) internal {
        // get the token in which the deposit reports its token
        address _token = depositToToken[_deposit];

        // revert if the deposit is not found
        require(_token != address(0), "CollateralizationOracle: deposit not found");

        // update maps & arrays for faster access
        // deposits array for the deposit's token
        depositToToken[_deposit] = address(0);
        tokenToDeposits[_token].remove(_deposit);

        // if it was the last deposit to have this token, remove this token from
        // the arrays also
        if (tokenToDeposits[_token].length() == 0) {
            tokensInPcv.remove(_token);
        }

        // emit event
        emit DepositRemove(msg.sender, _deposit);
    }

    /// @notice Swap a PCVDeposit with a new one, for instance when a new version
    ///         of a deposit (holding the same token) is deployed.
    /// @param _oldDeposit : the PCVDeposit to remove from the list.
    /// @param _newDeposit : the PCVDeposit to add to the list.
    function swapDeposit(address _oldDeposit, address _newDeposit) external onlyGuardianOrGovernor {
        _removeDeposit(_oldDeposit);
        _addDeposit(_newDeposit);
    }

    /// @notice Set the conversion mutli for a given asset.
    /// @param _token : the asset to add conversion multi for
    /// @param _newConverMutli : convert decimals to 18 
    function setConverMulti(address _token, uint256 _newConverMutli) external onlyGuardianOrGovernor {
        _setConverMulti(_token, _newConverMutli);
    }

    /// @notice adds a list of token oracles. See setOracle.
    function setConverMultis(address[] memory _tokens, uint256[] memory _converMutlis) public onlyGuardianOrGovernor {
        _setConverMultis(_tokens, _converMutlis);
    }

    function _setConverMultis(address[] memory _tokens, uint256[] memory _converMutlis) internal {
        require(_tokens.length == _converMutlis.length, "CollateralizationOracle: length mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            _setConverMulti(_tokens[i], _converMutlis[i]);
        }
    }

    function _setConverMulti(address _token, uint256 _newConverMutli) internal {
        require(_token != address(0), "CollateralizationOracle: token must be != 0x0");
        require(_newConverMutli != 0, "CollateralizationOracle: converMutli must be != 0");

        // add _newConverMutli to the map(ERC20Address) => ConverMutli
        tokenToConverMulti[_token] = _newConverMutli;

    }

     /// @notice Set the price feed oracle (in USD) for a given asset.
    /// @param _token : the asset to add price oracle for
    /// @param _newOracle : price feed oracle for the given asset
    function setOracle(address _token, address _newOracle) external onlyGuardianOrGovernor {
        _setOracle(_token, _newOracle);
    }

    /// @notice adds a list of token oracles. See setOracle.
    function setOracles(address[] memory _tokens, address[] memory _oracles) public onlyGuardianOrGovernor {
        _setOracles(_tokens, _oracles);
    }

    function _setOracles(address[] memory _tokens, address[] memory _oracles) internal {
        require(_tokens.length == _oracles.length, "CollateralizationOracle: length mismatch");
        for (uint256 i = 0; i < _tokens.length; i++) {
            _setOracle(_tokens[i], _oracles[i]);
        }
    }

    function _setOracle(address _token, address _newOracle) internal {
        require(_token != address(0), "CollateralizationOracle: token must be != 0x0");
        require(_newOracle != address(0), "CollateralizationOracle: oracle must be != 0x0");

        // add oracle to the map(ERC20Address) => OracleAddress
        address _oldOracle = tokenToOracle[_token];
        tokenToOracle[_token] = _newOracle;

        // emit event
        emit OracleUpdate(msg.sender, _token, _oldOracle, _newOracle);
    }

    // ----------- IOracle override methods -----------
    /// @notice update all oracles required for this oracle to work that are not
    ///         paused themselves.
    function update() external override whenNotPaused {
        for (uint256 i = 0; i < tokensInPcv.length(); i++) {
            address _oracle = tokenToOracle[tokensInPcv.at(i)];
            if (!IPausable(_oracle).paused()) {
                IOracle(_oracle).update();
            }
        }
    }

    // @notice returns true if any of the oracles required for this oracle to
    //         work are outdated.
    function isOutdated() external view override returns (bool) {
        bool _outdated = false;
        for (uint256 i = 0; i < tokensInPcv.length() && !_outdated; i++) {
            address _oracle = tokenToOracle[tokensInPcv.at(i)];
            if (!IPausable(_oracle).paused()) {
                _outdated = _outdated || IOracle(_oracle).isOutdated();
            }
        }
        return _outdated;
    }

    /// @notice Get the current collateralization ratio of the protocol.
    /// @return collateralRatio the current collateral ratio of the protocol.
    /// @return validityStatus the current oracle validity status (false if any
    ///         of the oracles for tokens held in the PCV are invalid, or if
    ///         this contract is paused).
    function read() public view override returns (Decimal.D256 memory collateralRatio, bool validityStatus) {
        // fetch PCV stats
        (
            uint256 _protocolControlledValue,
            uint256 _userCirculatingChi, // we don't need protocol equity
            ,
            bool _valid
        ) = pcvStats();

        // The protocol collateralization ratio is defined as the total USD
        // value of assets held in the PCV, minus the circulating CHI.
        collateralRatio = Decimal.ratio(_protocolControlledValue, _userCirculatingChi);
        validityStatus = _valid;
    }

    // ----------- ICollateralizationOracle override methods -----------

    /// @notice returns the Protocol-Controlled Value, User-circulating CHI, and
    ///         Protocol Equity.
    /// @return protocolControlledValue : the total USD value of all assets held
    ///         by the protocol.
    /// @return userCirculatingChi : the number of CHI not owned by the protocol.
    /// @return protocolEquity : the signed difference between PCV and user circulating CHI.
    /// @return validityStatus : the current oracle validity status (false if any
    ///         of the oracles for tokens held in the PCV are invalid, or if
    ///         this contract is paused).
    function pcvStats()
        public
        view
        override
        returns (
            uint256 protocolControlledValue,
            uint256 userCirculatingChi,
            int256 protocolEquity,
            bool validityStatus
        )
    {
        uint256 _protocolControlledChi = 0;
        validityStatus = !paused();

        // For each token...
        for (uint256 i = 0; i < tokensInPcv.length(); i++) {
            address _token = tokensInPcv.at(i);
            uint256 _totalTokenBalance = 0;

            // For each deposit...
            for (uint256 j = 0; j < tokenToDeposits[_token].length(); j++) {
                address _deposit = tokenToDeposits[_token].at(j);

                // read the deposit, and increment token balance/protocol chi
                (uint256 _depositBalance, uint256 _depositChi) = IPCVDepositBalances(_deposit).resistantBalanceAndChi();
                _totalTokenBalance += _depositBalance;
                _protocolControlledChi += _depositChi;
            }

            // If the protocol holds non-zero balance of tokens, fetch the oracle price to
            // increment PCV by _totalTokenBalance * oracle price USD.
            if (_totalTokenBalance != 0) {
                (Decimal.D256 memory _oraclePrice, bool _oracleValid) = IOracle(tokenToOracle[_token]).read();
                if (!_oracleValid) {
                    validityStatus = false;
                }
                protocolControlledValue += _oraclePrice.mul(_totalTokenBalance * tokenToConverMulti[_token]).asUint256();
            }
        }

        userCirculatingChi = chi().totalSupply() - _protocolControlledChi;
        protocolEquity = protocolControlledValue.toInt256() - userCirculatingChi.toInt256();
    }

    /// @notice returns true if the protocol is overcollateralized. Overcollateralization
    ///         is defined as the protocol having more assets in its PCV (Protocol
    ///         Controlled Value) than the circulating (user-owned) CHI, i.e.
    ///         a positive Protocol Equity.
    function isOvercollateralized() external view override whenNotPaused returns (bool) {
        (, , int256 _protocolEquity, bool _valid) = pcvStats();
        require(_valid, "CollateralizationOracle: reading is invalid");
        return _protocolEquity > 0;
    }
}
