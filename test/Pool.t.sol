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

    // Existing formula tests

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

    function testFuzz_KNeverDecreases(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) public {
        reserveIn = bound(reserveIn, 1, 1e30);
        reserveOut = bound(reserveOut, 1, 1e30);
        amountIn = bound(amountIn, 1, 1e30);

        uint256 out = pool.getAmountOut(amountIn, reserveIn, reserveOut);

        uint256 kBefore = reserveIn * reserveOut;
        uint256 kAfter = (reserveIn + amountIn) * (reserveOut - out);

        assertGe(kAfter, kBefore);
    }

    function _seedPool() internal {
        vm.prank(lp);
        pool.addLiquidity(1_000, 1_000);
    }

    function test_AddLiquiditySetsReservesAndHoldsTokens() public {
        _seedPool();

        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);

        assertEq(token0.balanceOf(address(pool)), 1_000);
        assertEq(token1.balanceOf(address(pool)), 1_000);

        assertEq(token0.balanceOf(lp), 9_000);
        assertEq(token1.balanceOf(lp), 9_000);
    }

    function test_SwapMatchesHandTrace() public {
        _seedPool();

        vm.prank(alice);
        uint256 amountOut = pool.swap(token0, 100, 90);

        assertEq(amountOut, 90);

        // Recorded reserves match the hand trace.
        assertEq(pool.reserve0(), 1_100);
        assertEq(pool.reserve1(), 910);

        // Alice sent 100 token0 and received 90 token1.
        assertEq(token0.balanceOf(alice), 9_900);
        assertEq(token1.balanceOf(alice), 10_090);

        // The real token balances must match recorded reserves.
        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    function test_SwapRevertsBelowMinAmountOut() public {
        _seedPool();

        vm.expectRevert(abi.encodeWithSelector(Pool.SlippageExceeded.selector, 90, 91));

        vm.prank(alice);
        pool.swap(token0, 100, 91);

        // The reverted swap must not alter pool state.
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
        _seedPool();

        vm.expectRevert(Pool.ZeroOutput.selector);

        vm.prank(alice);
        pool.swap(token0, 1, 0);

        // A rejected dust swap leaves everything unchanged.
        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);
        assertEq(token0.balanceOf(alice), 10_000);
    }
}
