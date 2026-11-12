// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ERC-6551P interfaces (docs/erc-6551p.md) — a DRAFT extension of ERC-6551, not an accepted ERC.
/// @notice The account side is `ITransferSafeAccount` (src/interfaces/ITransferSafe.sol, ERC-165 id 0x92ad233c); this
///         file holds the collection side, the part a collection inherits from `ERC6551PCollection`
///         (src/kit/ERC6551PCollection.sol). The ERC-165 id of `IERC6551PCollection` is pinned by
///         test/ERC6551PExample.t.sol (`type(IERC6551PCollection).interfaceId`).
interface IERC6551PCollection {
    /// @notice `owner` made `id` ready to sell while its account's `state()` was `state`.
    event SaleReady(uint256 indexed id, address indexed owner, uint256 state);

    /// @notice The token's own account only, as the last leg of an account batch: records (owner, account state).
    function readyToSell(uint256 id) external;

    /// @notice The token owner or its account: ends readiness now.
    function cancelReady(uint256 id) external;

    /// @notice True while the readiness record matches the current owner and the account's current `state()`.
    function saleReadyOf(uint256 id) external view returns (bool);

    /// @notice The number of transfers of `id` with `from != 0`.
    function transferCount(uint256 id) external view returns (uint256);

    /// @notice A ticket opener only: a one-use permission, for this transaction, of one transfer of `id` from `from` to
    ///         `to` while the account's `state()` equals its value now.
    function openTicket(uint256 id, address from, address to) external;

    /// @notice True when the open ticket of `id` served its transfer and the account's state is unchanged since the
    ///         opening.
    function ticketConsumed(uint256 id) external view returns (bool);

    /// @notice The opener only: frees the ticket slot of `id`.
    function closeTicket(uint256 id) external;

    /// @notice The checked market: one of the two ticket openers.
    function MARKET() external view returns (address);

    /// @notice The Seaport 1.6 zone: the other ticket opener.
    function ZONE() external view returns (address);
}
