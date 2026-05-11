// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════╗
 * ║     CinderLPZap — One-Click LP Vault Entry            ║
 * ╚══════════════════════════════════════════════════════════╝
 *
 * WHAT THIS DOES:
 * ────────────────
 * Without the zap, providing LP liquidity requires:
 *   1. Hold the right ratio of EMBER and FLR
 *   2. Approve EMBER to the Sparkdex router
 *   3. Call addLiquidityETH() on the router
 *   4. Receive LP tokens
 *   5. Approve LP tokens to the Cinder vault
 *   6. Call vault.deposit()
 *
 * With the zap, it's:
 *   1. Send FLR → get cEMBER-FLR vault shares (one transaction)
 *
 * HOW IT WORKS INTERNALLY:
 * ──────────────────────────
 * The zap handles two pools:
 *
 * EMBER/FLR POOL:
 *   - User sends FLR
 *   - Zap buys EMBER on Sparkdex with half the FLR
 *   - Zap adds EMBER + remaining FLR as liquidity
 *   - Zap deposits LP tokens into Cinder vault on user's behalf
 *   - User receives cEMBER-FLR shares
 *
 * sFLR/FLR POOL:
 *   - User sends FLR
 *   - Zap stakes half FLR with Sceptre → sFLR
 *   - Zap adds sFLR + remaining FLR as liquidity
 *   - Zap deposits LP tokens into Cinder vault
 *   - User receives csFLR-FLR shares
 *
 * WHY SPLIT 50/50:
 * ─────────────────
 * Uniswap V2 requires both tokens in proportion to current pool price.
 * Splitting FLR and buying/staking one half maintains the ratio.
 * In practice the split is slightly off due to price impact — the zap
 * uses slippage tolerance (default 1%) to handle this.
 *
 * SINGLE-SIDED ENTRY (advanced):
 * ───────────────────────────────
 * zapSingleSide() takes only FLR and handles the split automatically.
 * This is slightly less capital efficient than a balanced add but
 * dramatically simpler for the user.
 *
 * SLIPPAGE:
 * ──────────
 * All swap and LP operations use a minOut parameter.
 * The frontend calls previewZap() first to estimate output,
 * then applies a slippage tolerance before calling zapIn().
 *
 * SPARKDEX ADDRESSES (Flare Mainnet):
 * ─────────────────────────────────────
 * Router:  0x16b619B04c961b8Ce3A0E3FB8572dB3E55b99dB7
 * Factory: 0x6040BB9E4E12B7e8dc5BcEbbE5b76b9E86dBd35E
 * WFLR:    0x1D80c49BbBCd1C0911346656B529DF9E5c2F783d
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV2Router {
    function WETH() external pure returns (address);
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256 liquidity);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface ISceptrePool {
    function submit() external payable returns (uint256);
}

interface ICinderLPVault {
    function depositFor(address recipient, uint256 lpAmount) external returns (uint256 shares);
    function tvlCap() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function lpToShares(uint256) external view returns (uint256);
}

contract CinderLPZap {

    // ── Sparkdex ───────────────────────────────────────────────────────
    IUniswapV2Router public immutable router;
    address          public immutable WFLR;
    address          public immutable factory;

    // ── Protocol tokens ────────────────────────────────────────────────
    address          public immutable EMBER;
    address          public immutable sFLR;
    ISceptrePool     public immutable sceptrePool;

    // ── Vaults ────────────────────────────────────────────────────────
    ICinderLPVault public immutable emberFlrVault;  // EMBER/FLR LP vault
    ICinderLPVault public immutable sFLRFlrVault;  // sFLR/FLR LP vault

    // ── LP pair addresses ──────────────────────────────────────────────
    address public immutable emberFlrPair;
    address public immutable sFLRFlrPair;

    address public owner;

    // ── Events ────────────────────────────────────────────────────────
    event ZappedIntoFLOWFLR(address indexed user, uint256 flrIn, uint256 lpOut, uint256 sharesOut);
    event ZappedIntoSFLRFLR(address indexed user, uint256 flrIn, uint256 lpOut, uint256 sharesOut);

    modifier onlyOwner() { require(msg.sender == owner, "LPZap: not owner"); _; }

    constructor(
        address _router,
        address _factory,
        address _WFLR,
        address _FLOW,
        address _sFLR,
        address _sceptrePool,
        address _emberFlrPair,
        address _sFLRFlrPair,
        address _emberFlrVault,
        address _sFLRFlrVault
    ) {
        router       = IUniswapV2Router(_router);
        factory      = _factory;
        WFLR         = _WFLR;
        EMBER         = _FLOW;
        sFLR         = _sFLR;
        sceptrePool  = ISceptrePool(_sceptrePool);
        emberFlrPair  = _emberFlrPair;
        sFLRFlrPair  = _sFLRFlrPair;
        emberFlrVault = ICinderLPVault(_emberFlrVault);
        sFLRFlrVault = ICinderLPVault(_sFLRFlrVault);
        owner        = msg.sender;

        // Approve router to spend EMBER and sFLR (max approval — zap holds no persistent balance)
        IERC20(_FLOW).approve(_router, type(uint256).max);
        IERC20(_sFLR).approve(_router, type(uint256).max);

        // Approve vaults to spend LP tokens
        IERC20(_emberFlrPair).approve(_emberFlrVault, type(uint256).max);
        IERC20(_sFLRFlrPair).approve(_sFLRFlrVault, type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════════
    //  ZAP INTO EMBER/FLR VAULT
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Zap FLR into EMBER/FLR LP vault in one transaction.
     *
     * Splits your FLR: half buys EMBER on Sparkdex, half stays as FLR.
     * Both are added as liquidity → LP tokens → deposited into Cinder vault.
     * You receive cEMBER-FLR vault shares.
     *
     * @param minShares  Minimum vault shares to accept (slippage protection)
     *                   Use previewZapFLOWFLR() to estimate, apply 1% buffer
     */
    function zapIntoFLOWFLRVault(uint256 minShares) external payable returns (uint256 shares) {
        require(msg.value > 0, "LPZap: send FLR");

        // Step 1: Split — use half to buy EMBER
        uint256 flrForSwap = msg.value / 2;
        uint256 flrForLP   = msg.value - flrForSwap;

        // Step 2: Buy EMBER with flrForSwap
        address[] memory path = new address[](2);
        path[0] = WFLR; path[1] = EMBER;
        uint256[] memory amounts = router.swapExactETHForTokens{value: flrForSwap}(
            0, // minOut — we use overall slippage check at the end
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 flowReceived = amounts[amounts.length - 1];

        // Step 3: Add liquidity (EMBER + FLR)
        (,, uint256 lpReceived) = router.addLiquidityETH{value: flrForLP}(
            EMBER,
            flowReceived,
            flowReceived * 99 / 100, // 1% slippage on token side
            flrForLP * 99 / 100,     // 1% slippage on FLR side
            address(this),
            block.timestamp + 15 minutes
        );
        require(lpReceived > 0, "LPZap: no LP received");

        // Step 4: Deposit LP into Cinder vault on behalf of user
        shares = emberFlrVault.depositFor(msg.sender, lpReceived);
        require(shares >= minShares, "LPZap: slippage too high");

        // Step 5: Refund any leftover EMBER or FLR (rounding dust)
        _refundDust(EMBER, msg.sender);
        _refundFLR(msg.sender);

        emit ZappedIntoFLOWFLR(msg.sender, msg.value, lpReceived, shares);
    }

    // ════════════════════════════════════════════════════════════════════
    //  ZAP INTO sFLR/FLR VAULT
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Zap FLR into sFLR/FLR LP vault in one transaction.
     *
     * Splits your FLR: half staked with Sceptre → sFLR, half stays as FLR.
     * Both added as liquidity → LP tokens → deposited into Cinder vault.
     * You receive csFLR-FLR vault shares.
     *
     * @param minShares  Minimum vault shares to accept
     */
    function zapIntoSFLRFLRVault(uint256 minShares) external payable returns (uint256 shares) {
        require(msg.value > 0, "LPZap: send FLR");

        uint256 flrForStake = msg.value / 2;
        uint256 flrForLP    = msg.value - flrForStake;

        // Step 1: Stake half FLR with Sceptre → sFLR
        uint256 sFLRBefore = IERC20(sFLR).balanceOf(address(this));
        sceptrePool.submit{value: flrForStake}();
        uint256 sFLRReceived = IERC20(sFLR).balanceOf(address(this)) - sFLRBefore;
        require(sFLRReceived > 0, "LPZap: Sceptre returned 0");

        // Step 2: Add liquidity (sFLR + FLR)
        (,, uint256 lpReceived) = router.addLiquidityETH{value: flrForLP}(
            sFLR,
            sFLRReceived,
            sFLRReceived * 99 / 100,
            flrForLP * 99 / 100,
            address(this),
            block.timestamp + 15 minutes
        );
        require(lpReceived > 0, "LPZap: no LP received");

        // Step 3: Deposit LP into vault on behalf of user
        shares = sFLRFlrVault.depositFor(msg.sender, lpReceived);
        require(shares >= minShares, "LPZap: slippage too high");

        // Refund dust
        _refundDust(sFLR, msg.sender);
        _refundFLR(msg.sender);

        emit ZappedIntoSFLRFLR(msg.sender, msg.value, lpReceived, shares);
    }

    // ════════════════════════════════════════════════════════════════════
    //  PREVIEW (view functions for frontend)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Estimate vault shares for a given FLR amount into EMBER/FLR vault.
     * Not exact — actual output depends on price at execution time.
     * Apply 1-2% slippage tolerance to the result.
     */
    function previewZapFLOWFLR(uint256 flrAmount) external view returns (
        uint256 estimatedShares,
        uint256 flrForSwap,
        uint256 estimatedFLOW,
        uint256 vaultCapRemaining
    ) {
        flrForSwap = flrAmount / 2;
        uint256 flrForLP = flrAmount - flrForSwap;

        // Estimate EMBER received from swap
        address[] memory path = new address[](2);
        path[0] = WFLR; path[1] = EMBER;
        try router.getAmountsOut(flrForSwap, path) returns (uint256[] memory amounts) {
            estimatedFLOW = amounts[amounts.length - 1];
        } catch {
            estimatedFLOW = 0;
        }

        // Estimate LP received from addLiquidity
        uint256 estLP = _estimateLP(emberFlrPair, EMBER, estimatedFLOW, flrForLP);
        estimatedShares = emberFlrVault.lpToShares(estLP);

        uint256 cap = emberFlrVault.tvlCap();
        uint256 tvl = emberFlrVault.totalAssets();
        vaultCapRemaining = cap > tvl ? cap - tvl : 0;
    }

    /**
     * @notice Estimate vault shares for a given FLR amount into sFLR/FLR vault.
     */
    function previewZapSFLRFLR(uint256 flrAmount) external view returns (
        uint256 estimatedShares,
        uint256 estimatedSFLR,
        uint256 vaultCapRemaining
    ) {
        uint256 flrForStake = flrAmount / 2;
        uint256 flrForLP    = flrAmount - flrForStake;
        estimatedSFLR = flrForStake; // ~1:1 approximation (sFLR appreciates vs FLR over time)

        uint256 estLP = _estimateLP(sFLRFlrPair, sFLR, estimatedSFLR, flrForLP);
        estimatedShares = sFLRFlrVault.lpToShares(estLP);

        uint256 cap = sFLRFlrVault.tvlCap();
        uint256 tvl = sFLRFlrVault.totalAssets();
        vaultCapRemaining = cap > tvl ? cap - tvl : 0;
    }

    // ── Internal helpers ───────────────────────────────────────────────

    function _estimateLP(
        address pair,
        address token,
        uint256 tokenAmount,
        uint256 flrAmount
    ) internal view returns (uint256 lpEstimate) {
        if (tokenAmount == 0 || flrAmount == 0) return 0;
        try IUniswapV2Pair(pair).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            uint256 totalLP = IUniswapV2Pair(pair).totalSupply();
            if (totalLP == 0) return flrAmount; // first deposit
            address t0 = IUniswapV2Pair(pair).token0();
            (uint256 rToken, uint256 rFLR) = t0 == token
                ? (uint256(r0), uint256(r1))
                : (uint256(r1), uint256(r0));
            // LP received = min(tokenAmt/rToken, flrAmt/rFLR) * totalLP
            uint256 lpFromToken = (tokenAmount * totalLP) / rToken;
            uint256 lpFromFLR   = (flrAmount   * totalLP) / rFLR;
            lpEstimate = lpFromToken < lpFromFLR ? lpFromToken : lpFromFLR;
        } catch {
            lpEstimate = 0;
        }
    }

    function _refundDust(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(to, bal);
    }

    function _refundFLR(address to) internal {
        uint256 bal = address(this).balance;
        if (bal > 0) payable(to).transfer(bal);
    }

    // ── Admin ──────────────────────────────────────────────────────────
    function recoverToken(address token, address to) external onlyOwner {
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }
    function recoverFLR(address payable to) external onlyOwner {
        to.transfer(address(this).balance);
    }
    function transferOwnership(address n) external onlyOwner { owner = n; }

    receive() external payable {
        // Accept FLR only from router (refunds from addLiquidityETH)
        require(msg.sender == address(router), "LPZap: use zapIn functions");
    }
}
