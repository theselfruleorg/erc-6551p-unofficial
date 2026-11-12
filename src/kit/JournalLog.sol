// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title JournalLog — the on-chain journal of ERC-6551 accounts.
/// @notice No owner, no storage, no value. An account's owner calls `log(entry)` THROUGH the account
///         (`execute` / `executeBatch`, usually in the same batch as the action the entry describes), so the event's
///         `account` is the account itself: only the NFT's current owner can write to an account's journal. The entry
///         bytes are the journal line that the writer signs (its format is the writer's choice); a reader takes the events of one
///         account with `eth_getLogs` (topic 1 = the account) and checks the signatures and the hash chain itself.
contract JournalLog {
    /// @notice One journal entry of `account` (the caller). The contract never reads or checks `entry`.
    event Entry(address indexed account, bytes entry);

    function log(bytes calldata entry) external {
        emit Entry(msg.sender, entry);
    }
}
