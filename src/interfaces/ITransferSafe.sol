// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The transfer-safe account surface the collection, the market and the zone read.
///         ERC-165 id = `inBatch()` (0x92ad233c).
interface ITransferSafeAccount {
    /// @notice True while a batch of the account runs (the collection refuses a non-owner transfer then).
    function inBatch() external view returns (bool);
}

/// @notice The account reads the collection and the checked sale need (ERC-6551 `token`, `owner`, `state`).
interface IERC6551PAccountView is ITransferSafeAccount {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function owner() external view returns (address);
    function state() external view returns (uint256);
}

/// @notice The collection surface of the checked sale.
interface ITransferSafeCollection {
    function MARKET() external view returns (address);
    function ZONE() external view returns (address);
    function transferCount(uint256 id) external view returns (uint256);
    function positionOf(uint256 id) external view returns (uint256);
    function saleReadyOf(uint256 id) external view returns (bool);
    function hasIdentity(uint256 id) external view returns (bool);
    function agentIdOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function openTicket(uint256 id, address from, address to) external;
    function ticketConsumed(uint256 id) external view returns (bool);
    function closeTicket(uint256 id) external;
}
