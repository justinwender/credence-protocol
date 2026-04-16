// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {CreditOracle} from "../src/CreditOracle.sol";
import {OffchainAttestationRegistry} from "../src/OffchainAttestationRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CredenceTestBase} from "./TestHelpers.sol";

contract LendingPoolTest is CredenceTestBase {
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

    function setUp() public {
        _deployAll();
        vm.deal(lp, 100 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Collateral curve math (pure view)
    // ─────────────────────────────────────────────────────────────────────

    function test_Curve_AtBreakpoints() public view {
        // Default: breakpoints [20,50,70,85,100], ratios [15000,15000,12000,10000,8500,7500]
        assertEq(pool.getCollateralRatioBps(0),   15000); // floor
        assertEq(pool.getCollateralRatioBps(20),  15000); // first breakpoint, still plateau
        assertEq(pool.getCollateralRatioBps(50),  12000);
        assertEq(pool.getCollateralRatioBps(70),  10000);
        assertEq(pool.getCollateralRatioBps(85),   8500);
        assertEq(pool.getCollateralRatioBps(100),  7500); // ceiling
    }

    function test_Curve_Interpolates() public view {
        // midpoint 20→50 (ratio 15000→12000): score 35 → ratio 13500
        assertEq(pool.getCollateralRatioBps(35), 13500);
        // midpoint 70→85 (ratio 10000→8500): score ~77.5 → (10000 - 7.5*1500/15) = 9250
        assertEq(pool.getCollateralRatioBps(77), 9300);
        // midpoint 85→100 (ratio 8500→7500): score 92 → 8500 - 7*1000/15 = ~8033
        uint16 r92 = pool.getCollateralRatioBps(92);
        assertApproxEqAbs(uint256(r92), 8033, 1);
    }

    function test_Curve_Monotonic() public view {
        // Ratio must be non-increasing in score
        uint16 prev = pool.getCollateralRatioBps(0);
        for (uint8 s = 1; s <= 100; s++) {
            uint16 cur = pool.getCollateralRatioBps(s);
            assertLe(cur, prev);
            prev = cur;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Deposits / withdrawals
    // ─────────────────────────────────────────────────────────────────────

    function test_Deposit_IncreasesLiquidityAndTracksLP() public {
        vm.expectEmit(true, false, false, true);
        emit Deposited(lp, 10 ether, 10 ether);

        vm.prank(lp);
        pool.deposit{value: 10 ether}();

        assertEq(pool.totalLiquidity(), 10 ether);
        assertEq(pool.deposits(lp), 10 ether);
    }

    function test_Deposit_RevertsOnZero() public {
        vm.prank(lp);
        vm.expectRevert(bytes("Zero deposit"));
        pool.deposit{value: 0}();
    }

    function test_Withdraw_HappyPath() public {
        vm.prank(lp);
        pool.deposit{value: 10 ether}();

        uint256 lpBalBefore = lp.balance;
        vm.prank(lp);
        pool.withdraw(4 ether);

        assertEq(pool.deposits(lp), 6 ether);
        assertEq(pool.totalLiquidity(), 6 ether);
        assertEq(lp.balance, lpBalBefore + 4 ether);
    }

    function test_Withdraw_RevertsOnOverdraft() public {
        vm.prank(lp);
        pool.deposit{value: 5 ether}();

        vm.prank(lp);
        vm.expectRevert(bytes("Insufficient deposit"));
        pool.withdraw(6 ether);
    }

    function test_Withdraw_RevertsIfPoolLiquidityTaken() public {
        // LP deposits 5, Alice borrows 4. Now withdrawable is only 1.
        vm.prank(lp);
        pool.deposit{value: 5 ether}();

        _seedCompositeScore(alice, 100); // best terms so collateral is small
        uint256 required = pool.getRequiredCollateral(alice, 4 ether);
        vm.prank(alice);
        pool.borrow{value: required}(4 ether);

        vm.prank(lp);
        vm.expectRevert(bytes("Insufficient pool liquidity"));
        pool.withdraw(2 ether); // > 1 ether available
    }

    // Receive() should behave identically to deposit()
    function test_Receive_IsDeposit() public {
        vm.prank(lp);
        (bool ok, ) = address(pool).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(pool.deposits(lp), 3 ether);
        assertEq(pool.totalLiquidity(), 3 ether);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Borrow
    // ─────────────────────────────────────────────────────────────────────

    function test_Borrow_AtScore0_Requires150PctCollateral() public {
        _seedLiquidity(10 ether);
        // score 0 → ratio 15000 bps
        uint256 required = pool.getRequiredCollateral(alice, 1 ether);
        assertEq(required, 1.5 ether);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        pool.borrow{value: required}(1 ether);

        assertEq(pool.borrowedAmounts(alice), 1 ether);
        assertEq(pool.collateralDeposited(alice), 1.5 ether);
        assertEq(pool.totalBorrowed(), 1 ether);
        // Alice paid 1.5 ether in, received 1 ether back → net out 0.5 ether
        assertEq(alice.balance, aliceBalBefore - 0.5 ether);
    }

    function test_Borrow_AtScore100_Requires75PctCollateral() public {
        _seedLiquidity(10 ether);
        _seedCompositeScore(alice, 100);

        uint256 required = pool.getRequiredCollateral(alice, 1 ether);
        assertEq(required, 0.75 ether);

        vm.expectEmit(true, false, false, true);
        emit Borrowed(alice, 1 ether, 0.75 ether, 7500, 100);

        vm.prank(alice);
        pool.borrow{value: 0.75 ether}(1 ether);
    }

    function test_Borrow_RevertsOnInsufficientCollateral() public {
        _seedLiquidity(10 ether);
        _seedCompositeScore(alice, 50); // ratio 12000 → need 1.2 ether for 1 ether

        vm.prank(alice);
        vm.expectRevert(bytes("Insufficient collateral"));
        pool.borrow{value: 1.19 ether}(1 ether);
    }

    function test_Borrow_RevertsOnOutstandingLoan() public {
        _seedLiquidity(10 ether);
        _seedCompositeScore(alice, 50);

        uint256 required = pool.getRequiredCollateral(alice, 1 ether);
        vm.prank(alice);
        pool.borrow{value: required}(1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("Outstanding loan exists"));
        pool.borrow{value: required}(1 ether);
    }

    function test_Borrow_RevertsOnInsufficientPoolLiquidity() public {
        _seedLiquidity(0.5 ether);
        _seedCompositeScore(alice, 50);

        uint256 required = pool.getRequiredCollateral(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Insufficient pool liquidity"));
        pool.borrow{value: required}(1 ether);
    }

    function test_Borrow_RevertsOnZeroAmount() public {
        _seedLiquidity(5 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Zero borrow"));
        pool.borrow{value: 1 ether}(0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Repay
    // ─────────────────────────────────────────────────────────────────────

    function test_Repay_ReturnsCollateralAndClearsLoan() public {
        _seedLiquidity(10 ether);
        _seedCompositeScore(alice, 100);
        uint256 required = pool.getRequiredCollateral(alice, 1 ether);
        vm.prank(alice);
        pool.borrow{value: required}(1 ether);

        uint256 aliceBalBefore = alice.balance;

        vm.expectEmit(true, false, false, true);
        emit Repaid(alice, 1 ether, required);

        vm.prank(alice);
        pool.repay{value: 1 ether}();

        // Alice paid 1 ether, got required (collateral) back → net gain = required - 1 ether
        assertEq(alice.balance, aliceBalBefore - 1 ether + required);
        assertEq(pool.borrowedAmounts(alice), 0);
        assertEq(pool.collateralDeposited(alice), 0);
        assertEq(pool.totalBorrowed(), 0);
    }

    function test_Repay_RefundsOverpayment() public {
        _seedLiquidity(10 ether);
        _seedCompositeScore(alice, 100);
        uint256 required = pool.getRequiredCollateral(alice, 1 ether);
        vm.prank(alice);
        pool.borrow{value: required}(1 ether);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        pool.repay{value: 1.5 ether}(); // 0.5 ether overpay

        // Alice sent 1.5 ether, got collateral + 0.5 overpay back → net = 1 ether (debt only)
        assertEq(alice.balance, aliceBalBefore - 1 ether + required);
    }

    function test_Repay_RevertsOnNoLoan() public {
        vm.prank(alice);
        vm.expectRevert(bytes("No outstanding loan"));
        pool.repay{value: 1 ether}();
    }

    function test_Repay_RevertsOnUnderpayment() public {
        _seedLiquidity(10 ether);
        _seedCompositeScore(alice, 100);
        uint256 required = pool.getRequiredCollateral(alice, 1 ether);
        vm.prank(alice);
        pool.borrow{value: required}(1 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("Insufficient repayment"));
        pool.repay{value: 0.5 ether}();
    }

    // ─────────────────────────────────────────────────────────────────────
    // setCollateralCurve: admin + invariants
    // ─────────────────────────────────────────────────────────────────────

    function test_SetCurve_OnlyOwner() public {
        uint16[5] memory bp = [uint16(25), 55, 75, 90, 100];
        uint16[6] memory rt = [uint16(14000), 14000, 11500, 9500, 8000, 7000];
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        pool.setCollateralCurve(bp, rt);
    }

    function test_SetCurve_RevertsOnNonIncreasingBreakpoints() public {
        uint16[5] memory bp = [uint16(50), 40, 70, 85, 100];
        uint16[6] memory rt = [uint16(15000), 15000, 12000, 10000, 8500, 7500];
        vm.prank(admin);
        vm.expectRevert(bytes("Breakpoints not increasing"));
        pool.setCollateralCurve(bp, rt);
    }

    function test_SetCurve_RevertsOnNonDecreasingRatios() public {
        uint16[5] memory bp = [uint16(20), 50, 70, 85, 100];
        uint16[6] memory rt = [uint16(15000), 15000, 12000, 13000, 8500, 7500]; // ratio went UP at idx 3
        vm.prank(admin);
        vm.expectRevert(bytes("Ratios not non-increasing"));
        pool.setCollateralCurve(bp, rt);
    }

    function test_SetCurve_RevertsOnFirstRatioTooHigh() public {
        uint16[5] memory bp = [uint16(20), 50, 70, 85, 100];
        uint16[6] memory rt = [uint16(25000), 20000, 12000, 10000, 8500, 7500];
        vm.prank(admin);
        vm.expectRevert(bytes("First ratio > 200%"));
        pool.setCollateralCurve(bp, rt);
    }

    function test_SetCurve_RevertsOnLastRatioTooLow() public {
        uint16[5] memory bp = [uint16(20), 50, 70, 85, 100];
        uint16[6] memory rt = [uint16(15000), 15000, 12000, 10000, 7000, 4000];
        vm.prank(admin);
        vm.expectRevert(bytes("Last ratio < 50%"));
        pool.setCollateralCurve(bp, rt);
    }

    function test_SetCurve_RevertsOnBreakpointZero() public {
        uint16[5] memory bp = [uint16(0), 50, 70, 85, 100];
        uint16[6] memory rt = [uint16(15000), 15000, 12000, 10000, 8500, 7500];
        vm.prank(admin);
        vm.expectRevert(bytes("Breakpoints out of range"));
        pool.setCollateralCurve(bp, rt);
    }

    function test_SetCurve_HappyPath() public {
        uint16[5] memory bp = [uint16(25), 55, 75, 90, 100];
        uint16[6] memory rt = [uint16(14000), 14000, 11500, 9500, 8000, 7000];
        vm.prank(admin);
        pool.setCollateralCurve(bp, rt);

        assertEq(pool.getCollateralRatioBps(25), 14000);
        assertEq(pool.getCollateralRatioBps(100), 7000);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────

    function _seedLiquidity(uint256 amount) internal {
        vm.prank(lp);
        pool.deposit{value: amount}();
    }

    function _seedCompositeScore(address wallet, uint8 composite) internal {
        // Manipulate multipliers so that onchain-only maps to the desired
        // composite score for clean curve testing. We set onchainOnlyMultiplier
        // = 100 and push score == composite.
        vm.prank(admin);
        oracle.setMultipliers(100, 70, 40);
        vm.prank(admin);
        oracle.setOnchainScore(wallet, composite, 5);
    }
}
