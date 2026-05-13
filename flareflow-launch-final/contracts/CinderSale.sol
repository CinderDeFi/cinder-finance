// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════╗
 * ║           CinderSale - EMBER Public Token Sale          ║
 * ╚══════════════════════════════════════════════════════╝
 *
 * WHAT THIS DOES (plain English):
 * ──────────────────────────────────
 * Sells 150,000,000 EMBER tokens for FLR (Flare's native token).
 * After the sale ends, buyers claim their EMBER linearly over 6 months.
 * If the softcap isn't hit, everyone can get a full refund.
 *
 * THE DEAL:
 * ─────────
 * - Pay FLR → receive EMBER allocation
 * - EMBER vests linearly over 6 months after sale ends (no cliff)
 * - Softcap: 500,000 FLR - if not reached, full refunds available
 * - Hardcap: 5,000,000 FLR - sale closes when hit
 * - Price: 1 FLR = 10 EMBER (so 1 EMBER = 0.1 FLR)
 *   At FLR = $0.01, that prices EMBER at ~$0.001 at launch
 *   Repriced from 30→10 EMBER/FLR to account for FLR trading <$0.01
 * - Minimum buy: 1,000 FLR (~10,000 EMBER, ~$10)
 * - Maximum buy per wallet: 50,000 FLR (~$500) - prevents whale domination
 *
 * SAFETY FEATURES:
 * ─────────────────
 * 1. Softcap refund - if sale raises < 500K FLR, refund everything
 * 2. 6-month linear vest - prevents dump at listing
 * 3. Per-wallet cap - keeps distribution fair
 * 4. Owner can pause (for emergencies only)
 * 5. FLR raised goes directly to treasury multisig on finalize
 *
 * TIMELINE:
 * ─────────
 * Day 0:     Owner calls startSale()
 * Day 0-14:  Public buys EMBER with FLR
 * Day 14:    Sale ends (or hardcap hit). Owner calls finalize()
 * Day 14+:   Buyers can claim() EMBER linearly over next 6 months
 * Day 196:   100% of purchased EMBER is claimable
 */

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract CinderSale {

    // ── Sale configuration ─────────────────────────────────────────────
    IERC20 public immutable flow;
    address public treasury;         // FLR raised goes here on finalize
    address public owner;

    uint256 public constant TOTAL_FOR_SALE  = 150_000_000e18;   // 150M EMBER
    uint256 public constant PRICE_PER_FLR   = 10e18;            // 10 EMBER per FLR - repriced for FLR < $0.01
    uint256 public constant SOFTCAP         = 500_000e18;        // 500K FLR
    uint256 public constant HARDCAP         = 5_000_000e18;      // 5M FLR
    uint256 public constant MIN_BUY         = 1_000e18;          // 1,000 FLR min (~$10 at $0.01/FLR)
    uint256 public constant MAX_BUY         = 50_000e18;         // 50K FLR max per wallet
    uint256 public constant SALE_DURATION   = 14 days;
    uint256 public constant VEST_DURATION   = 180 days;          // 6 month linear vest

    // ── State ──────────────────────────────────────────────────────────
    uint256 public saleStart;
    uint256 public saleEnd;
    uint256 public totalRaised;      // total FLR raised
    bool    public finalized;        // true after owner calls finalize()
    bool    public paused;

    mapping(address => uint256) public contributions;   // FLR paid per wallet
    mapping(address => uint256) public claimed;         // EMBER already claimed

    // ── Events ────────────────────────────────────────────────────────
    event Purchased(address indexed buyer, uint256 flrAmount, uint256 flowAmount);
    event Claimed(address indexed buyer, uint256 flowAmount);
    event Refunded(address indexed buyer, uint256 flrAmount);
    event SaleFinalized(uint256 totalRaised, bool softcapHit);
    event SaleStarted(uint256 startTime, uint256 endTime);

    modifier onlyOwner()  { require(msg.sender == owner, "Sale: not owner"); _; }
    modifier notPaused()  { require(!paused, "Sale: paused"); _; }
    modifier afterFinalize() { require(finalized, "Sale: not finalized"); _; }

    constructor(address _flow, address _treasury) {
        flow     = IERC20(_flow);
        treasury = _treasury;
        owner    = msg.sender;
    }

    // ════════════════════════════════════════════════════════════════════
    //  OWNER: MANAGE SALE
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Start the sale. Requires EMBER tokens to be in this contract first.
     * Call after sending 150M EMBER here from the CinderToken constructor allocation.
     */
    function startSale() external onlyOwner {
        require(saleStart == 0, "Sale: already started");
        require(flow.balanceOf(address(this)) >= TOTAL_FOR_SALE, "Sale: insufficient EMBER balance");
        saleStart = block.timestamp;
        saleEnd   = block.timestamp + SALE_DURATION;
        emit SaleStarted(saleStart, saleEnd);
    }

    /**
     * @notice Finalize the sale after it ends (or can be called early if hardcap hit).
     * If softcap reached: sends FLR to treasury.
     * If softcap not reached: enables refunds.
     */
    function finalize() external onlyOwner {
        require(saleStart > 0, "Sale: not started");
        require(block.timestamp >= saleEnd || totalRaised >= HARDCAP, "Sale: still active");
        require(!finalized, "Sale: already finalized");
        finalized = true;

        bool softcapHit = totalRaised >= SOFTCAP;
        if (softcapHit) {
            // Send all raised FLR to treasury
            (bool ok,) = treasury.call{value: address(this).balance}("");
            require(ok, "Sale: treasury transfer failed");
        }
        // If softcap not hit, FLR stays in contract for refunds

        emit SaleFinalized(totalRaised, softcapHit);
    }

    function pause()   external onlyOwner { paused = true; }
    function unpause() external onlyOwner { paused = false; }
    function setTreasury(address t) external onlyOwner { treasury = t; }

    // ════════════════════════════════════════════════════════════════════
    //  PUBLIC: BUY
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Buy EMBER with FLR. Send FLR as msg.value.
     *
     * Example: send 1,000 FLR → receive allocation of 30,000 EMBER
     * (EMBER vests linearly over 6 months after sale ends, then claim())
     */
    function buy() external payable notPaused {
        require(saleStart > 0 && block.timestamp >= saleStart, "Sale: not started");
        require(block.timestamp < saleEnd, "Sale: ended");
        require(totalRaised < HARDCAP, "Sale: hardcap reached");
        require(msg.value >= MIN_BUY, "Sale: below minimum buy");

        uint256 remaining      = HARDCAP - totalRaised;
        uint256 acceptedAmount = msg.value > remaining ? remaining : msg.value;

        uint256 newTotal = contributions[msg.sender] + acceptedAmount;
        require(newTotal <= MAX_BUY, "Sale: exceeds per-wallet cap");

        contributions[msg.sender] = newTotal;
        totalRaised              += acceptedAmount;

        // Refund excess if hardcap was hit mid-purchase
        if (msg.value > acceptedAmount) {
            (bool ok,) = msg.sender.call{value: msg.value - acceptedAmount}("");
            require(ok, "Sale: refund failed");
        }

        // If hardcap hit, close sale early
        if (totalRaised >= HARDCAP) {
            saleEnd = block.timestamp;
        }

        uint256 flowAmount = (acceptedAmount * PRICE_PER_FLR) / 1e18;
        emit Purchased(msg.sender, acceptedAmount, flowAmount);
    }

    receive() external payable { this.buy(); }

    // ════════════════════════════════════════════════════════════════════
    //  PUBLIC: CLAIM (after finalize, if softcap hit)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim your vested EMBER. Call multiple times as vesting progresses.
     *
     * Vesting is LINEAR over 6 months from saleEnd:
     * - At saleEnd + 1 month: 1/6 of your EMBER is claimable
     * - At saleEnd + 3 months: 1/2 of your EMBER is claimable
     * - At saleEnd + 6 months: 100% of your EMBER is claimable
     */
    function claim() external afterFinalize {
        require(totalRaised >= SOFTCAP, "Sale: softcap not hit - use refund()");
        require(contributions[msg.sender] > 0, "Sale: no contribution");

        uint256 totalEntitled = (contributions[msg.sender] * PRICE_PER_FLR) / 1e18;
        uint256 elapsed       = block.timestamp - saleEnd;
        uint256 vested        = elapsed >= VEST_DURATION
            ? totalEntitled
            : (totalEntitled * elapsed) / VEST_DURATION;

        uint256 claimableAmt = vested - claimed[msg.sender];
        require(claimableAmt > 0, "Sale: nothing to claim yet");

        claimed[msg.sender] += claimableAmt;
        flow.transfer(msg.sender, claimableAmt);
        emit Claimed(msg.sender, claimableAmt);
    }

    // ════════════════════════════════════════════════════════════════════
    //  PUBLIC: REFUND (only if softcap not hit after finalize)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Get a full FLR refund if the sale failed to hit softcap.
     */
    function refund() external afterFinalize {
        require(totalRaised < SOFTCAP, "Sale: softcap was hit - use claim()");
        uint256 amount = contributions[msg.sender];
        require(amount > 0, "Sale: no contribution");
        contributions[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Sale: refund transfer failed");
        emit Refunded(msg.sender, amount);
    }

    // ════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /** @notice FLR → EMBER conversion for a given amount */
    function flrToFlow(uint256 flrAmount) external pure returns (uint256) {
        return (flrAmount * PRICE_PER_FLR) / 1e18;
    }

    /** @notice How much EMBER is claimable right now for an address */
    function claimable(address buyer) external view returns (uint256) {
        if (!finalized || totalRaised < SOFTCAP || saleEnd == 0) return 0;
        uint256 totalEntitled = (contributions[buyer] * PRICE_PER_FLR) / 1e18;
        uint256 elapsed = block.timestamp > saleEnd ? block.timestamp - saleEnd : 0;
        uint256 vested  = elapsed >= VEST_DURATION
            ? totalEntitled
            : (totalEntitled * elapsed) / VEST_DURATION;
        return vested > claimed[buyer] ? vested - claimed[buyer] : 0;
    }

    /** @notice Full sale status in one call - for frontend */
    function getSaleInfo() external view returns (
        uint256 _start,
        uint256 _end,
        uint256 _raised,
        uint256 _softcap,
        uint256 _hardcap,
        bool    _finalized,
        bool    _softcapHit,
        bool    _active
    ) {
        return (
            saleStart,
            saleEnd,
            totalRaised,
            SOFTCAP,
            HARDCAP,
            finalized,
            totalRaised >= SOFTCAP,
            saleStart > 0 && block.timestamp >= saleStart && block.timestamp < saleEnd && !finalized
        );
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
