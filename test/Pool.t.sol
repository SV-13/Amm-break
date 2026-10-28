// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Pool} from "../src/Pool.sol";

contract PoolTest is Test {
    Token token0;
    Token token1;
    Pool pool;

    address lp = makeAddr("lp");
    address alice = makeAddr("alice");

    function setUp() public {
        token0 = new Token("Token 0", "T0");
        token1 = new Token("Token 1", "T1");
        pool = new Pool(token0, token1);

        token0.mint(lp, 10_000);
        token1.mint(lp, 10_000);

        token0.mint(alice, 10_000);
        token1.mint(alice, 10_000);

        // The liquidity provider authorizes the pool to take tokens.
        vm.startPrank(lp);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // Alice authorizes the pool to take her swap input.
        vm.startPrank(alice);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // Formula tests

    function test_SmallTrade() public view {
        assertEq(pool.getAmountOut(10, 100, 100), 9);
    }

    function test_BigTrade() public view {
        assertEq(pool.getAmountOut(50, 100, 100), 33);
    }

    function test_RevertsOnZeroInput() public {
        vm.expectRevert(Pool.ZeroInput.selector);
        pool.getAmountOut(0, 100, 100);
    }

    function test_RevertsOnEmptyReserves() public {
        vm.expectRevert(Pool.NoLiquidity.selector);
        pool.getAmountOut(10, 0, 100);

        vm.expectRevert(Pool.NoLiquidity.selector);
        pool.getAmountOut(10, 100, 0);
    }

    function testFuzz_KNeverDecreases(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) public view {
        reserveIn = bound(reserveIn, 1, 1e30);
        reserveOut = bound(reserveOut, 1, 1e30);
        amountIn = bound(amountIn, 1, 1e30);

        uint256 out = pool.getAmountOut(amountIn, reserveIn, reserveOut);

        uint256 kBefore = reserveIn * reserveOut;
        uint256 kAfter = (reserveIn + amountIn) * (reserveOut - out);

        assertGe(kAfter, kBefore);
    }

    function _seedPool(uint256 amount0, uint256 amount1) internal {
        vm.prank(lp);
        pool.addLiquidity(amount0, amount1, 0);
    }

    function test_AddLiquiditySetsReservesAndHoldsTokens() public {
        _seedPool(1_000, 1_000);

        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);

        assertEq(token0.balanceOf(address(pool)), 1_000);
        assertEq(token1.balanceOf(address(pool)), 1_000);

        assertEq(token0.balanceOf(lp), 9_000);
        assertEq(token1.balanceOf(lp), 9_000);
    }

    function test_SwapMatchesHandTrace() public {
        _seedPool(1_000, 1_000);

        vm.prank(alice);
        uint256 amountOut = pool.swap(token0, 100, 90);

        assertEq(amountOut, 90);

        assertEq(pool.reserve0(), 1_100);
        assertEq(pool.reserve1(), 910);

        assertEq(token0.balanceOf(alice), 9_900);
        assertEq(token1.balanceOf(alice), 10_090);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    function test_SwapRevertsBelowMinAmountOut() public {
        _seedPool(1_000, 1_000);

        vm.expectRevert(abi.encodeWithSelector(Pool.SlippageExceeded.selector, 90, 91));

        vm.prank(alice);
        pool.swap(token0, 100, 91);

        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);
        assertEq(token0.balanceOf(address(pool)), 1_000);
        assertEq(token1.balanceOf(address(pool)), 1_000);
    }

    function test_SwapRevertsForForeignToken() public {
        Token foreignToken = new Token("Foreign Token", "FOREIGN");

        vm.expectRevert(Pool.InvalidToken.selector);

        vm.prank(alice);
        pool.swap(foreignToken, 10, 0);
    }

    function test_SwapRejectsZeroOutput() public {
        _seedPool(1_000, 1_000);

        vm.expectRevert(Pool.ZeroOutput.selector);

        vm.prank(alice);
        pool.swap(token0, 1, 0);

        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);
        assertEq(token0.balanceOf(alice), 10_000);
    }

    function test_SwapAppliesFee() public {
        _seedPool(1_000, 1_000);

        vm.prank(alice);
        uint256 amountOut = pool.swap(token0, 500, 332);

        assertEq(amountOut, 332);
        assertEq(pool.reserve0(), 1_500);
        assertEq(pool.reserve1(), 668);
        assertEq(pool.reserve0() * pool.reserve1(), 1_002_000);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    function test_SwapToken1ForToken0() public {
        _seedPool(1_000, 2_000);

        vm.prank(alice);
        uint256 amountOut = pool.swap(token1, 100, 47);

        assertEq(amountOut, 47);
        assertEq(pool.reserve0(), 953);
        assertEq(pool.reserve1(), 2_100);
        assertEq(pool.reserve0() * pool.reserve1(), 2_001_300);

        assertEq(token0.balanceOf(alice), 10_047);
        assertEq(token1.balanceOf(alice), 9_900);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    function testFuzz_SwapKeepsInvariants(uint256 amountIn, bool zeroForOne) public {
        _seedPool(1_000, 1_000);

        amountIn = bound(amountIn, 10, 5_000);

        uint256 kBefore = pool.reserve0() * pool.reserve1();

        vm.prank(alice);
        if (zeroForOne) {
            pool.swap(token0, amountIn, 0);
        } else {
            pool.swap(token1, amountIn, 0);
        }

        uint256 kAfter = pool.reserve0() * pool.reserve1();

        assertGe(kAfter, kBefore);
        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    // Liquidity provider shares

    function test_FirstDepositMintsSharesAndLocksMinimum() public {
        vm.prank(lp);
        uint256 minted = pool.addLiquidity(1_000, 1_000, 0);

        assertEq(minted, 900);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 1_000);

        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);
        assertEq(token0.balanceOf(address(pool)), 1_000);
        assertEq(token1.balanceOf(address(pool)), 1_000);
    }

    function test_FirstDepositAsymmetric() public {
        vm.prank(lp);
        uint256 minted = pool.addLiquidity(1_000, 2_000, 0);

        assertEq(minted, 1_314);
        assertEq(pool.shares(lp), 1_314);
        assertEq(pool.totalShares(), 1_414);

        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 2_000);
    }

    function test_SecondDepositProportional() public {
        _seedPool(1_000, 2_000);

        vm.prank(alice);
        uint256 minted = pool.addLiquidity(500, 1_000, 0);

        assertEq(minted, 707);
        assertEq(pool.shares(lp), 1_314);
        assertEq(pool.shares(alice), 707);
        assertEq(pool.totalShares(), 2_121);

        assertEq(pool.reserve0(), 1_500);
        assertEq(pool.reserve1(), 3_000);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    function test_UnbalancedDepositGetsFewerShares() public {
        _seedPool(1_000, 1_000);

        vm.prank(alice);
        uint256 minted = pool.addLiquidity(500, 100, 0);

        assertEq(minted, 100);
        assertEq(pool.shares(alice), 100);
        assertEq(pool.totalShares(), 1_100);

        assertEq(pool.reserve0(), 1_500);
        assertEq(pool.reserve1(), 1_100);
    }

    function test_TinyFirstDepositReverts() public {
        vm.expectRevert(Pool.ZeroShares.selector);

        vm.prank(lp);
        pool.addLiquidity(10, 10, 0);

        assertEq(pool.totalShares(), 0);
        assertEq(pool.reserve0(), 0);
        assertEq(pool.reserve1(), 0);
    }

    function test_DepositThatRoundsToZeroSharesReverts() public {
        _seedPool(1_000, 1_000);

        vm.prank(alice);
        pool.swap(token0, 500, 0);

        assertEq(pool.reserve0(), 1_500);
        assertEq(pool.reserve1(), 668);
        assertEq(pool.totalShares(), 1_000);

        vm.expectRevert(Pool.ZeroShares.selector);
        vm.prank(alice);
        pool.addLiquidity(1, 1, 0);

        assertEq(pool.reserve0(), 1_500);
        assertEq(pool.reserve1(), 668);
        assertEq(pool.totalShares(), 1_000);
        assertEq(pool.shares(alice), 0);

        assertEq(token0.balanceOf(address(pool)), 1_500);
        assertEq(token1.balanceOf(address(pool)), 668);
        assertEq(token0.balanceOf(alice), 9_500);
        assertEq(token1.balanceOf(alice), 10_332);
    }

    // Liquidity withdrawals

    function test_RemovePartialShares() public {
        _seedPool(1_000, 1_000);

        vm.prank(lp);
        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(450);

        assertEq(amount0, 450);
        assertEq(amount1, 450);

        assertEq(pool.shares(lp), 450);
        assertEq(pool.totalShares(), 550);
        assertEq(pool.reserve0(), 550);
        assertEq(pool.reserve1(), 550);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    function test_RemoveAfterSwapEarnsFees() public {
        _seedPool(1_000, 1_000);

        vm.prank(alice);
        pool.swap(token0, 500, 0);

        vm.prank(lp);
        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(900);

        assertEq(amount0, 1_350);
        assertEq(amount1, 601);

        assertEq(pool.shares(lp), 0);
        assertEq(pool.totalShares(), 100);
        assertEq(pool.reserve0(), 150);
        assertEq(pool.reserve1(), 67);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
        assertEq(token0.balanceOf(lp), 10_350);
        assertEq(token1.balanceOf(lp), 9_601);
    }

    function test_CannotRemoveMoreSharesThanOwned() public {
        _seedPool(1_000, 1_000);

        vm.expectRevert(abi.encodeWithSelector(Pool.InsufficientShares.selector, 900, 901));

        vm.prank(lp);
        pool.removeLiquidity(901);

        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 1_000);
        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);
    }

    function test_LockedSharesStayForever() public {
        _seedPool(1_000, 1_000);

        vm.prank(lp);
        pool.removeLiquidity(900);

        assertEq(pool.shares(lp), 0);
        assertEq(pool.totalShares(), 100);
        assertEq(pool.reserve0(), 100);
        assertEq(pool.reserve1(), 100);

        assertEq(token0.balanceOf(address(pool)), 100);
        assertEq(token1.balanceOf(address(pool)), 100);
    }

    function test_RemoveThatRoundsToZeroReverts() public {
        _seedPool(1_000, 1_000);

        vm.prank(alice);
        pool.swap(token0, 5_000, 0);

        assertEq(pool.reserve0(), 6_000);
        assertEq(pool.reserve1(), 168);

        vm.expectRevert(Pool.ZeroOutput.selector);

        vm.prank(lp);
        pool.removeLiquidity(1);

        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 1_000);
        assertEq(pool.reserve0(), 6_000);
        assertEq(pool.reserve1(), 168);

        assertEq(token0.balanceOf(address(pool)), 6_000);
        assertEq(token1.balanceOf(address(pool)), 168);
    }

    function test_RemoveZeroSharesOnEmptyPoolReverts() public {
        vm.expectRevert(Pool.ZeroOutput.selector);
        vm.prank(lp);
        pool.removeLiquidity(0);
    }

    // Fuzz tests

    function testFuzz_DepositThenWithdrawNeverProfits(uint256 a0, uint256 a1) public {
        _seedPool(1_000, 2_000);

        a0 = bound(a0, 10, 5_000);
        a1 = bound(a1, 10, 5_000);

        vm.prank(alice);
        pool.swap(token0, 123, 0);

        vm.startPrank(alice);
        uint256 minted = pool.addLiquidity(a0, a1, 0);
        (uint256 out0, uint256 out1) = pool.removeLiquidity(minted);
        vm.stopPrank();

        assertLe(out0, a0);
        assertLe(out1, a1);
    }

    function testFuzz_RemoveNeverDilutesRemainingProviders(uint256 a0, uint256 a1, uint256 burn) public {
        _seedPool(1_000, 2_000);

        a0 = bound(a0, 10, 5_000);
        a1 = bound(a1, 10, 5_000);
        burn = bound(burn, 10, 900);

        vm.prank(alice);
        pool.swap(token0, 123, 0);

        vm.prank(alice);
        pool.addLiquidity(a0, a1, 0);

        uint256 oldReserve0 = pool.reserve0();
        uint256 oldReserve1 = pool.reserve1();
        uint256 oldTotal = pool.totalShares();

        vm.prank(lp);
        pool.removeLiquidity(burn);

        uint256 newTotal = pool.totalShares();

        assertGe(pool.reserve0() * oldTotal, oldReserve0 * newTotal);

        assertGe(pool.reserve1() * oldTotal, oldReserve1 * newTotal);

        assertEq(pool.shares(lp) + pool.shares(alice) + 100, pool.totalShares());
    }

    function testFuzz_SwapSequenceKeepsInvariants(uint256[8] memory amounts, uint8 directions) public {
        _seedPool(1_000, 1_000);

        uint256 kPrev = pool.reserve0() * pool.reserve1();

        for (uint256 i = 0; i < 8; i++) {
            uint256 amountIn = bound(amounts[i], 100, 500);
            bool zeroForOne = ((directions >> i) & 1) == 1;

            vm.prank(alice);
            if (zeroForOne) {
                pool.swap(token0, amountIn, 0);
            } else {
                pool.swap(token1, amountIn, 0);
            }

            uint256 kNow = pool.reserve0() * pool.reserve1();
            assertGe(kNow, kPrev);
            kPrev = kNow;

            assertEq(token0.balanceOf(address(pool)), pool.reserve0());
            assertEq(token1.balanceOf(address(pool)), pool.reserve1());
        }
    }

    function test_FirstDepositRespectsMinShares() public {
        // A first deposit of 1,000 / 1,000 mints 900 provider shares.
        vm.expectRevert(abi.encodeWithSelector(Pool.SlippageExceeded.selector, 900, 901));

        vm.prank(lp);
        pool.addLiquidity(1_000, 1_000, 901);

        // The rejected first deposit must leave the pool unchanged.
        assertEq(pool.reserve0(), 0);
        assertEq(pool.reserve1(), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.shares(lp), 0);
        assertEq(token0.balanceOf(address(pool)), 0);
        assertEq(token1.balanceOf(address(pool)), 0);

        // Exactly 900 shares meets the minimum and should succeed.
        vm.prank(lp);
        uint256 minted = pool.addLiquidity(1_000, 1_000, 900);

        assertEq(minted, 900);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 1_000);
        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);
    }
}
