// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreditOracle} from "./CreditOracle.sol";

/**
 * @title LendingPool
 * @notice Credit-score-adjusted native-BNB lending pool. Reads the composite
 *         credit score from CreditOracle and uses a piecewise-linear curve to
 *         determine the collateral required for each borrower.
 *
 * ────────────────────────────────────────────────────────────────────────────
 * COLLATERAL CURVE (piecewise linear, in basis points)
 * ────────────────────────────────────────────────────────────────────────────
 * Default breakpoints (score → collateral ratio):
 *
 *     score    0 → 20:     15000 bps  (150%  — standard DeFi)
 *     score   20 → 50:     15000 → 12000 bps  (150% → 120%)
 *     score   50 → 70:     12000 → 10000 bps  (120% → 100%)
 *     score   70 → 85:     10000 → 8500  bps  (100% → 85%)
 *     score   85 → 100:     8500 → 7500  bps  (85%  → 75%)
 *
 * These are PRE-CALIBRATION DEFAULTS. They were validated against the actual
 * composite score distribution from the trained model (see
 * `model/calibrate_curve.py`), but are stored as admin-adjustable state so
 * post-deployment tuning is cheap.
 *
 * ────────────────────────────────────────────────────────────────────────────
 * SCOPE FOR THE HACKATHON
 * ────────────────────────────────────────────────────────────────────────────
 * This is a demo of credit-score-adjusted collateral requirements. It is NOT
 * a production lending protocol. Explicitly out of scope:
 *   - Interest rate model
 *   - Liquidations (if collateral value drops, borrower is not liquidated here)
 *   - Bad-debt handling
 *   - Multi-asset support (only native BNB)
 *   - Loan term structure (loans are open-ended until repaid in full)
 * See the hackathon report for the full list of production gaps.
 */
contract LendingPool is Ownable, ReentrancyGuard {
    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    CreditOracle public immutable oracle;

    /// @dev Pool-wide accounting
    uint256 public totalLiquidity;          // total BNB deposited by LPs
    uint256 public totalBorrowed;           // total BNB currently borrowed

    /// @dev Per-LP deposit accounting (simplified: no shares, no interest accrual)
    mapping(address => uint256) public deposits;

    /// @dev Per-borrower state
    mapping(address => uint256) public borrowedAmounts;
    mapping(address => uint256) public collateralDeposited;

    // Collateral curve breakpoints (5 scores, 6 ratios — n+1 points).
    // scoreBreakpoints[i]   is the score at which ratio ratios[i+1] applies.
    // Below scoreBreakpoints[0], ratios[0] applies.
    // Above scoreBreakpoints[last], ratios[last] applies.
    // Ratios must be monotonically non-increasing.
    uint16[5] public scoreBreakpoints;
    uint16[6] public collateralRatiosBps;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event Deposited(address indexed lp, uint256 amount, uint256 newTotalLiquidity);
    event Withdrawn(address indexed lp, uint256 amount, uint256 newTotalLiquidity);
    event Borrowed(
        address indexed borrower,
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint16 collateralRatioBps,
        uint8 compositeScore
    );
    event Repaid(address indexed borrower, uint256 amount, uint256 collateralReturned);
    event CollateralCurveUpdated(uint16[5] scoreBreakpoints, uint16[6] collateralRatiosBps);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address initialOwner, CreditOracle _oracle) Ownable(initialOwner) {
        require(address(_oracle) != address(0), "Zero oracle");
        oracle = _oracle;

        scoreBreakpoints = [uint16(20), 50, 70, 85, 100];
        collateralRatiosBps = [uint16(15000), 15000, 12000, 10000, 8500, 7500];
    }

    // ─────────────────────────────────────────────────────────────────────
    // LP actions
    // ─────────────────────────────────────────────────────────────────────

    function deposit() external payable nonReentrant {
        require(msg.value > 0, "Zero deposit");
        deposits[msg.sender] += msg.value;
        totalLiquidity += msg.value;
        emit Deposited(msg.sender, msg.value, totalLiquidity);
    }

    /**
     * @notice LPs can withdraw any amount up to their deposit balance, capped
     *         by the amount of liquidity that isn't currently borrowed.
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero withdraw");
        require(deposits[msg.sender] >= amount, "Insufficient deposit");
        uint256 available = totalLiquidity - totalBorrowed;
        require(available >= amount, "Insufficient pool liquidity");

        deposits[msg.sender] -= amount;
        totalLiquidity -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");

        emit Withdrawn(msg.sender, amount, totalLiquidity);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Borrower actions
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Borrow `amount` BNB, posting `msg.value` as collateral.
     *         The composite credit score from the CreditOracle determines the
     *         required collateral ratio.
     *
     *         Restriction: at most one open loan per borrower at a time.
     */
    function borrow(uint256 amount) external payable nonReentrant {
        require(amount > 0, "Zero borrow");
        require(borrowedAmounts[msg.sender] == 0, "Outstanding loan exists");
        require(totalLiquidity - totalBorrowed >= amount, "Insufficient pool liquidity");

        uint8 score = oracle.getCompositeScore(msg.sender);
        uint16 ratioBps = getCollateralRatioBps(score);

        // required = amount * ratioBps / 10000
        uint256 required = (amount * ratioBps) / 10000;
        require(msg.value >= required, "Insufficient collateral");

        borrowedAmounts[msg.sender] = amount;
        collateralDeposited[msg.sender] = msg.value;
        totalBorrowed += amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");

        emit Borrowed(msg.sender, amount, msg.value, ratioBps, score);
    }

    /**
     * @notice Repay the outstanding loan in full and reclaim collateral.
     *         Partial repayments are not supported in this demo.
     */
    function repay() external payable nonReentrant {
        uint256 debt = borrowedAmounts[msg.sender];
        require(debt > 0, "No outstanding loan");
        require(msg.value >= debt, "Insufficient repayment");

        uint256 collateral = collateralDeposited[msg.sender];
        borrowedAmounts[msg.sender] = 0;
        collateralDeposited[msg.sender] = 0;
        totalBorrowed -= debt;

        // Return collateral + any overpayment
        uint256 refund = collateral + (msg.value - debt);
        (bool ok, ) = msg.sender.call{value: refund}("");
        require(ok, "Transfer failed");

        emit Repaid(msg.sender, debt, collateral);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the collateral ratio (basis points) that applies for a
     *         given composite score under the current curve.
     *         10000 bps = 100%. 15000 = 150%. 7500 = 75%.
     * @dev Control points:
     *         (0, ratios[0]), (bp[0], ratios[1]), (bp[1], ratios[2]),
     *         (bp[2], ratios[3]), (bp[3], ratios[4]), (bp[4], ratios[5])
     *      Interpolation is piecewise-linear between successive control
     *      points; outside the curve's domain, the edge ratios apply.
     */
    function getCollateralRatioBps(uint8 score) public view returns (uint16) {
        uint256 s = score;
        // Above the last breakpoint → floor ratio
        if (s >= scoreBreakpoints[4]) {
            return collateralRatiosBps[5];
        }
        // Segment 0: [0, breakpoints[0]] — from ratios[0] to ratios[1]
        if (s <= scoreBreakpoints[0]) {
            return _interp(s, 0, scoreBreakpoints[0], collateralRatiosBps[0], collateralRatiosBps[1]);
        }
        // Segments 1-4: [breakpoints[i], breakpoints[i+1]] — from ratios[i+1] to ratios[i+2]
        for (uint256 i = 0; i < 4; i++) {
            uint256 lo = scoreBreakpoints[i];
            uint256 hi = scoreBreakpoints[i + 1];
            if (s >= lo && s <= hi) {
                return _interp(s, lo, hi, collateralRatiosBps[i + 1], collateralRatiosBps[i + 2]);
            }
        }
        // Unreachable
        return collateralRatiosBps[5];
    }

    /// @dev Linear interpolation. Requires y0 >= y1 (ratios are non-increasing).
    function _interp(uint256 s, uint256 x0, uint256 x1, uint256 y0, uint256 y1)
        internal pure returns (uint16)
    {
        if (x1 == x0) return uint16(y0);
        uint256 delta = y0 - y1;
        uint256 offset = s - x0;
        uint256 ratio = y0 - (offset * delta) / (x1 - x0);
        return uint16(ratio);
    }

    /**
     * @notice Convenience helper: compute required collateral in wei for a
     *         given borrower and borrow amount using the live oracle score.
     */
    function getRequiredCollateral(address borrower, uint256 borrowAmount)
        external
        view
        returns (uint256)
    {
        uint8 score = oracle.getCompositeScore(borrower);
        uint16 ratioBps = getCollateralRatioBps(score);
        return (borrowAmount * ratioBps) / 10000;
    }

    /**
     * @notice Returns the collateral ratio for a borrower using the live
     *         oracle score.
     */
    function getBorrowerCollateralRatioBps(address borrower)
        external
        view
        returns (uint16)
    {
        uint8 score = oracle.getCompositeScore(borrower);
        return getCollateralRatioBps(score);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Admin: update the collateral curve
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Update the piecewise-linear collateral curve. The following
     *         invariants are enforced:
     *           - scoreBreakpoints strictly increasing
     *           - scoreBreakpoints values in (0, 100]
     *           - collateralRatiosBps monotonically non-increasing
     *           - first ratio <= 20000 bps (200%), last >= 5000 bps (50%)
     */
    function setCollateralCurve(
        uint16[5] calldata newBreakpoints,
        uint16[6] calldata newRatiosBps
    ) external onlyOwner {
        // Breakpoints strictly increasing within (0, 100]
        require(newBreakpoints[0] > 0 && newBreakpoints[4] <= 100, "Breakpoints out of range");
        for (uint256 i = 1; i < 5; i++) {
            require(newBreakpoints[i] > newBreakpoints[i - 1], "Breakpoints not increasing");
        }
        // Ratios monotonically non-increasing
        for (uint256 i = 1; i < 6; i++) {
            require(newRatiosBps[i] <= newRatiosBps[i - 1], "Ratios not non-increasing");
        }
        // Sanity bounds
        require(newRatiosBps[0] <= 20000, "First ratio > 200%");
        require(newRatiosBps[5] >= 5000, "Last ratio < 50%");

        scoreBreakpoints = newBreakpoints;
        collateralRatiosBps = newRatiosBps;
        emit CollateralCurveUpdated(newBreakpoints, newRatiosBps);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Fallbacks
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Accept plain BNB transfers (treat as LP deposit from msg.sender)
    receive() external payable {
        deposits[msg.sender] += msg.value;
        totalLiquidity += msg.value;
        emit Deposited(msg.sender, msg.value, totalLiquidity);
    }
}
