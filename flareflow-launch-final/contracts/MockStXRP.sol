// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-20 mock for testnet — simulates sFLR and stXRP
contract MockStXRP {
    string public name;
    string public symbol;
    uint8  public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
        // Mint 10M tokens to deployer for testing
        uint256 initial = 10_000_000 * 1e18;
        balanceOf[msg.sender] = initial;
        totalSupply = initial;
        emit Transfer(address(0), msg.sender, initial);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Test helper — mint tokens to any address
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Simulate rebasing yield — increases balance of vault
    function simulateYield(address vault, uint256 amount) external {
        balanceOf[vault] += amount;
        totalSupply += amount;
        emit Transfer(address(0), vault, amount);
    }
}
