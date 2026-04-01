// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

/// @title BalancerBptAdapter
/// @notice Adapter for the Euler Swapper's GenericHandler to perform single-sided
///         Balancer V3 addLiquidityUnbalanced with optional ERC4626 wrapping.
///
///         Flow when called via Swapper.multicall → GenericHandler:
///         1. Swapper transfers underlying tokens to this adapter
///         2. If the token needs wrapping (ERC4626), adapter deposits into the wrapper
///         3. Adapter approves wrapped tokens to Permit2, then Permit2-approves to Router
///         4. Calls addLiquidityUnbalanced with single-sided deposit
///         5. Transfers resulting BPT to msg.sender (the Swapper)
///
///         Deployed once per pool. Stateless — holds no tokens between calls.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function asset() external view returns (address);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IBalancerRouter {
    function addLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256 bptAmountOut);

    function removeLiquiditySingleTokenExactIn(
        address pool,
        uint256 exactBptAmountIn,
        address tokenOut,
        uint256 minAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256 amountOut);
}

contract BalancerBptAdapter {
    address public immutable balancerRouter;
    address public immutable pool; // also the BPT token
    uint256 public immutable numTokens;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint48 constant MAX_EXPIRATION = type(uint48).max;
    uint160 constant MAX_ALLOWANCE = type(uint160).max;

    struct TokenConfig {
        address poolToken;
        address underlying;
        bool needsWrap;
    }

    TokenConfig[] private tokenConfigs;

    error ZeroAmount();
    error InvalidTokenIndex();
    error NoBptReceived();

    constructor(
        address _balancerRouter,
        address _pool,
        TokenConfig[] memory _tokenConfigs
    ) {
        balancerRouter = _balancerRouter;
        pool = _pool;
        numTokens = _tokenConfigs.length;

        for (uint256 i = 0; i < _tokenConfigs.length; i++) {
            tokenConfigs.push(_tokenConfigs[i]);
            // Pre-approve each pool token to Permit2 (max, one-time)
            IERC20(_tokenConfigs[i].poolToken).approve(PERMIT2, type(uint256).max);
        }

        // Pre-approve BPT to Permit2 for removeLiquidity
        IERC20(_pool).approve(PERMIT2, type(uint256).max);
    }

    /// @notice Deposit a single underlying token into the Balancer pool and return BPT.
    function zapIn(
        uint256 tokenIndex,
        uint256 amount,
        uint256 minBptOut
    ) external returns (uint256 bptOut) {
        if (amount == 0) revert ZeroAmount();
        if (tokenIndex >= numTokens) revert InvalidTokenIndex();

        TokenConfig memory cfg = tokenConfigs[tokenIndex];

        IERC20(cfg.underlying).transferFrom(msg.sender, address(this), amount);

        uint256 poolTokenAmount;
        if (cfg.needsWrap) {
            IERC20(cfg.underlying).approve(cfg.poolToken, amount);
            poolTokenAmount = IERC4626(cfg.poolToken).deposit(amount, address(this));
        } else {
            poolTokenAmount = amount;
        }

        // Permit2-approve the pool token to the Balancer Router
        IPermit2(PERMIT2).approve(cfg.poolToken, balancerRouter, MAX_ALLOWANCE, MAX_EXPIRATION);

        uint256[] memory maxAmountsIn = new uint256[](numTokens);
        maxAmountsIn[tokenIndex] = poolTokenAmount;

        IBalancerRouter(balancerRouter).addLiquidityUnbalanced(
            pool,
            maxAmountsIn,
            minBptOut,
            false,
            ""
        );

        bptOut = IERC20(pool).balanceOf(address(this));
        if (bptOut == 0) revert NoBptReceived();
        IERC20(pool).transfer(msg.sender, bptOut);
    }

    /// @notice Remove liquidity from the Balancer pool and return a single underlying token.
    function zapOut(
        uint256 tokenIndex,
        uint256 bptAmount,
        uint256 minOut
    ) external returns (uint256 amountOut) {
        if (bptAmount == 0) revert ZeroAmount();
        if (tokenIndex >= numTokens) revert InvalidTokenIndex();

        TokenConfig memory cfg = tokenConfigs[tokenIndex];

        IERC20(pool).transferFrom(msg.sender, address(this), bptAmount);

        // BPT removal uses direct ERC20 approve (not Permit2)
        IERC20(pool).approve(balancerRouter, bptAmount);

        uint256 poolTokenOut = IBalancerRouter(balancerRouter).removeLiquiditySingleTokenExactIn(
            pool,
            bptAmount,
            cfg.poolToken,
            1,
            false,
            ""
        );

        if (cfg.needsWrap) {
            amountOut = IERC4626(cfg.poolToken).redeem(poolTokenOut, msg.sender, address(this));
        } else {
            amountOut = poolTokenOut;
            IERC20(cfg.poolToken).transfer(msg.sender, amountOut);
        }

        if (amountOut < minOut) revert ZeroAmount();
    }

    function getTokenConfig(uint256 index) external view returns (TokenConfig memory) {
        return tokenConfigs[index];
    }
}
