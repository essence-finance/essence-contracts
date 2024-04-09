// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol"; 
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/tokens/IZenTokenV2.sol";
import "./interfaces/tokens/IXZenToken.sol";
import "./interfaces/IXZenTokenUsage.sol";
import "../../refs/CoreRef.sol";

/*
 * xZEN is Essence's escrowed governance token obtainable by converting ZEN to it
 * It's non-transferable, except from/to whitelisted addresses
 * It can be converted back to ZEN through a vesting process
 * This contract is made to receive xZEN deposits from users in order to allocate them to Usages (plugins) contracts
 */

contract XZenToken is CoreRef, ReentrancyGuard, ERC20Votes, IXZenToken {
    using Address for address;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IZenTokenV2;

    struct XZenBalance {
        uint256 allocatedAmount; // Amount of xZEN allocated to a Usage
        uint256 redeemingAmount; // Total amount of xZEN currently being redeemed
    }

    struct RedeemInfo {
        uint256 zenAmount; // ZEN amount to receive when vesting has ended
        uint256 xZenAmount; // xZEN amount to redeem
        uint256 endTime;
        IXZenTokenUsage dividendsAddress;
        uint256 dividendsAllocation; // Share of redeeming xZEN to allocate to the Dividends Usage contract
    }

    IZenTokenV2 public immutable zenToken; // ZEN token to convert to/from
    IXZenTokenUsage public dividendsAddress; // Essence dividends contract

    EnumerableSet.AddressSet private _transferWhitelist; // addresses allowed to send/receive xZEN

    mapping(address => mapping(address => uint256)) public usageApprovals; // Usage approvals to allocate xZEN
    mapping(address => mapping(address => uint256)) public override usageAllocations; // Active xZEN allocations to usages

    uint256 public constant MAX_DEALLOCATION_FEE = 200; // 2%
    mapping(address => uint256) public usagesDeallocationFee; // Fee paid when deallocating xZEN

    uint256 public constant MAX_FIXED_RATIO = 100; // 100%

    // Redeeming min/max settings
    uint256 public minRedeemRatio = 50; // 1:0.5
    uint256 public maxRedeemRatio = 100; // 1:1
    uint256 public minRedeemDuration = 15 days; // 1296000s
    uint256 public maxRedeemDuration = 180 days; // 7776000s
    // Adjusted dividends rewards for redeeming xZEN
    uint256 public redeemDividendsAdjustment = 0; // 0%

    mapping(address => XZenBalance) public xZenBalances; // User's xZEN balances
    mapping(address => RedeemInfo[]) public userRedeems; // User's redeeming instances

    constructor(
        IZenTokenV2 zenToken_,
        address _core
    ) ERC20("Essence escrowed token", "xZEN") ERC20Permit("Essence escrowed token") CoreRef(_core) {
        zenToken = zenToken_;
        _transferWhitelist.add(address(this));
    }

    /********************************************/
    /****************** EVENTS ******************/
    /********************************************/

    event ApproveUsage(address indexed userAddress, address indexed usageAddress, uint256 amount);
    event Convert(address indexed from, address to, uint256 amount);
    event UpdateRedeemSettings(
        uint256 minRedeemRatio,
        uint256 maxRedeemRatio,
        uint256 minRedeemDuration,
        uint256 maxRedeemDuration,
        uint256 redeemDividendsAdjustment
    );
    event UpdateDividendsAddress(address previousDividendsAddress, address newDividendsAddress);
    event UpdateDeallocationFee(address indexed usageAddress, uint256 fee);
    event SetTransferWhitelist(address account, bool add);
    event Redeem(address indexed userAddress, uint256 xZenAmount, uint256 zenAmount, uint256 duration);
    event FinalizeRedeem(address indexed userAddress, uint256 xZenAmount, uint256 zenAmount);
    event CancelRedeem(address indexed userAddress, uint256 xZenAmount);
    event UpdateRedeemDividendsAddress(
        address indexed userAddress,
        uint256 redeemIndex,
        address previousDividendsAddress,
        address newDividendsAddress
    );
    event Allocate(address indexed userAddress, address indexed usageAddress, uint256 amount);
    event Deallocate(address indexed userAddress, address indexed usageAddress, uint256 amount, uint256 fee);

    /***********************************************/
    /****************** MODIFIERS ******************/
    /***********************************************/

    /*
     * @dev Check if a redeem entry exists
     */
    modifier validateRedeem(address userAddress, uint256 redeemIndex) {
        require(redeemIndex < userRedeems[userAddress].length, "validateRedeem: redeem entry does not exist");
        _;
    }

    /**************************************************/
    /****************** PUBLIC VIEWS ******************/
    /**************************************************/

    /*
     * @dev Returns user's xZEN balances
     */
    function getXZenBalance(
        address userAddress
    ) external view returns (uint256 allocatedAmount, uint256 redeemingAmount) {
        XZenBalance storage balance = xZenBalances[userAddress];
        return (balance.allocatedAmount, balance.redeemingAmount);
    }

    /*
     * @dev returns redeemable ZEN for "amount" of xZEN vested for "duration" seconds
     */
    function getZenByVestingDuration(uint256 amount, uint256 duration) public view returns (uint256) {
        if (duration < minRedeemDuration) {
            return 0;
        }

        // capped to maxRedeemDuration
        if (duration > maxRedeemDuration) {
            return amount.mul(maxRedeemRatio).div(100);
        }

        uint256 ratio = minRedeemRatio.add(
            (duration.sub(minRedeemDuration)).mul(maxRedeemRatio.sub(minRedeemRatio)).div(
                maxRedeemDuration.sub(minRedeemDuration)
            )
        );

        return amount.mul(ratio).div(100);
    }

    /**
     * @dev returns quantity of "userAddress" pending redeems
     */
    function getUserRedeemsLength(address userAddress) external view returns (uint256) {
        return userRedeems[userAddress].length;
    }

    /**
     * @dev returns "userAddress" info for a pending redeem identified by "redeemIndex"
     */
    function getUserRedeem(
        address userAddress,
        uint256 redeemIndex
    )
        external
        view
        validateRedeem(userAddress, redeemIndex)
        returns (
            uint256 zenAmount,
            uint256 xZenAmount,
            uint256 endTime,
            address dividendsContract,
            uint256 dividendsAllocation
        )
    {
        RedeemInfo storage _redeem = userRedeems[userAddress][redeemIndex];
        return (
            _redeem.zenAmount,
            _redeem.xZenAmount,
            _redeem.endTime,
            address(_redeem.dividendsAddress),
            _redeem.dividendsAllocation
        );
    }

    /**
     * @dev returns approved xZen to allocate from "userAddress" to "usageAddress"
     */
    function getUsageApproval(address userAddress, address usageAddress) external view returns (uint256) {
        return usageApprovals[userAddress][usageAddress];
    }

    /**
     * @dev returns allocated xZen from "userAddress" to "usageAddress"
     */
    function getUsageAllocation(address userAddress, address usageAddress) external view returns (uint256) {
        return usageAllocations[userAddress][usageAddress];
    }

    /**
     * @dev returns length of transferWhitelist array
     */
    function transferWhitelistLength() external view returns (uint256) {
        return _transferWhitelist.length();
    }

    /**
     * @dev returns transferWhitelist array item's address for "index"
     */
    function transferWhitelist(uint256 index) external view returns (address) {
        return _transferWhitelist.at(index);
    }

    /**
     * @dev returns if "account" is allowed to send/receive xZEN
     */
    function isTransferWhitelisted(address account) external view override returns (bool) {
        return _transferWhitelist.contains(account);
    }

    /*******************************************************/
    /************ ACCESS CONTROLLED FUNCTIONS **************/
    /*******************************************************/
    /**
     * @dev Updates all redeem ratios and durations
     *
     * Must only be called by Governer or Gurdian	Role
     */
    function updateRedeemSettings(
        uint256 minRedeemRatio_,
        uint256 maxRedeemRatio_,
        uint256 minRedeemDuration_,
        uint256 maxRedeemDuration_,
        uint256 redeemDividendsAdjustment_
    ) external onlyGuardianOrGovernor {
        require(minRedeemRatio_ <= maxRedeemRatio_, "updateRedeemSettings: wrong ratio values");
        require(minRedeemDuration_ < maxRedeemDuration_, "updateRedeemSettings: wrong duration values");
        // should never exceed 100%
        require(
            maxRedeemRatio_ <= MAX_FIXED_RATIO && redeemDividendsAdjustment_ <= MAX_FIXED_RATIO,
            "updateRedeemSettings: wrong ratio values"
        );
        minRedeemRatio = minRedeemRatio_;
        maxRedeemRatio = maxRedeemRatio_;
        minRedeemDuration = minRedeemDuration_;
        maxRedeemDuration = maxRedeemDuration_;
        redeemDividendsAdjustment = redeemDividendsAdjustment_;
        emit UpdateRedeemSettings(
            minRedeemRatio_,
            maxRedeemRatio_,
            minRedeemDuration_,
            maxRedeemDuration_,
            redeemDividendsAdjustment_
        );
    }

    /**
     * @dev Updates dividends contract address
     *
     * Must only be called by owner
     */
    function updateDividendsAddress(IXZenTokenUsage dividendsAddress_) external onlyGuardianOrGovernor {
        // if set to 0, also set divs earnings while redeeming to 0
        if (address(dividendsAddress_) == address(0)) {
            redeemDividendsAdjustment = 0;
        }
        emit UpdateDividendsAddress(address(dividendsAddress), address(dividendsAddress_));
        dividendsAddress = dividendsAddress_;
    }

    /**
     * @dev Updates fee paid by users when deallocating from "usageAddress"
     */
    function updateDeallocationFee(address usageAddress, uint256 fee) external onlyGuardianOrGovernor {
        require(fee <= MAX_DEALLOCATION_FEE, "updateDeallocationFee: too high");
        usagesDeallocationFee[usageAddress] = fee;
        emit UpdateDeallocationFee(usageAddress, fee);
    }

    /**
     * @dev Adds or removes addresses from the transferWhitelist
     */
    function updateTransferWhitelist(address account, bool add) external onlyGuardianOrGovernor {
        require(account != address(this), "updateTransferWhitelist: Cannot remove xZen from whitelist");
        if (add) _transferWhitelist.add(account);
        else _transferWhitelist.remove(account);
        emit SetTransferWhitelist(account, add);
    }

    function setDelegatee(address delegatee) external onlyGuardianOrGovernor {
        _delegate(address(this), delegatee);
    }

    /*****************************************************************/
    /******************  EXTERNAL PUBLIC FUNCTIONS  ******************/
    /*****************************************************************/

    /**
     * @dev Approves "usage" address to get allocations up to "amount" of xZEN from msg.sender
     */
    function approveUsage(IXZenTokenUsage usage, uint256 amount) external nonReentrant {
        require(address(usage) != address(0), "approveUsage: approve to the zero address");

        usageApprovals[msg.sender][address(usage)] = amount;
        emit ApproveUsage(msg.sender, address(usage), amount);
    }

    /**
     * @dev Convert caller's "amount" of ZEN to xZEN
     */
    function convert(uint256 amount) external nonReentrant {
        _convert(amount, msg.sender);
    }

    /**
     * @dev Convert caller's "amount" of ZEN to xZEN to "to" address
     */
    function convertTo(uint256 amount, address to) external override nonReentrant {
        _convert(amount, to);
    }

    /**
     * @dev Initiates redeem process (xZEN to ZEN)
     *
     * Handles dividends' compensation allocation during the vesting process if needed
     */
    function redeem(uint256 xZenAmount, uint256 duration) external nonReentrant {
        require(xZenAmount > 0, "redeem: xZenAmount cannot be null");
        require(duration >= minRedeemDuration, "redeem: duration too low");

        _transfer(msg.sender, address(this), xZenAmount);
        XZenBalance storage balance = xZenBalances[msg.sender];

        // get corresponding ZEN amount
        uint256 zenAmount = getZenByVestingDuration(xZenAmount, duration);
        emit Redeem(msg.sender, xZenAmount, zenAmount, duration);

        // if redeeming is not immediate, go through vesting process
        if (duration > 0) {
            // add to SBT total
            balance.redeemingAmount = balance.redeemingAmount.add(xZenAmount);

            // handle dividends during the vesting process
            uint256 dividendsAllocation = xZenAmount.mul(redeemDividendsAdjustment).div(100);
            // only if compensation is active
            if (dividendsAllocation > 0) {
                // allocate to dividends
                dividendsAddress.allocate(msg.sender, dividendsAllocation, new bytes(0));
            }

            // add redeeming entry
            userRedeems[msg.sender].push(
                RedeemInfo(
                    zenAmount,
                    xZenAmount,
                    _currentBlockTimestamp().add(duration),
                    dividendsAddress,
                    dividendsAllocation
                )
            );
        } else {
            // immediately redeem for ZEN
            _finalizeRedeem(msg.sender, xZenAmount, zenAmount);
        }
    }

    /**
     * @dev Finalizes redeem process when vesting duration has been reached
     *
     * Can only be called by the redeem entry owner
     */
    function finalizeRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        XZenBalance storage balance = xZenBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];
        require(_currentBlockTimestamp() >= _redeem.endTime, "finalizeRedeem: vesting duration has not ended yet");

        // remove from SBT total
        balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.xZenAmount);
        _finalizeRedeem(msg.sender, _redeem.xZenAmount, _redeem.zenAmount);

        // handle dividends compensation if any was active
        if (_redeem.dividendsAllocation > 0) {
            // deallocate from dividends
            IXZenTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
        }

        // remove redeem entry
        _deleteRedeemEntry(redeemIndex);
    }

    /**
     * @dev Updates dividends address for an existing active redeeming process
     *
     * Can only be called by the involved user
     * Should only be used if dividends contract was to be migrated
     */
    function updateRedeemDividendsAddress(
        uint256 redeemIndex
    ) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        // only if the active dividends contract is not the same anymore
        if (dividendsAddress != _redeem.dividendsAddress && address(dividendsAddress) != address(0)) {
            if (_redeem.dividendsAllocation > 0) {
                // deallocate from old dividends contract
                _redeem.dividendsAddress.deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
                // allocate to new used dividends contract
                dividendsAddress.allocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
            }

            emit UpdateRedeemDividendsAddress(
                msg.sender,
                redeemIndex,
                address(_redeem.dividendsAddress),
                address(dividendsAddress)
            );
            _redeem.dividendsAddress = dividendsAddress;
        }
    }

    /**
     * @dev Cancels an ongoing redeem entry
     *
     * Can only be called by its owner
     */
    function cancelRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        XZenBalance storage balance = xZenBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        // make redeeming xZEN available again
        balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.xZenAmount);
        _transfer(address(this), msg.sender, _redeem.xZenAmount);

        // handle dividends compensation if any was active
        if (_redeem.dividendsAllocation > 0) {
            // deallocate from dividends
            IXZenTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
        }

        emit CancelRedeem(msg.sender, _redeem.xZenAmount);

        // remove redeem entry
        _deleteRedeemEntry(redeemIndex);
    }

    /**
     * @dev Allocates caller's "amount" of available xZEN to "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        _allocate(msg.sender, usageAddress, amount);

        // allocates xZEN to usageContract
        IXZenTokenUsage(usageAddress).allocate(msg.sender, amount, usageData);
    }

    /**
     * @dev Allocates "amount" of available xZEN from "userAddress" to caller (ie usage contract)
     *
     * Caller must have an allocation approval for the required xZen xZEN from "userAddress"
     */
    function allocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
        _allocate(userAddress, msg.sender, amount);
    }

    /**
     * @dev Deallocates caller's "amount" of available xZEN from "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function deallocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        _deallocate(msg.sender, usageAddress, amount);

        // deallocate xZEN into usageContract
        IXZenTokenUsage(usageAddress).deallocate(msg.sender, amount, usageData);
    }

    /**
     * @dev Deallocates "amount" of allocated xZEN belonging to "userAddress" from caller (ie usage contract)
     *
     * Caller can only deallocate xZEN from itself
     */
    function deallocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
        _deallocate(userAddress, msg.sender, amount);
    }

    /********************************************************/
    /****************** INTERNAL FUNCTIONS ******************/
    /********************************************************/

    /**
     * @dev Convert caller's "amount" of ZEN into xZEN to "to"
     */
    function _convert(uint256 amount, address to) internal {
        require(amount != 0, "convert: amount cannot be null");

        // mint new xZEN
        _mint(to, amount);

        emit Convert(msg.sender, to, amount);
        zenToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Finalizes the redeeming process for "userAddress" by transferring him "zenAmount" and removing "xZenAmount" from supply
     *
     * Any vesting check should be ran before calling this
     * ZEN excess is automatically burnt
     */
    function _finalizeRedeem(address userAddress, uint256 xZenAmount, uint256 zenAmount) internal {
        uint256 zenExcess = xZenAmount.sub(zenAmount);

        // sends due ZEN tokens
        zenToken.safeTransfer(userAddress, zenAmount);

        // burns ZEN excess if any
        zenToken.burn(zenExcess);
        _burn(address(this), xZenAmount);

        emit FinalizeRedeem(userAddress, xZenAmount, zenAmount);
    }

    /**
     * @dev Allocates "userAddress" user's "amount" of available xZEN to "usageAddress" contract
     *
     */
    function _allocate(address userAddress, address usageAddress, uint256 amount) internal {
        require(amount > 0, "allocate: amount cannot be null");

        XZenBalance storage balance = xZenBalances[userAddress];

        // approval checks if allocation request amount has been approved by userAddress to be allocated to this usageAddress
        uint256 approvedXZen = usageApprovals[userAddress][usageAddress];
        require(approvedXZen >= amount, "allocate: non authorized amount");

        // remove allocated amount from usage's approved amount
        usageApprovals[userAddress][usageAddress] = approvedXZen.sub(amount);

        // update usage's allocatedAmount for userAddress
        usageAllocations[userAddress][usageAddress] = usageAllocations[userAddress][usageAddress].add(amount);

        // adjust user's xZEN balances
        balance.allocatedAmount = balance.allocatedAmount.add(amount);
        _transfer(userAddress, address(this), amount);

        emit Allocate(userAddress, usageAddress, amount);
    }

    /**
     * @dev Deallocates "amount" of available xZEN to "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function _deallocate(address userAddress, address usageAddress, uint256 amount) internal {
        require(amount > 0, "deallocate: amount cannot be null");

        // check if there is enough allocated xZEN to this usage to deallocate
        uint256 allocatedAmount = usageAllocations[userAddress][usageAddress];
        require(allocatedAmount >= amount, "deallocate: non authorized amount");

        // remove deallocated amount from usage's allocation
        usageAllocations[userAddress][usageAddress] = allocatedAmount.sub(amount);

        uint256 deallocationFeeAmount = amount.mul(usagesDeallocationFee[usageAddress]).div(10000);

        // adjust user's xZEN balances
        XZenBalance storage balance = xZenBalances[userAddress];
        balance.allocatedAmount = balance.allocatedAmount.sub(amount);
        _transfer(address(this), userAddress, amount.sub(deallocationFeeAmount));
        // burn corresponding ZEN and XZEN
        zenToken.burn(deallocationFeeAmount);
        _burn(address(this), deallocationFeeAmount);

        emit Deallocate(userAddress, usageAddress, amount, deallocationFeeAmount);
    }

    function _deleteRedeemEntry(uint256 index) internal {
        userRedeems[msg.sender][index] = userRedeems[msg.sender][userRedeems[msg.sender].length - 1];
        userRedeems[msg.sender].pop();
    }

    /**
     * @dev Hook override to forbid transfers except from whitelisted addresses and minting
     */
    function _beforeTokenTransfer(address from, address to, uint256 /*amount*/) internal view override {
        require(
            from == address(0) || _transferWhitelist.contains(from) || _transferWhitelist.contains(to),
            "transfer: not allowed"
        );
    }

    /**
     * @dev Utility function to get the current block timestamp
     */
    function _currentBlockTimestamp() internal view virtual returns (uint256) {
        /* solhint-disable not-rely-on-time */
        return block.timestamp;
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}
