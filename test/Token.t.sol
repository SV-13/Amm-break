pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Token} from "../src/Token.sol";

contract TokenTest is Test {
    Token token;
    address alice = makeAddr("alice");

    function setUp() public {
        token = new Token("Test Token", "TT");
        token.mint(alice, 1_000);
    }

    function test_MintCreditsBalanceAndSupply() public view {
        assertEq(token.totalSupply(), 1_000);
        assertEq(token.balanceOf(alice), 1_000);
    }
}
