// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../../src/Token.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolHandler} from "./PoolHandler.sol";

contract PoolInvariantTest is Test {
    uint256 internal constant LOCKED_SHARES = 100;
    // Mirrors Pool.MINIMUM_LIQUIDITY, which is private.

    Token token0;
    Token token1;
    Pool pool;
    PoolHandler handler;

    function setUp() public {
        token0 = new Token("Token 0", "T0");
        token1 = new Token("Token 1", "T1");
        pool = new Pool(token0, token1);
        handler = new PoolHandler(token0, token1, pool);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PoolHandler.swap.selector;
        selectors[1] = PoolHandler.addLiquidity.selector;
        selectors[2] = PoolHandler.removeLiquidity.selector;

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

        assertEq(accountedShares, pool.totalShares());
    }

    /// Rule 3: No executed swap may decrease the constant product.
    function invariant_SwapsNeverLowerK() public view {
        assertEq(handler.kDecreases(), 0);
    }
}
