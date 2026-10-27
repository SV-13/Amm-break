// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";

contract TokenTest is Test {
    Token token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new Token("Test Token", "TT");
        token.mint(alice, 1_000);
    }

    function test_MintCreditsBalanceAndSupply() public view {
        assertEq(token.totalSupply(), 1_000);
        assertEq(token.balanceOf(alice), 1_000);
    }

    function test_TransferMovesBalance() public {
        vm.prank(alice);
        token.transfer(bob, 300);

        assertEq(token.balanceOf(alice), 700);
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.totalSupply(), 1_000);
    }

    function test_TransferRevertsWhenBalanceTooLow() public {
        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientBalance.selector, 1_000, 1_001));

        vm.prank(alice);
        token.transfer(bob, 1_001);

        assertEq(token.balanceOf(alice), 1_000);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), 1_000);
    }
}
