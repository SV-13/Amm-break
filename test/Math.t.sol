// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "../src/Math.sol";

contract MathTest is Test {
    function test_SqrtSmallValues() public pure {
        assertEq(Math.sqrt(0), 0);
        assertEq(Math.sqrt(1), 1);
        assertEq(Math.sqrt(3), 1);
        assertEq(Math.sqrt(10), 3);
        assertEq(Math.sqrt(1_000_000), 1_000);
    }

    function testFuzz_SqrtIsFloor(uint256 y) public pure {
        y = bound(y, 0, type(uint128).max);

        uint256 r = Math.sqrt(y);

        assertLe(r * r, y);
        assertGt((r + 1) * (r + 1), y);
    }
}
