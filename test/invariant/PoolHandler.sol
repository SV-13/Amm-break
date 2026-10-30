// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../../src/Token.sol";
import {Pool} from "../../src/Pool.sol";
import {ReentrancyAttacker, IRemovable} from "../ReentrancyAttack.t.sol";

/// @notice Restricts invariant fuzzing to bounded pool operations,
/// including a controlled reentrancy attacker.
contract PoolHandler is Test {
    Token public token0;
    Token public token1;
    Pool public pool;

    ReentrancyAttacker public attacker;

    address[] public actors;
    address internal currentActor;

    // Ghost variables: facts the pool does not store itself.
    uint256 public swapCount;
    uint256 public addCount;
    uint256 public removeCount;
    uint256 public kDecreases;
    uint256 public dilutions;

    // Minimum-shares boundary testing.
    uint256 public boundaryViolations;
    uint256 public boundaryChecks;

    // Hostile-actor testing.
    uint256 public attackRounds;

    struct Snapshot {
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalShares;
    }

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

        // Create the hostile actor. It catches a failed nested withdrawal,
        // allowing the legitimate outer withdrawal to complete.
        attacker = new ReentrancyAttacker(IRemovable(address(pool)), true);

        // Fund the attacker and approve both pool tokens.
        token0.mint(address(attacker), 1e24);
        token1.mint(address(attacker), 1e24);

        vm.startPrank(address(attacker));
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice Captures the pool state relevant to LP dilution.
    function _snapshot() internal view returns (Snapshot memory) {
        return Snapshot({reserve0: pool.reserve0(), reserve1: pool.reserve1(), totalShares: pool.totalShares()});
    }

    /// @notice Detects whether either token's reserve per share decreased.
    function _checkNoDilution(Snapshot memory pre, Snapshot memory post) internal {
        bool token0Diluted = post.reserve0 * pre.totalShares < pre.reserve0 * post.totalShares;

        bool token1Diluted = post.reserve1 * pre.totalShares < pre.reserve1 * post.totalShares;

        if (token0Diluted || token1Diluted) {
            dilutions++;
        }
    }

    /// @notice Checks whether a revert contains the expected custom-error selector.
    function _isSlippageExceeded(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) {
            return false;
        }

        bytes4 selector;

        assembly {
            selector := mload(add(reason, 32))
        }

        return selector == Pool.SlippageExceeded.selector;
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

        Snapshot memory pre = _snapshot();

        pool.addLiquidity(amount0, amount1, 0);

        Snapshot memory post = _snapshot();

        _checkNoDilution(pre, post);

        addCount++;
    }

    /// @notice Tests that minShares rejects one share above the expected amount
    /// and accepts the exact expected amount.
    function addLiquidityAtBoundary(uint256 actorSeed, uint256 amount0, uint256 amount1) external useActor(actorSeed) {
        amount0 = bound(amount0, 1_000, 1_000_000);
        amount1 = bound(amount1, 1_000, 1_000_000);

        uint256 reserve0 = pool.reserve0();
        uint256 reserve1 = pool.reserve1();
        uint256 totalShares = pool.totalShares();

        if (reserve0 == 0 || reserve1 == 0 || totalShares == 0) {
            return;
        }

        // Calculate the exact shares the pool should mint.
        uint256 shares0 = (amount0 * totalShares) / reserve0;
        uint256 shares1 = (amount1 * totalShares) / reserve1;

        uint256 expected = shares0 < shares1 ? shares0 : shares1;

        if (expected == 0) {
            return;
        }

        // One share above the expected amount must revert specifically
        // with Pool.SlippageExceeded.
        Snapshot memory preAboveBoundary = _snapshot();

        try pool.addLiquidity(amount0, amount1, expected + 1) returns (uint256) {
            boundaryViolations++;

            Snapshot memory postAboveBoundary = _snapshot();
            _checkNoDilution(preAboveBoundary, postAboveBoundary);

            addCount++;
        } catch (bytes memory reason) {
            if (!_isSlippageExceeded(reason)) {
                boundaryViolations++;
            }
        }

        // The exact expected amount must succeed.
        Snapshot memory preAtBoundary = _snapshot();

        try pool.addLiquidity(amount0, amount1, expected) returns (uint256) {
            Snapshot memory postAtBoundary = _snapshot();
            _checkNoDilution(preAtBoundary, postAtBoundary);

            addCount++;
        } catch {
            boundaryViolations++;
        }

        boundaryChecks++;
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

        Snapshot memory pre = _snapshot();

        pool.removeLiquidity(sharesToBurn);

        Snapshot memory post = _snapshot();

        _checkNoDilution(pre, post);

        removeCount++;
    }

    /// @notice Deposits for the hostile actor if necessary, then attempts
    /// a withdrawal that triggers its token-receiver callback.
    function attackerRound(uint256 depositSeed, uint256 burnSeed) external {
        uint256 ownedShares = pool.shares(address(attacker));

        if (ownedShares == 0) {
            uint256 amount = bound(depositSeed, 10_000, 1_000_000);

            uint256 reserve0 = pool.reserve0();
            uint256 reserve1 = pool.reserve1();
            uint256 depositTotalShares = pool.totalShares();

            if (reserve0 == 0 || reserve1 == 0 || depositTotalShares == 0) {
                return;
            }

            uint256 shares0 = (amount * depositTotalShares) / reserve0;
            uint256 shares1 = (amount * depositTotalShares) / reserve1;

            uint256 expectedShares = shares0 < shares1 ? shares0 : shares1;

            if (expectedShares == 0) {
                return;
            }

            // Make the deposit as the attacker contract.
            vm.prank(address(attacker));
            pool.addLiquidity(amount, amount, 0);

            ownedShares = pool.shares(address(attacker));
        }

        if (ownedShares == 0) {
            return;
        }

        uint256 burn = bound(burnSeed, 1, ownedShares);

        uint256 totalShares = pool.totalShares();

        if (totalShares == 0) {
            return;
        }

        // Skip withdrawals that would revert because either payout rounds to zero.
        uint256 amount0 = (burn * pool.reserve0()) / totalShares;
        uint256 amount1 = (burn * pool.reserve1()) / totalShares;

        if (amount0 == 0 || amount1 == 0) {
            return;
        }

        // The attacker's token0 receiver hook will attempt one nested withdrawal.
        attacker.attack(burn);

        attackRounds++;
    }
}

