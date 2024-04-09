// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../../Constants.sol";
import "../PCVDeposit.sol";
import "./IGauge.sol";
import "./IRouter.sol";
import "../../refs/CoreRef.sol";

contract StablePCVDeposit is PCVDeposit {
    // ------------------ Properties -------------------------------------------

    /// @notice maximum slippage accepted during deposit / withdraw, expressed
    /// in basis points (100% = 10_000).
    uint256 public maxSlippageBasisPoints;

    /// @notice The pool to deposit in
    IERC20 public liquidityPool;

    /// @notice The PCV holding contract for holding Reward Token
    IPCVDeposit public rewardTokenHolding;

    /// @notice The underlying token
    IERC20 public token;

    /// @notice The gauge to deposit pool tokens in
    IGauge public gauge;

    /// @notice The Router
    IRouter public router;

    /// @notice reward token address
    address public rewardToken;

    uint256 public CONVERSION_MULTI;

    // ------------------ Constructor ------------------------------------------

    /// @notice StablePCVDeposit constructor
    /// @param _core Core for reference
    /// @param _liquidityPool The Liquidity Pool to deposit in
    /// @param _maxSlippageBasisPoints max slippage for deposits, in bp
    /// @param _token The underlying token address
    /// @param _router The router address
    /// @param _gauge The gauge's address for deposisting LP tokens in
    constructor(
        address _core,
        address _liquidityPool,
        uint256 _maxSlippageBasisPoints,
        address _token,
        address _router,
        address _gauge,
        address _rewardTokenHolding,
        address _rewardToken,
        uint256 _CONVERSION_MULTI
    ) CoreRef(_core) {
        liquidityPool = IERC20(_liquidityPool);
        maxSlippageBasisPoints = _maxSlippageBasisPoints;
        token = IERC20(_token);
        router = IRouter(_router);
        gauge = IGauge(_gauge);
        rewardTokenHolding = IPCVDeposit(_rewardTokenHolding);
        rewardToken = _rewardToken;
        CONVERSION_MULTI = _CONVERSION_MULTI;
    }

    /// @notice No-op deposit
    function deposit() external override whenNotPaused {
        emit Deposit(msg.sender, balance());
    }

    function addLiquidity(uint256 amountChi, uint256 amountToken) public onlyGuardianOrPCVController whenNotPaused {
        uint256 lpTokenPrice = getLpTokenPrice();

        uint256 tokenBal = token.balanceOf(address(this));
        if (amountToken > tokenBal) amountToken = tokenBal;

        _mintChi(address(this), amountChi);

        chi().approve(address(router), amountChi);
        token.approve(address(router), amountToken);

        (uint256 chiSpent, uint256 tokenSpent, uint256 lpTokensReceived) = router.addLiquidity(
            address(chi()),
            address(token),
            true,
            amountChi,
            amountToken,
            0,
            0,
            address(this),
            block.timestamp
        );
        require(lpTokensReceived > 0, "No LP tokens received");

        uint256 totalValue = chiSpent + (tokenSpent * CONVERSION_MULTI);

        uint256 expectedLpTokens = (((totalValue * 1e18) / lpTokenPrice) *
            (Constants.BASIS_POINTS_GRANULARITY - maxSlippageBasisPoints)) / Constants.BASIS_POINTS_GRANULARITY;
        require(lpTokensReceived > expectedLpTokens, "LP slippage too high");

        liquidityPool.approve(address(gauge), liquidityPool.balanceOf(address(this)));
        gauge.deposit(liquidityPool.balanceOf(address(this)));

        //burns dust CHI from left from adding liquidity
        _burnChiHeld();
    }

    function removeLiquidity(uint256 amountChi) public onlyGuardianOrPCVController whenNotPaused {
        uint256 lpTokenPrice = getLpTokenPrice();

        uint256 liquidityToWithdraw = (amountChi * 1e18) / lpTokenPrice;

        uint256 ownedLiquidity = gauge.balanceOf(address(this));

        if (liquidityToWithdraw > ownedLiquidity) liquidityToWithdraw = ownedLiquidity;
        gauge.withdraw(liquidityToWithdraw);

        liquidityPool.approve(address(router), liquidityToWithdraw);
        (uint recievedChi, uint recievedToken) = router.removeLiquidity(
            address(chi()),
            address(token),
            true,
            liquidityToWithdraw,
            0,
            0,
            address(this),
            block.timestamp
        );

        uint totalReceived = recievedChi + (recievedToken * CONVERSION_MULTI);

        require(
            ((amountChi * (Constants.BASIS_POINTS_GRANULARITY - maxSlippageBasisPoints)) /
                Constants.BASIS_POINTS_GRANULARITY) < totalReceived,
            "LP slippage too high"
        );

        //burns CHI from removed from liquidity pool
        _burnChiHeld();
    }

    /// @notice returns total balance of PCV in the Deposit excluding the CHI
    function balance() public view override returns (uint256) {
        uint256 ownedLPtokens = gauge.balanceOf(address(this));
        if (ownedLPtokens == 0) return (0);
        (, uint tokenBalinOwnedLP) = router.quoteRemoveLiquidity(address(chi()), address(token), true, ownedLPtokens);
        uint256 tokenBal = token.balanceOf(address(this));
        return (tokenBalinOwnedLP + tokenBal);
    }

    function balanceReportedIn() public view override returns (address) {
        return address(token);
    }

    /// @notice returns the resistant balance of PCV and CHI held by the contract
    function resistantBalanceAndChi() public view override returns (uint256 resistantBalance, uint256 resistantChi) {
        uint256 lpTokensStaked = gauge.balanceOf(address(this));
        if (lpTokensStaked == 0) return (0,0);
        uint256 lpTokenPrice = getLpTokenPrice();
        resistantBalance = (lpTokensStaked * lpTokenPrice) / 1e18;

        // to have a resistant balance, we assume the pool is balanced, e.g. if
        // the pool holds 2 tokens, we assume CHI is 50% of the pool.
        resistantChi = resistantBalance / 2;
        resistantBalance -= resistantChi;
        uint256 tokenBal = token.balanceOf(address(this));
        return (((resistantBalance / CONVERSION_MULTI) + tokenBal), resistantChi);
    }

    function claimGaugeRewards() external {
        gauge.getReward();

        IERC20(rewardToken).transfer(address(rewardTokenHolding), IERC20(rewardToken).balanceOf(address(this)));
    }

    /**
     * @notice Swap `tokenAmount` of 'token' to CHI
     * @param tokenAmount Amount of 'token' to swap to CHI
     */
    function swapToChi(uint tokenAmount) public onlyGuardianOrPCVController whenNotPaused {
        //Assumes token has 18 decimals
        uint minOut = ((tokenAmount * (Constants.BASIS_POINTS_GRANULARITY - maxSlippageBasisPoints)) /
            Constants.BASIS_POINTS_GRANULARITY) * CONVERSION_MULTI;

        token.approve(address(router), tokenAmount);

        router.swapExactTokensForTokens(
            tokenAmount,
            minOut,
            getRoute(address(token), address(chi())),
            address(this),
            block.timestamp
        );
        //Burns CHI recieved
        _burnChiHeld();
    }

    function swapFromChi(uint chiAmount) public onlyGuardianOrPCVController whenNotPaused {
        //Assumes token has 18 decimals
        uint minOut = (chiAmount * (Constants.BASIS_POINTS_GRANULARITY - maxSlippageBasisPoints)) /
            Constants.BASIS_POINTS_GRANULARITY /
            CONVERSION_MULTI;

        _mintChi(address(this), chiAmount);
        chi().approve(address(router), chiAmount);
        router.swapExactTokensForTokens(
            chiAmount,
            minOut,
            getRoute(address(chi()), address(token)),
            address(this),
            block.timestamp
        );
        //Burns any dust CHI left
        _burnChiHeld();
    }

    /// @notice Sets the maximum slippage accepted.
    /// @param _maxSlippageBasisPoints the maximum slippage expressed in basis points (1/10_000)
    function setMaximumSlippage(uint256 _maxSlippageBasisPoints) external onlyGuardianOrGovernor {
        require(
            _maxSlippageBasisPoints <= Constants.BASIS_POINTS_GRANULARITY,
            "StablePCVDeposit: Exceeds bp granularity."
        );
        maxSlippageBasisPoints = _maxSlippageBasisPoints;
    }

    /// @notice withdraw assets from PCVDeposit to an external address
    function withdraw(address to, uint256 amount) public override onlyPCVController whenNotPaused {
        _withdrawERC20(address(token), to, amount);
    }

    function getLpTokenPrice() internal view returns (uint) {
        (uint chiAmtPerLp, uint tokenAmtPerLp) = router.quoteRemoveLiquidity(
            address(chi()),
            address(token),
            true,
            0.001 ether
        );
        tokenAmtPerLp *= CONVERSION_MULTI;
        return (chiAmtPerLp + tokenAmtPerLp) * 1000;
    }

    /**
     * @notice Generate route array for swap between two stablecoins
     * @param from Token to go from
     * @param to Token to go to
     * @return Returns a Route[] with a single element, representing the route
     */
    function getRoute(address from, address to) internal pure returns (IRouter.route[] memory) {
        IRouter.route memory route = IRouter.route(from, to, true);
        IRouter.route[] memory routeArray = new IRouter.route[](1);
        routeArray[0] = route;
        return routeArray;
    }
}
