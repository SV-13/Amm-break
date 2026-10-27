// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice A minimal ERC-20 style token, written by hand for the AMM lab.
contract Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    
    error InsufficientBalance(uint256 have, uint256 want);    
    
    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }
    /// @dev Open mint, for tests only. A real token would never allow this
    function mint(address to, uint256 amount) external {
       totalSupply += amount;
       balanceOf[to] += amount;
       emit Transfer(address(0), to, amount);
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 have = balanceOf[msg.sender];
        if (have < amount) {
            revert InsufficientBalance(have, amount);
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}
