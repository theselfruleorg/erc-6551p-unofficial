// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccountedERC721} from "./AccountedERC721.sol";
import {IERC6551PAccountView} from "../interfaces/ITransferSafe.sol";
import {IERC6551PCollection} from "../interfaces/IERC6551P.sol";

/// @title ERC6551PCollection — the collection rule of ERC-6551P (a DRAFT extension of ERC-6551; docs/erc-6551p.md).
/// @notice An `AccountedERC721` whose every token owns an ERC-6551P account, plus the sale rule: a transfer made by
///         anyone other than the current owner passes only when the token's account is not inside a batch, the seller
///         is not an ERC-6551 account, and either (a) the token is READY — `readyToSell` by the same owner in an
///         EARLIER transaction, the account's `state()` unchanged since — or (b) a one-use TICKET of `MARKET` or `ZONE`
///         matches (`from`, `to`, the account's state), and is consumed. The owner's own transfer and the mint are not
///         affected. Every transfer ends readiness and counts in `transferCount` (ERC-5646 input).
///         Collection-agnostic: no traits, no art, no economics. The inheriting contract checks its constructor
///         arguments, and may react to readiness changes in `_onReadyChanged` (ERC-7496 / ERC-4906 events).
/// @dev Implements `IERC6551PCollection` (src/interfaces/IERC6551P.sol). It does not answer that ERC-165 id in
///      `supportsInterface`: a collection adds it (the example does).
///      The account implementation, the market and the zone are immutables of the inheriting deploy (no setter).
///      Transient storage (EIP-1153): `readiedNow` (readyToSell in this transaction) and the ticket of an id (4 slots:
///      from | open << 160 | consumed << 161, to, opener, the account state at the opening).
abstract contract ERC6551PCollection is AccountedERC721, IERC6551PCollection {
    /// @notice The ERC-6551P account implementation every token's account clones.
    address public immutable ACCOUNT_IMPL;
    /// @notice The checked market and the Seaport zone: the only addresses that open a sale ticket.
    address public immutable MARKET;
    address public immutable ZONE;

    /// @notice Sale readiness: keccak256(owner, account.state()) at `readyToSell`; 0 = not ready.
    mapping(uint256 => bytes32) internal _readyKey;

    /// @notice Every transfer with `from != 0`.
    mapping(uint256 => uint256) public transferCount;

    bytes32 private constant _READIED_SEED = keccak256("erc6551p.readiedNow");
    bytes32 private constant _TICKET_SEED = keccak256("erc6551p.ticket");

    bytes4 private constant _IID_ERC5646 = 0xf5112315;

    error NonexistentToken();
    error SaleNotReady();
    error AccountInBatch();
    error SellerIsAccount();
    error NotTicketOpener();
    error TicketBusy();
    error NotTokenAccount();
    error NotTokenOwner();

    constructor(address accountImpl_, address market_, address zone_) {
        ACCOUNT_IMPL = accountImpl_;
        MARKET = market_;
        ZONE = zone_;
    }

    function accountImplementation() public view override returns (address) {
        return ACCOUNT_IMPL;
    }

    /// @dev Readiness of `id` was set (`ready`) or ended. The base emits `SaleReady` on a set; the drop adds its events.
    function _onReadyChanged(uint256 id, bool ready) internal virtual {}

    // ---------------------------------------------------------------- sale readiness
    /// @notice The token's OWN account only (`msg.sender == accountOf(id)`), as the last leg of an account batch (the
    ///         account refuses any later leg but a JournalLog entry). Records keccak256(owner, account.state()); the
    ///         account updates `state()` at the start of every batch, so any later batch ends readiness. Refused when
    ///         the owner is itself an ERC-6551 account (its control can change without a transfer of this token).
    ///         A ready record made in this transaction does not count for a transfer in this transaction.
    function readyToSell(uint256 id) external {
        address owner_ = _ownerOf(id);
        if (owner_ == address(0)) revert NonexistentToken();
        address a = accountOf(id);
        if (msg.sender != a) revert NotTokenAccount();
        if (_isERC6551Account(owner_)) revert SellerIsAccount();
        uint256 st = IERC6551PAccountView(a).state();
        _readyKey[id] = keccak256(abi.encode(owner_, st));
        _tset(_slot(_READIED_SEED, id), 1);
        emit SaleReady(id, owner_, st);
        _onReadyChanged(id, true);
    }

    /// @notice The token owner or its account: ends readiness now (any account batch ends it too).
    function cancelReady(uint256 id) external {
        address owner_ = _ownerOf(id);
        if (owner_ == address(0)) revert NonexistentToken();
        if (msg.sender != owner_ && msg.sender != accountOf(id)) revert NotTokenOwner();
        _clearReady(id);
    }

    /// @notice True while the token is ready to sell: recorded by `readyToSell`, the same owner, the account's
    ///         `state()` unchanged since then.
    function saleReadyOf(uint256 id) public view returns (bool) {
        address owner_ = _ownerOf(id);
        bytes32 k = _readyKey[id];
        if (owner_ == address(0) || k == bytes32(0)) return false;
        return k == keccak256(abi.encode(owner_, IERC6551PAccountView(accountOf(id)).state()));
    }

    /// @notice ERC-5646: keccak256(owner, transferCount, account.state()).
    function getStateFingerprint(uint256 id) external view returns (bytes32) {
        return keccak256(abi.encode(ownerOf(id), transferCount[id], IERC6551PAccountView(accountOf(id)).state()));
    }

    function _clearReady(uint256 id) private {
        if (_readyKey[id] != bytes32(0)) {
            delete _readyKey[id];
            _onReadyChanged(id, false);
        }
    }

    // ---------------------------------------------------------------- tickets
    /// @notice MARKET or ZONE only: a one-use permission, for this transaction, of ONE transfer of `id` from `from`
    ///         to `to` while the account's `state()` equals its value now. One ticket per id at a time.
    function openTicket(uint256 id, address from, address to) external {
        if (msg.sender != MARKET && msg.sender != ZONE) revert NotTicketOpener();
        bytes32 b = _slot(_TICKET_SEED, id);
        if (_tget(b) >> 160 & 1 != 0) revert TicketBusy();
        _tset(b, uint256(uint160(from)) | 1 << 160);
        _tset(bytes32(uint256(b) + 1), uint160(to));
        _tset(bytes32(uint256(b) + 2), uint160(msg.sender));
        _tset(bytes32(uint256(b) + 3), IERC6551PAccountView(accountOf(id)).state());
    }

    /// @notice True when the open ticket of `id` served its transfer and the account's state is still the state at
    ///         the opening.
    function ticketConsumed(uint256 id) external view returns (bool) {
        bytes32 b = _slot(_TICKET_SEED, id);
        return _tget(b) >> 160 == 3 && _tget(bytes32(uint256(b) + 3)) == IERC6551PAccountView(accountOf(id)).state();
    }

    /// @notice The opener only: closes the ticket of `id` (used or not).
    function closeTicket(uint256 id) external {
        bytes32 b = _slot(_TICKET_SEED, id);
        if (_tget(b) >> 160 & 1 == 0 || address(uint160(_tget(bytes32(uint256(b) + 2)))) != msg.sender) {
            revert NotTicketOpener();
        }
        for (uint256 k; k < 4; k++) {
            _tset(bytes32(uint256(b) + k), 0);
        }
    }

    // ---------------------------------------------------------------- transfers
    /// @dev No-nesting (AccountedERC721) and the ERC-721 authorization run first (super). Then the sale rule: a
    ///      transfer made by anyone other than the current owner (`auth != from`: a marketplace, its conduit, the
    ///      market, any approved address) passes only when the account is not inside a batch, `from` is not an
    ///      ERC-6551 account, and either an open, unused ticket matches (`from`, `to`, the account's state) — it is
    ///      consumed — or the token is READY (`readyToSell` by the same owner in an EARLIER transaction, the account's
    ///      `state()` unchanged since). A transfer by the owner itself and the mint are not affected. Every transfer
    ///      ends readiness and counts in `transferCount`.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0)) {
            if (auth != address(0) && auth != from) _checkSale(tokenId, from, to);
            _clearReady(tokenId);
            unchecked {
                transferCount[tokenId]++;
            }
        }
    }

    function _checkSale(uint256 id, address from, address to) private {
        IERC6551PAccountView a = IERC6551PAccountView(accountOf(id));
        if (a.inBatch()) revert AccountInBatch();
        if (_isERC6551Account(from)) revert SellerIsAccount();
        uint256 st = a.state();
        bytes32 b = _slot(_TICKET_SEED, id);
        uint256 head = _tget(b);
        if (
            head >> 160 == 1 && address(uint160(head)) == from && address(uint160(_tget(bytes32(uint256(b) + 1)))) == to
                && _tget(bytes32(uint256(b) + 3)) == st
        ) {
            _tset(b, head | 1 << 161); // consumed
            return;
        }
        bytes32 k = _readyKey[id];
        if (k != bytes32(0) && k == keccak256(abi.encode(from, st)) && _tget(_slot(_READIED_SEED, id)) == 0) return;
        revert SaleNotReady();
    }

    /// @dev Any ERC-6551 account in the registry's clone format (173 bytes: header ‖ impl ‖ tail ‖ footer), of any
    ///      implementation.
    function _isERC6551Account(address x) internal view returns (bool yes) {
        if (x.code.length != 173) return false;
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(x, p, 0, 45)
            let head := shr(176, mload(p)) // bytes 0..9
            let tail := shr(136, mload(add(p, 30))) // bytes 30..44
            yes := and(eq(head, 0x363d3d373d3d3d363d73), eq(tail, 0x5af43d82803e903d91602b57fd5bf3))
        }
    }

    function _slot(bytes32 seed, uint256 id) private pure returns (bytes32) {
        return keccak256(abi.encode(seed, id));
    }

    function _tget(bytes32 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tset(bytes32 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    /// @notice + ERC-5646 (`getStateFingerprint`).
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == _IID_ERC5646 || super.supportsInterface(interfaceId);
    }
}
