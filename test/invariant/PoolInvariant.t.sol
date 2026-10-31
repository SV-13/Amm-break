// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../../src/Token.sol";
import {Pool} from "../../src/Pool.sol";
import {HookToken} from "../../src/vulnerable/HookToken.sol";
import {PoolHandler} from "./PoolHandler.sol";

contract PoolInvariantTest is Test {
    // Mirrors Pool.MINIMUM_LIQUIDITY, which is private.
    uint256 internal constant LOCKED_SHARES = 100;

    Token token0;
    Token token1;
    Pool pool;
    PoolHandler handler;

    function setUp() public {
        // token0 calls the recipient when the pool transfers tokens out.
        token0 = new HookToken("Token 0", "T0");
        token1 = new Token("Token 1", "T1");

        pool = new Pool(token0, token1);
        handler = new PoolHandler(token0, token1, pool);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PoolHandler.swap.selector;
        selectors[1] = PoolHandler.addLiquidity.selector;
        selectors[2] = PoolHandler.removeLiquidity.selector;
        selectors[3] = PoolHandler.addLiquidityAtBoundary.selector;
        selectors[4] = PoolHandler.attackerRound.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Rule 1: Actual token balances must match recorded reserves.
    function invariant_ReservesMatchBalances() public view {
        assertEq(token0.balanceOf(address(pool)), pool.reserve0());
        assertEq(token1.balanceOf(address(pool)), pool.reserve1());
    }

    /// Rule 2: All shares belong to actors or remain permanently locked.
    function invariant_SharesAccountForTotal() public view {
        uint256 accountedShares = LOCKED_SHARES;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            accountedShares += pool.shares(handler.actors(i));
        }
        accountedShares += pool.shares(address(handler.attacker()));
        assertEq(accountedShares, pool.totalShares());
    }

    /// Rule 3: No executed swap may decrease the constant product.
    function invariant_SwapsNeverLowerK() public view {
        assertEq(handler.kDecreases(), 0);
    }

    /// Rule 4: Liquidity operations must never dilute existing shares.
    function invariant_NoDilution() public view {
        assertEq(handler.dilutions(), 0);
    }

    /// Rule 5: Minimum-shares boundary checks must always behave correctly.
    function invariant_MinSharesBoundaryHolds() public view {
        assertEq(handler.boundaryViolations(), 0);
    }
}

