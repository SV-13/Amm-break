// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../../src/Token.sol";
import {Pool} from "../../src/Pool.sol";

/// @notice Restricts invariant fuzzing to bounded, valid pool operations.
contract PoolHandler is Test {
    Token public token0;
    Token public token1;
    Pool public pool;

    address[] public actors;
    address internal currentActor;

    // Ghost variables: facts the pool does not store itself.
    uint256 public swapCount;
    uint256 public addCount;
    uint256 public removeCount;
    uint256 public kDecreases;

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];

        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(Token _token0, Token _token1, Pool _pool) {
        token0 = _token0;
        token1 = _token1;
        pool = _pool;

        // Create three independent actors.
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));

        // Fund every actor and authorize the pool.
        for (uint256 i = 0; i < actors.length; i++) {
            token0.mint(actors[i], 1e24);
            token1.mint(actors[i], 1e24);

            vm.startPrank(actors[i]);
            token0.approve(address(pool), type(uint256).max);
            token1.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }

        // Seed the pool so handlers can perform valid actions.
        vm.prank(actors[0]);
        pool.addLiquidity(1_000_000, 1_000_000, 0);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amountIn) external useActor(actorSeed) {
        Token tokenIn = zeroForOne ? token0 : token1;

        uint256 reserveIn = zeroForOne ? pool.reserve0() : pool.reserve1();
        uint256 reserveOut = zeroForOne ? pool.reserve1() : pool.reserve0();

        if (reserveIn == 0 || reserveOut == 0) {
            return;
        }

        amountIn = bound(amountIn, 1, reserveIn);

        // Skip dust trades that would produce no output.
        uint256 expectedOut = pool.getAmountOut(amountIn, reserveIn, reserveOut);

        if (expectedOut == 0) {
            return;
        }

        uint256 kBefore = pool.reserve0() * pool.reserve1();

        pool.swap(tokenIn, amountIn, 0);

        uint256 kAfter = pool.reserve0() * pool.reserve1();

        if (kAfter < kBefore) {
            kDecreases++;
        }

        swapCount++;
    }

    function addLiquidity(uint256 actorSeed, uint256 amount0, uint256 amount1) external useActor(actorSeed) {
        amount0 = bound(amount0, 1_000, 1_000_000);
        amount1 = bound(amount1, 1_000, 1_000_000);

        uint256 reserve0 = pool.reserve0();
        uint256 reserve1 = pool.reserve1();
        uint256 totalShares = pool.totalShares();

        if (reserve0 == 0 || reserve1 == 0 || totalShares == 0) {
            return;
        }

        // Skip deposits that would mint zero shares.
        uint256 shares0 = (amount0 * totalShares) / reserve0;
        uint256 shares1 = (amount1 * totalShares) / reserve1;

        if (shares0 == 0 || shares1 == 0) {
            return;
        }

        pool.addLiquidity(amount0, amount1, 0);
        addCount++;
    }

    function removeLiquidity(uint256 actorSeed, uint256 sharesToBurn) external useActor(actorSeed) {
        uint256 ownedShares = pool.shares(currentActor);

        if (ownedShares == 0) {
            return;
        }

        sharesToBurn = bound(sharesToBurn, 1, ownedShares);

        uint256 totalShares = pool.totalShares();

        if (totalShares == 0) {
            return;
        }

        // Avoid calls that would revert because either payout rounds to zero.
        uint256 amount0 = (sharesToBurn * pool.reserve0()) / totalShares;
        uint256 amount1 = (sharesToBurn * pool.reserve1()) / totalShares;

        if (amount0 == 0 || amount1 == 0) {
            return;
        }
        pool.removeLiquidity(sharesToBurn);
        removeCount++;
    }
}
