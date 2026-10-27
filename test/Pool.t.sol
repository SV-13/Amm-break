// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../src/Pool.sol";

contract PoolTest is Test {
    Pool pool;

    function setUp() public {
        pool = new Pool();
    }

    function test_SmallTrade() public view {
        assertEq(pool.getAmountOut(10, 100, 100), 9);
    }

    function test_BigTrade() public view {
        assertEq(pool.getAmountOut(50, 100, 100), 33);
    }

    function test_RevertsOnZeroInput() public {
        vm.expectRevert(Pool.ZeroInput.selector);
        pool.getAmountOut(0, 100, 100);
    }

    function test_RevertsOnEmptyReserves() public {
        vm.expectRevert(Pool.NoLiquidity.selector);
        pool.getAmountOut(10, 0, 100);

        vm.expectRevert(Pool.NoLiquidity.selector);
        pool.getAmountOut(10, 100, 0);
    }

    function testFuzz_KNeverDecreases(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) public {
        // Bound the inputs to realistic values and avoid unrelated overflows.
        reserveIn = bound(reserveIn, 1, 1e30);
        reserveOut = bound(reserveOut, 1, 1e30);
        amountIn = bound(amountIn, 1, 1e30);

        uint256 out = pool.getAmountOut(amountIn, reserveIn, reserveOut);

        uint256 kBefore = reserveIn * reserveOut;
        uint256 kAfter = (reserveIn + amountIn) * (reserveOut - out);

        assertGe(kAfter, kBefore);
    }
}
