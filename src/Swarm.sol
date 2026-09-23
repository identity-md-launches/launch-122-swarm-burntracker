// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Swarm (SWORM)
/// @notice An ERC-20 with 18 decimals and a 1% burn on every transfer.
/// @dev Deployment mints 1,000,000 tokens to msg.sender. There is no owner, initializer,
/// mint function, fee exemption, or external dependency. Deploy BurnTracker with this
/// contract's address to read the cumulative burn, including burns before its deployment.
///
/// Amounts are in base units. Each transfer burns floor(amount / 100) and credits the
/// remainder to the recipient; fractions of a base unit cannot be burned. For example,
/// transferring 100 tokens burns 1 token and delivers 99. Transferring 99 base units
/// burns zero. A self-transfer requires the full amount but only reduces the balance
/// by the burn. Zero-amount transfers emit a Transfer event and do not change supply.
/// transferFrom spends allowance on the full amount; unlimited approvals stay unlimited.
contract Swarm {
    string public constant name = "Swarm";
    string public constant symbol = "SWORM";
    uint8 public constant decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 10 ** 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert ERC20InsufficientAllowance(msg.sender, approved, amount);
            allowance[from][msg.sender] = approved - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 balance = balanceOf[from];
        if (balance < amount) revert ERC20InsufficientBalance(from, balance, amount);

        uint256 burned = amount / 100;
        uint256 received = amount - burned;

        // Debit before crediting so aliased sender/recipient balances lose only the burn.
        balanceOf[from] = balance - amount;
        balanceOf[to] += received;
        // The sum of all balances equals totalSupply, which can only decrease.
        totalSupply -= burned;

        emit Transfer(from, to, received);
        if (burned != 0) emit Transfer(from, address(0), burned);
    }
}
