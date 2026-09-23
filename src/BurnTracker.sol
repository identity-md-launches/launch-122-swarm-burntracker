// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Swarm} from "./Swarm.sol";

/// @title Swarm Burn Tracker
/// @notice Deploy with the Swarm token address to read cumulative burns in base units.
/// @dev The token reference is immutable. Initial supply minus current supply includes
/// every burn, even those before this tracker was deployed. There are no update calls,
/// privileged roles, or separately stored counters that could become inconsistent.
contract BurnTracker {
    Swarm public immutable token;

    error InvalidToken(address token);

    constructor(address tokenAddress) {
        if (tokenAddress.code.length == 0) revert InvalidToken(tokenAddress);
        token = Swarm(tokenAddress);
    }

    function totalBurned() external view returns (uint256) {
        return token.INITIAL_SUPPLY() - token.totalSupply();
    }
}
