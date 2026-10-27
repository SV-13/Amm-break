// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";

contract TokenTest is Test {
    Token token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

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

    function test_ApproveSetsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 500);

        assertEq(token.allowance(alice, bob), 500);
        assertEq(token.balanceOf(alice), 1_000);
    }

    function test_TransferFromMovesTokensAndSpendsAllowance() public {
        // Alice gives Bob permission to spend 500 tokens.
        vm.prank(alice);
        token.approve(bob, 500);

        // Bob uses 200 of Alice's tokens to pay Carol.
        vm.prank(bob);
        token.transferFrom(alice, carol, 200);

        assertEq(token.balanceOf(alice), 800);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 200);
        assertEq(token.allowance(alice, bob), 300);
        assertEq(token.totalSupply(), 1_000);
    }

    function test_TransferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientAllowance.selector, 0, 1));

        vm.prank(bob);
        token.transferFrom(alice, carol, 1);
    }

    function test_TransferFromRevertsWhenBalanceTooLow() public {
        // Alice approves more than she actually owns.
        vm.prank(alice);
        token.approve(bob, 5_000);

        vm.expectRevert(abi.encodeWithSelector(Token.InsufficientBalance.selector, 1_000, 1_001));

        vm.prank(bob);
        token.transferFrom(alice, carol, 1_001);

        // The failed transfer must not change the state.
        assertEq(token.balanceOf(alice), 1_000);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.allowance(alice, bob), 5_000);
        assertEq(token.totalSupply(), 1_000);
    }

    function test_SelfTransferChangesNothing() public {
        vm.prank(alice);
        token.transfer(alice, 300);

        assertEq(token.balanceOf(alice), 1_000);
        assertEq(token.totalSupply(), 1_000);
    }
}
