// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════╗
 * ║     EmberGelatoResolver — Automated Keeper            ║
 * ╚══════════════════════════════════════════════════════╝
 *
 * WHAT THIS REPLACES:
 * ────────────────────
 * Your keeper bot + VPS server. Instead of running a Node.js
 * process 24/7 on a $6/mo server, Gelato Network runs the
 * harvest calls for you — on-chain, decentralized, reliable.
 *
 * HOW GELATO WORKS:
 * ──────────────────
 * 1. You deploy this Resolver contract
 * 2. You register a task on https://app.gelato.network
 * 3. Gelato calls checker() every ~10 seconds
 * 4. When checker() returns (true, calldata), Gelato executes it
 * 5. You pay Gelato a small fee in GELATO1 token (or FLR via relay)
 *
 * COST:
 * ──────
 * Gelato charges ~$0.01-0.10 per execution depending on gas.
 * At 1 harvest/day: ~$3-30/month. Much cheaper than a VPS
 * for low-TVL protocols. At high TVL you'd switch to a VPS anyway.
 *
 * SETUP (10 minutes):
 * ────────────────────
 * 1. Deploy this contract to Flare Mainnet
 * 2. Go to https://app.gelato.network
 * 3. Connect wallet → Create Task
 * 4. Resolver: this contract address
 * 5. Function: checker()
 * 6. Set time interval: every 1 hour (Gelato will skip if not needed)
 * 7. Fund your Gelato balance with some FLR
 * 8. Done — harvests happen automatically forever
 *
 * GELATO ON FLARE:
 * ─────────────────
 * Gelato supports Flare Mainnet (chainId 14).
 * Check https://docs.gelato.network/developer-services/automate/supported-networks
 */

interface ICinderVault {
    function harvest() external returns (uint256 yieldAmount, uint256 feeAmount);
    function getVaultStats() external view returns (
        uint256 tvl,
        uint256 totalShares,
        uint256 pricePerShare,
        uint256 pendingYield,
        uint256 lifetimeYield,
        uint256 lifetimeFees,
        uint256 lastHarvest
    );
}

interface IEmberMining {
    function advanceEpoch() external;
    function currentEpoch() external view returns (uint256);
    function epochStartTime() external view returns (uint256);
    function epochs(uint256) external view returns (uint256 duration, uint256 totalFlow);
}

contract EmberGelatoResolver {

    // ── Config ─────────────────────────────────────────────────────────
    ICinderVault public immutable vault;
    IEmberMining     public immutable mining;
    address         public owner;

    // Minimum pending yield before harvesting (saves gas on tiny yields)
    uint256 public minYieldThreshold = 0.5e18; // 0.5 stXRP

    // Minimum time between harvests even if yield is above threshold
    uint256 public minHarvestInterval = 6 hours;

    // ── Stats ──────────────────────────────────────────────────────────
    uint256 public lastHarvestTime;
    uint256 public harvestCount;
    uint256 public totalYieldCollected;

    event Harvested(uint256 yield, uint256 fee, uint256 timestamp);
    event EpochAdvanced(uint256 newEpoch);
    event ThresholdUpdated(uint256 newThreshold);

    modifier onlyOwner() { require(msg.sender == owner, "Resolver: not owner"); _; }

    constructor(address _vault, address _mining) {
        vault  = ICinderVault(_vault);
        mining = IEmberMining(_mining);
        owner  = msg.sender;
    }

    // ════════════════════════════════════════════════════════════════════
    //  GELATO RESOLVER INTERFACE
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Gelato calls this every ~10s to check if work needs doing.
     * Returns (true, calldata) when harvest should run.
     * Returns (false, "") when nothing to do.
     *
     * This is the core of the Gelato integration. Gelato reads canExec
     * and if true, submits the execPayload transaction on your behalf.
     */
    function checker() external view returns (bool canExec, bytes memory execPayload) {

        // ── Check 1: Should we harvest? ────────────────────────────────
        (bool shouldHarvest, uint256 pendingYield) = _shouldHarvest();
        if (shouldHarvest) {
            return (true, abi.encodeWithSelector(this.runHarvest.selector));
        }

        // ── Check 2: Should we advance the mining epoch? ───────────────
        if (_shouldAdvanceEpoch()) {
            return (true, abi.encodeWithSelector(this.runAdvanceEpoch.selector));
        }

        return (false, bytes(""));
    }

    function _shouldHarvest() internal view returns (bool, uint256) {
        // Rate limit: don't harvest more than once per minHarvestInterval
        if (block.timestamp < lastHarvestTime + minHarvestInterval) {
            return (false, 0);
        }
        try vault.getVaultStats() returns (
            uint256, uint256, uint256, uint256 pendingYield, uint256, uint256, uint256
        ) {
            return (pendingYield >= minYieldThreshold, pendingYield);
        } catch {
            return (false, 0);
        }
    }

    function _shouldAdvanceEpoch() internal view returns (bool) {
        try mining.currentEpoch() returns (uint256 epoch) {
            if (epoch >= 3) return false; // all 4 epochs complete
            try mining.epochStartTime() returns (uint256 startTime) {
                (uint256 duration,) = mining.epochs(epoch);
                return block.timestamp >= startTime + duration;
            } catch { return false; }
        } catch { return false; }
    }

    // ════════════════════════════════════════════════════════════════════
    //  EXECUTION FUNCTIONS (called by Gelato, or anyone)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Execute harvest. Called by Gelato when checker() returns true.
     * Also callable by anyone directly (permissionless).
     */
    function runHarvest() external {
        (uint256 yieldAmt, uint256 feeAmt) = vault.harvest();
        lastHarvestTime     = block.timestamp;
        harvestCount++;
        totalYieldCollected += yieldAmt;
        emit Harvested(yieldAmt, feeAmt, block.timestamp);
    }

    /**
     * @notice Advance mining epoch. Called by Gelato or anyone.
     */
    function runAdvanceEpoch() external {
        uint256 newEpoch = mining.currentEpoch() + 1;
        mining.advanceEpoch();
        emit EpochAdvanced(newEpoch);
    }

    // ════════════════════════════════════════════════════════════════════
    //  VIEW
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Dashboard data for monitoring.
     */
    function getStatus() external view returns (
        uint256 _pendingYield,
        bool    _shouldHarvestNow,
        uint256 _lastHarvest,
        uint256 _harvestCount,
        uint256 _totalYield,
        uint256 _currentEpoch,
        bool    _epochReadyToAdvance
    ) {
        (bool sh, uint256 py) = _shouldHarvest();
        return (
            py,
            sh,
            lastHarvestTime,
            harvestCount,
            totalYieldCollected,
            mining.currentEpoch(),
            _shouldAdvanceEpoch()
        );
    }

    // ── Admin ──────────────────────────────────────────────────────────
    function setMinYield(uint256 threshold) external onlyOwner {
        minYieldThreshold = threshold;
        emit ThresholdUpdated(threshold);
    }
    function setMinInterval(uint256 interval) external onlyOwner {
        require(interval >= 1 hours && interval <= 24 hours, "Resolver: invalid interval");
        minHarvestInterval = interval;
    }
    function transferOwnership(address newOwner) external onlyOwner { owner = newOwner; }
}
