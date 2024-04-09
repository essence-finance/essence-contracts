pragma solidity ^0.8.0;

import "../../refs/CoreRef.sol";
import "../../oracle/collateralization/ICollateralizationOracle.sol";
import "../../pcv/solidly/IRouter.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/IXZen.sol";
import "../../zen/xzen/interfaces/IDividendsV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PCVEquityMinter is CoreRef {
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    /// @notice the collateralization oracle used to determine PCV equity
    ICollateralizationOracle public collateralizationOracle;

    /// @notice Router
    IRouter public router;

    /// @notice The xZEN token
    IXZen public xZEN;

    /// @notice The xZEN Dividend contract;
    IDividendsV2 public dividend;

    constructor(
        address _core,
        address _router,
        ICollateralizationOracle _collateralizationOracle,
        IXZen _xZEN,
        IDividendsV2 _dividend
    ) CoreRef(_core) {
        _setCollateralizationOracle(_collateralizationOracle);
        router = IRouter(_router);
        xZEN = IXZen(_xZEN);
        dividend = IDividendsV2(_dividend);
    }

    /// @notice triggers a minting of CHI, Chi only mintable when collat. ratio is positive
    function mint(uint256 amountToMint) public virtual onlyGuardianOrGovernor whenNotPaused {
        (, , int256 equity, bool valid) = collateralizationOracle.pcvStats();
        uint256 maxMintableAmount = equity.toUint256();

        require(maxMintableAmount > amountToMint, "PCVEquityMinter: amountToMint is more than equity value");
        require(valid, "PCVEquityMinter: invalid CR oracle");

        _mintChi(address(this), amountToMint);
    }

    //@notice Buyback of ZEN using minted chi
    function buyBackZen(uint256 chiAmount, uint256 minOut) public onlyGuardianOrPCVController whenNotPaused {
        chi().approve(address(router), chiAmount);
        router.swapExactTokensForTokens(
            chiAmount,
            minOut,
            getRoute(address(chi()), address(zen())),
            address(this),
            block.timestamp
        );
    }

    function swapFromChi(
        uint256 chiAmount,
        uint256 minOut,
        address token
    ) public onlyGuardianOrPCVController whenNotPaused {
        chi().approve(address(router), chiAmount);
        router.swapExactTokensForTokens(
            chiAmount,
            minOut,
            getRoute(address(chi()), token),
            address(this),
            block.timestamp
        );
    }

    function convertZen() public onlyGuardianOrPCVController whenNotPaused {
        uint256 zenBalance = IERC20(zen()).balanceOf(address(this));
        IERC20(zen()).approve(address(xZEN), zenBalance);
        xZEN.convert(zenBalance);
    }

    function addToDividends() public onlyGuardianOrPCVController whenNotPaused {
        // @notice adds contracts CHI balance to xZEN's dividend contract
        chi().approve(address(dividend), chi().balanceOf(address(this)));
        dividend.addDividendsToPending(address(chi()), chi().balanceOf(address(this)));

        // @notice adds contracts xZEN balance to xZEN's dividend contract
        xZEN.approve(address(dividend), xZEN.balanceOf(address(this)));
        dividend.addDividendsToPending(address(xZEN), xZEN.balanceOf(address(this)));
    }

    /// @notice set the collateralization oracle
    function setCollateralizationOracle(ICollateralizationOracle newCollateralizationOracle) external onlyGovernor {
        _setCollateralizationOracle(newCollateralizationOracle);
    }

    function getRoute(address from, address to) internal pure returns (IRouter.route[] memory) {
        IRouter.route memory route = IRouter.route(from, to, false);
        IRouter.route[] memory routeArray = new IRouter.route[](1);
        routeArray[0] = route;
        return routeArray;
    }

    function _setCollateralizationOracle(ICollateralizationOracle newCollateralizationOracle) internal {
        require(address(newCollateralizationOracle) != address(0), "PCVEquityMinter: zero address");
        collateralizationOracle = newCollateralizationOracle;
    }
    
    /// @notice Allows Gurdian to withdraw @param token to the a valid PCV deposit. Transaction will fail otherwise.
    function sendTokenToPCVDeposit(address token, address to, uint256 amountToken) external onlyGuardianOrPCVController whenNotPaused {
        require(collateralizationOracle.isPcvDeposit(to)!= address(0), "PCVEquityMinter: address(to) is not a valid PCVDeposit");
        IERC20(token).safeTransfer(to, amountToken);
    }

    function withdraw(address token, address to, uint256 amountToken) external onlyPCVController whenNotPaused {
        IERC20(token).safeTransfer(to, amountToken);
    }
}
