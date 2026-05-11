// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * CinderFounderVest — Solo Founder Token Vesting
 *
 * Holds 100,000,000 EMBER (10% of supply) and releases them
 * linearly over 2 years from deployment. No cliff.
 *
 * WHY NO CLIFF:
 * ─────────────
 * A cliff rewards a founder who sticks around for 6 months then
 * leaves. Linear from day 1 means tokens are earned proportionally
 * to time spent building. If the founder abandons the project on
 * day 10, they get 10/730 of their allocation — not a lump sum.
 *
 * TRANSPARENCY:
 * ─────────────
 * This contract is deployed at a public address. Anyone can verify:
 * - Total founder allocation: 100,000,000 EMBER
 * - Vesting start: timestamp of deployment
 * - Amount claimed so far: claimed variable
 * - Amount still locked: 100M - vested()
 * - Founder cannot access more than their linear share at any moment
 *
 * REVOCATION:
 * ────────────
 * There is no revocation — it's just one person (the founder).
 * If the project is abandoned, unvested tokens stay locked until
 * they vest. The community can take over governance with the
 * distributed mining EMBER and vote on what to do with treasury.
 */

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract CinderFounderVest {

    IERC20  public immutable flow;
    address public founder;          // the one person who can claim
    uint256 public immutable start;  // vesting start (deployment time)
    uint256 public constant  DURATION = 730 days; // 2 years
    uint256 public constant  TOTAL    = 100_000_000e18; // 100M EMBER
    uint256 public claimed;

    event Claimed(uint256 amount, uint256 totalClaimed);
    event FounderTransferred(address oldFounder, address newFounder);

    constructor(address _flow, address _founder) {
        flow    = IERC20(_flow);
        founder = _founder;
        start   = block.timestamp;
    }

    modifier onlyFounder() { require(msg.sender == founder, "Vest: not founder"); _; }

    /**
     * @notice How much EMBER has vested so far (linear, no cliff).
     * At day 1: 100M / 730 ≈ 136,986 EMBER
     * At day 365: 50M EMBER
     * At day 730: 100M EMBER (fully vested)
     */
    function vested() public view returns (uint256) {
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= DURATION) return TOTAL;
        return (TOTAL * elapsed) / DURATION;
    }

    /**
     * @notice How much is claimable right now (vested minus already claimed).
     */
    function claimable() public view returns (uint256) {
        uint256 v = vested();
        return v > claimed ? v - claimed : 0;
    }

    /**
     * @notice Claim vested EMBER. Only callable by the founder.
     * Can call as often as desired — each call claims everything available.
     */
    function claim() external onlyFounder {
        uint256 amount = claimable();
        require(amount > 0, "Vest: nothing to claim");
        claimed += amount;
        flow.transfer(founder, amount);
        emit Claimed(amount, claimed);
    }

    /**
     * @notice Transfer founder role (e.g. to a new wallet or multisig).
     * Unvested tokens stay here — vesting continues to the new address.
     */
    function transferFounder(address newFounder) external onlyFounder {
        require(newFounder != address(0), "Vest: zero address");
        emit FounderTransferred(founder, newFounder);
        founder = newFounder;
    }

    /**
     * @notice Dashboard data in one call.
     */
    function getVestInfo() external view returns (
        uint256 totalAlloc,
        uint256 vestedAmount,
        uint256 claimedAmount,
        uint256 claimableNow,
        uint256 startTime,
        uint256 endTime,
        uint256 daysRemaining
    ) {
        uint256 elapsed = block.timestamp - start;
        uint256 remaining = elapsed >= DURATION ? 0 : DURATION - elapsed;
        return (
            TOTAL,
            vested(),
            claimed,
            claimable(),
            start,
            start + DURATION,
            remaining / 1 days
        );
    }
}
