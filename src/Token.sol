pragma solidity ^0.8.20;

contract Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
       totalSupply += amount;
       balanceOf[to] += amount;
       emit Transfer(address(0), to, amount);
    }
}
