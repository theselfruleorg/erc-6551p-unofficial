// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Condition, Conditions} from "./Conditions.sol";
import {ITransferSafeCollection} from "../interfaces/ITransferSafe.sol";
import {ZoneParameters, SpentItem, ReceivedItem, ItemType} from "../interfaces/ISeaport16.sol";

/// @title ERC6551PZone — the checked sale inside a Seaport 1.6 restricted order.
/// @notice Seaport calls `authorizeOrder` before the transfers and `validateOrder` after them, for order types 2–3 only.
///         The zone accepts calls only from SEAPORT and never calls Seaport. An order carries exactly one NFT of the collection
///         (ERC-721, amount 1) of a collection that names this zone.
///         - A LISTING (the NFT is the one offer item; offerer = seller): `zoneHash = keccak256(abi.encode(
///           transferCount, sellerPromise))`, `extraData = abi.encode(sellerPromise, buyerConditions)` from the fulfiller (the
///           buyer); the ticket is (offerer → fulfiller), so the recipient must be the fulfiller.
///         - An OFFER (the NFT is a consideration item to the offerer; offerer = buyer): `zoneHash =
///           keccak256(abi.encode(conditions))`, `extraData = abi.encode(conditions)` (the preimage only); the ticket
///           is (fulfiller → offerer).
///         `authorizeOrder` opens the collection's ticket; `validateOrder` requires it served the transfer with the
///         account state unchanged, checks the conditions on the account the zone computes, and closes it. No
///         consideration item may pay the sold account. A basic order (empty `extraData`) is refused.
contract ERC6551PZone {
    address public immutable SEAPORT;
    address public immutable ACCOUNT_IMPL;

    bytes4 internal constant AUTHORIZE_MAGIC = 0x01e4d72a; // authorizeOrder(ZoneParameters)
    bytes4 internal constant VALIDATE_MAGIC = 0x17b1f942; // validateOrder(ZoneParameters)

    struct Sale {
        ITransferSafeCollection c;
        uint256 id;
        address from;
        address to;
        Condition[] sellerPromise;
        Condition[] buyer;
    }

    error NotSeaport();
    error BadOrder();
    error BadZoneHash();
    error NotThisZone();
    error SellerIsAccount();
    error NotConsumed();
    error NotDelivered();

    struct Schema {
        uint256 id;
        bytes metadata;
    }

    constructor(address seaport, address accountImpl) {
        SEAPORT = seaport;
        ACCOUNT_IMPL = accountImpl;
    }

    function authorizeOrder(ZoneParameters calldata z) external returns (bytes4) {
        Sale memory s = _sale(z, true);
        s.c.openTicket(s.id, s.from, s.to);
        return AUTHORIZE_MAGIC;
    }

    function validateOrder(ZoneParameters calldata z) external returns (bytes4) {
        Sale memory s = _sale(z, false);
        if (!s.c.ticketConsumed(s.id)) revert NotConsumed();
        if (s.c.ownerOf(s.id) != s.to) revert NotDelivered();
        address a = Conditions.accountOf(ACCOUNT_IMPL, address(s.c), s.id);
        Conditions.checkAccount(a, address(s.c), s.id, s.to);
        Conditions.checkAll(s.sellerPromise, s.buyer, a, address(s.c), s.id);
        s.c.closeTicket(s.id);
        return VALIDATE_MAGIC;
    }

    /// @dev Decodes and checks an order: who sells, who buys, which token, which conditions. The listing's zoneHash
    ///      binds `transferCount` BEFORE the transfer, so it is checked in `authorizeOrder` only; Seaport gives
    ///      `validateOrder` the same parameters (seaport-core ConsiderationEncoder.sol:544-569).
    function _sale(ZoneParameters calldata z, bool authorizing) private view returns (Sale memory s) {
        if (msg.sender != SEAPORT) revert NotSeaport();
        if (z.extraData.length == 0) revert BadOrder();
        address token;
        if (z.offer.length == 1 && z.offer[0].itemType == ItemType.ERC721) {
            // a listing
            SpentItem calldata it = z.offer[0];
            if (it.amount != 1) revert BadOrder();
            for (uint256 i; i < z.consideration.length; i++) {
                if (_isNft(z.consideration[i].itemType)) revert BadOrder();
            }
            (token, s.id, s.from, s.to) = (it.token, it.identifier, z.offerer, z.fulfiller);
            s.c = ITransferSafeCollection(token);
            (s.sellerPromise, s.buyer) = abi.decode(z.extraData, (Condition[], Condition[]));
            if (authorizing && keccak256(abi.encode(s.c.transferCount(s.id), s.sellerPromise)) != z.zoneHash) {
                revert BadZoneHash();
            }
        } else {
            // an offer: no NFT offered, exactly one NFT in the consideration, the NFT to the offerer
            for (uint256 i; i < z.offer.length; i++) {
                if (_isNft(z.offer[i].itemType)) revert BadOrder();
            }
            uint256 found;
            for (uint256 i; i < z.consideration.length; i++) {
                ReceivedItem calldata r = z.consideration[i];
                if (!_isNft(r.itemType)) continue;
                if (++found > 1 || r.itemType != ItemType.ERC721 || r.amount != 1 || r.recipient != z.offerer) {
                    revert BadOrder();
                }
                (token, s.id) = (r.token, r.identifier);
            }
            if (found != 1) revert BadOrder();
            (s.from, s.to) = (z.fulfiller, z.offerer);
            s.c = ITransferSafeCollection(token);
            s.buyer = abi.decode(z.extraData, (Condition[]));
            if (keccak256(abi.encode(s.buyer)) != z.zoneHash) revert BadZoneHash();
        }
        if (s.c.ZONE() != address(this)) revert NotThisZone();
        if (s.buyer.length == 0) revert Conditions.NoBuyerConditions();
        if (Conditions.isERC6551Account(s.from)) revert SellerIsAccount();
        address a = Conditions.accountOf(ACCOUNT_IMPL, token, s.id);
        for (uint256 i; i < z.consideration.length; i++) {
            if (z.consideration[i].recipient == a) revert BadOrder();
        }
    }

    function _isNft(ItemType t) private pure returns (bool) {
        return t == ItemType.ERC721 || t == ItemType.ERC1155 || t == ItemType.ERC721_WITH_CRITERIA
            || t == ItemType.ERC1155_WITH_CRITERIA;
    }

    /// @notice Seaport zone metadata (SIP-5): no schemas.
    function getSeaportMetadata() external pure returns (string memory name, Schema[] memory schemas) {
        return ("ERC6551PZone", new Schema[](0));
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x3822a094; // ERC-165, Seaport 1.6 ZoneInterface
    }
}
