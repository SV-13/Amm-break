// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Pool} from "../src/Pool.sol";

contract MinSharesFixTest is Test {
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

    function test_SkewAttackRevertsWhenMinSharesIsSet() public {
        // Attacker seeds the pool, then skews its reserves.
        vm.prank(attacker);
        pool.addLiquidity(1_000, 1_000, 0);

        vm.prank(attacker);
        pool.addLiquidity(30_000, 1_000, 0);

        assertEq(pool.reserve0(), 31_000);
        assertEq(pool.reserve1(), 2_000);
        assertEq(pool.totalShares(), 2_000);

        // Snapshot the victim's wallet and pool state before the deposit.
        uint256 victimToken0Before = token0.balanceOf(victim);
        uint256 victimToken1Before = token1.balanceOf(victim);
        uint256 reserve0Before = pool.reserve0();
        uint256 reserve1Before = pool.reserve1();
        uint256 totalSharesBefore = pool.totalShares();

        // The victim expects at least 9,900 shares.
        vm.expectRevert(abi.encodeWithSelector(Pool.SlippageExceeded.selector, 645, 9_900));

        vm.prank(victim);
        pool.addLiquidity(10_000, 10_000, 9_900);

        // A rejected deposit changes neither wallet nor pool state.
        assertEq(token0.balanceOf(victim), victimToken0Before);
        assertEq(token1.balanceOf(victim), victimToken1Before);
        assertEq(pool.reserve0(), reserve0Before);
        assertEq(pool.reserve1(), reserve1Before);
        assertEq(pool.totalShares(), totalSharesBefore);
        assertEq(pool.shares(victim), 0);

        assertEq(token0.balanceOf(address(pool)), reserve0Before);
        assertEq(token1.balanceOf(address(pool)), reserve1Before);
    }

    function test_HonestDepositPassesWithMinShares() public {
        // No skew: the pool remains balanced.
        vm.prank(attacker);
        pool.addLiquidity(1_000, 1_000, 0);

        vm.prank(victim);
        uint256 minted = pool.addLiquidity(10_000, 10_000, 9_900);

        assertEq(minted, 10_000);
        assertEq(pool.shares(victim), 10_000);
        assertEq(pool.totalShares(), 11_000);
        assertEq(pool.reserve0(), 11_000);
        assertEq(pool.reserve1(), 11_000);

        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    function test_MinSharesBoundary() public {
        vm.prank(attacker);
        pool.addLiquidity(1_000, 1_000, 0);

        // Requiring one more share than the deposit would mint must revert.
        vm.expectRevert(abi.encodeWithSelector(Pool.SlippageExceeded.selector, 10_000, 10_001));

        vm.prank(victim);
        pool.addLiquidity(10_000, 10_000, 10_001);

        // The exact boundary must succeed: minted == minShares.
        vm.prank(victim);
        uint256 minted = pool.addLiquidity(10_000, 10_000, 10_000);

        assertEq(minted, 10_000);
        assertEq(pool.shares(victim), 10_000);
        assertEq(pool.totalShares(), 11_000);
        assertEq(pool.reserve0(), 11_000);
        assertEq(pool.reserve1(), 11_000);
    }
}
