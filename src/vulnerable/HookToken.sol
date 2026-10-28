// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// INTENTIONALLY VULNERABLE, educational, never deploy.

import {Token} from "../Token.sol";

interface ITokenReceiver {
    function onTokenReceived(address from, uint256 amount) external;
}

contract HookToken is Token {
    constructor(string memory name_, string memory symbol_) Token(name_, symbol_) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        // First perform the normal token transfer.
        bool success = super.transfer(to, amount);

        // Then call the recipient if it is a contract.
        if (to.code.length > 0) {
            ITokenReceiver(to).onTokenReceived(msg.sender, amount);
        }

        return success;
    }
}
