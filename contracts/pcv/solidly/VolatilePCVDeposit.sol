// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

import "../../Constants.sol";
import "../PCVDeposit.sol";
import "./IGauge.sol";
import "./IRouter.sol";
import "../../refs/CoreRef.sol";

contract VolatilePCVDeposit is PCVDeposit {


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


    // ------------------ Constructor ------------------------------------------

    /// @notice VolatilePCVDeposit constructor
    /// @param _core Core for reference
    /// @param _liquidityPool The pool to deposit in
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
        address _rewardToken
        
    ) CoreRef(_core) {
        liquidityPool = IERC20(_liquidityPool);
        maxSlippageBasisPoints = _maxSlippageBasisPoints;
        token = IERC20(_token);
        router = IRouter(_router);
        gauge = IGauge(_gauge);
        rewardTokenHolding = IPCVDeposit(_rewardTokenHolding);
        rewardToken = _rewardToken;

    }

    function deposit() external override whenNotPaused {
        emit Deposit(msg.sender, balance());
    }
    function addLiquidity(uint256 amountToken,uint256 amountChi,uint256 minToken,uint256 minChi) public onlyGuardianOrPCVController whenNotPaused {

        _mintChi(address(this), amountChi);

        chi().approve(address(router), amountChi);
        token.approve(address(router), amountToken);

        router.addLiquidity( address(token), address(chi()), false, amountToken, amountChi, minToken, minChi, address(this), block.timestamp);

        //burns dust CHI from left from adding liquidity
        _burnChiHeld();
    }

    function depositToGauge(uint256 amountToStake) public onlyGuardianOrPCVController whenNotPaused {
        
        liquidityPool.approve(address(gauge), amountToStake);
        gauge.deposit(amountToStake);
    }

    function depositAllToGauge() public onlyGuardianOrPCVController whenNotPaused {
        
        liquidityPool.approve(address(gauge), liquidityPool.balanceOf(address(this)));
        gauge.deposit(liquidityPool.balanceOf(address(this)));
    }

    function removeLiquidity(uint256 liquidityToWithdraw,  uint256 minChi, uint256 minToken) public onlyGuardianOrPCVController whenNotPaused {
        uint256 ownedLiquidity = gauge.balanceOf(address(this));
        require(ownedLiquidity > 0, 'VolatilePCVDeposit: No Lp Tokens Staked');
        if (liquidityToWithdraw > ownedLiquidity) liquidityToWithdraw = ownedLiquidity;
        gauge.withdraw(liquidityToWithdraw);

        liquidityPool.approve(address(router), liquidityToWithdraw);
        router.removeLiquidity(address(chi()), address(token), false, liquidityToWithdraw, minChi, minToken, address(this), block.timestamp);

        //burns CHI from removed from liquidity pool
        _burnChiHeld();
    }

    /// @notice returns total balance of PCV in the Deposit excluding the CHI
    function balance() public view override returns (uint256) {
         uint256 ownedLPtokens = gauge.balanceOf(address(this));
         if (ownedLPtokens == 0) return (0);
         (, uint tokenBalinOwnedLP) = router.quoteRemoveLiquidity(address(chi()), address(token), false, ownedLPtokens);
        return tokenBalinOwnedLP;
    }

    function balanceReportedIn() public view override returns (address) {
        return address(token);
    }
    /// @notice returns the resistant balance of PCV and CHI held by the contract
    function resistantBalanceAndChi() public view override returns (
        uint256 resistantBalance,
        uint256 resistantChi
    ) {
        uint256 lpTokensStaked = gauge.balanceOf(address(this));
        if (lpTokensStaked == 0) return (0,0);
        (uint256 chiBal, uint256 tokenBal) = router.quoteRemoveLiquidity(address(chi()), address(token), false, lpTokensStaked);
        resistantBalance =  tokenBal;
        resistantChi =   chiBal;
        return (resistantBalance, resistantChi);
    }  

    function claimGaugeRewards() external {
        uint256  prevTokenBalance = IERC20(rewardToken).balanceOf(address(this));
        gauge.getReward();
        uint256 newTokenBalance = IERC20(rewardToken).balanceOf(address(this));

        IERC20(rewardToken).transfer(address(rewardTokenHolding), (newTokenBalance-prevTokenBalance));
    }

    /// @notice Sets the maximum slippage accepted.
    /// @param _maxSlippageBasisPoints the maximum slippage expressed in basis points (1/10_000)
    function setMaximumSlippage(uint256 _maxSlippageBasisPoints) external onlyGuardianOrGovernor {
        require(_maxSlippageBasisPoints <= Constants.BASIS_POINTS_GRANULARITY, "VolatilePCVDeposit: Exceeds bp granularity.");
        maxSlippageBasisPoints = _maxSlippageBasisPoints;
    }
    /// @notice withdraw assets from PCVDeposit to an external address
    function withdraw(address to, uint256 amount) public override onlyPCVController whenNotPaused {
        _withdrawERC20(address(token), to, amount);
    }

}