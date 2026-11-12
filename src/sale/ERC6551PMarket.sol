// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Condition, Conditions} from "./Conditions.sol";
import {ITransferSafeCollection} from "../interfaces/ITransferSafe.sol";
import {
    ISeaport16,
    IConduitController,
    AdvancedOrder,
    CriteriaResolver,
    OrderParameters,
    ItemType,
    OrderType
} from "../interfaces/ISeaport16.sol";

/// @title ERC6551PMarket — custody-free checked sales of transfer-safe agent NFTs.
/// @notice Our own listings (`buy`) and offers (`accept`), and a checked fill of any Seaport 1.6 listing
///         (`checkedFill`). On every path the BUYER's conditions (at least one) are read on the sold token's account
///         after the transfer, in the same transaction; a failed condition reverts the whole fill. The market serves
///         any collection that names it (`c.MARKET() == this`); it protects only buyers of a collection whose ERC-721
///         logic is honest. No owner, no fee, no setter, no upgrade. At rest it holds no NFT and no buyer funds, and ETH
///         only as `owed` to named payees.
contract ERC6551PMarket is EIP712 {
    using SafeERC20 for IERC20;

    ISeaport16 public immutable SEAPORT;
    /// @notice The ERC6551PAccount implementation: the market computes the sold token's account itself.
    address public immutable ACCOUNT_IMPL;

    bytes32 public constant LISTING_TYPEHASH = keccak256(
        "Listing(address collection,uint256 id,uint256 transferCount,address seller,address currency,uint256 price,"
        "uint256 maxRoyalty,uint256 expiry,uint256 salt,bytes32 promiseHash,uint256 nonce)"
    );
    bytes32 public constant OFFER_TYPEHASH = keccak256(
        "Offer(address collection,uint256 id,bool anyId,address buyer,address currency,uint256 price,"
        "uint256 maxRoyalty,uint256 expiry,uint256 salt,bytes32 conditionsHash,uint256 nonce)"
    );

    struct Listing {
        address collection;
        uint256 id;
        uint256 transferCount;
        address seller;
        address currency; // address(0) = ETH
        uint256 price;
        uint256 maxRoyalty;
        uint256 expiry;
        uint256 salt;
        bytes32 promiseHash; // keccak256(abi.encode(Condition[] sellerPromise))
        uint256 nonce;
    }

    struct Offer {
        address collection;
        uint256 id;
        bool anyId;
        address buyer;
        address currency; // an ERC-20 only
        uint256 price;
        uint256 maxRoyalty;
        uint256 expiry;
        uint256 salt;
        bytes32 conditionsHash; // keccak256(abi.encode(Condition[] buyerConditions))
        uint256 nonce;
    }

    struct Fill {
        address collection;
        uint256 soldId;
        address currency;
        uint256 maxPayment;
    }

    mapping(address => uint256) public nonces;
    mapping(address => mapping(uint256 => bool)) public usedSalt;
    /// @notice ETH a payee refused at a fill; `claim` pays it out.
    mapping(address => uint256) public owed;

    bytes32 private constant _LOCK = keccak256("erc6551p.market.lock");
    bytes32 private constant _FILLING = keccak256("erc6551p.market.filling");

    event Sold(
        address indexed collection,
        uint256 indexed id,
        address indexed seller,
        address buyer,
        address currency,
        uint256 price,
        uint256 royalty
    );
    event CheckedFill(address indexed collection, uint256 indexed id, address indexed buyer, bytes32 orderHashOrZero);
    event SaltCancelled(address indexed signer, uint256 salt);
    event NonceIncremented(address indexed signer, uint256 nonce);
    event Owed(address indexed payee, uint256 amount);

    error Reentered();
    error NotThisMarket();
    error Expired();
    error BadNonce();
    error SaltUsed();
    error BadSignature();
    error BadPromise();
    error NotSeller();
    error StaleListing();
    error SellerIsAccount();
    error WrongPayment();
    error WrongId();
    error NotConsumed();
    error NotDelivered();
    error BadOrder();
    error EthOnlyFromSeaport();
    error ClaimFailed();
    error NothingOwed();

    constructor(ISeaport16 seaport, address accountImpl) EIP712("ERC6551PMarket", "1") {
        SEAPORT = seaport;
        ACCOUNT_IMPL = accountImpl;
    }

    modifier locked() {
        bytes32 s = _LOCK;
        bool busy;
        assembly ("memory-safe") {
            busy := tload(s)
        }
        if (busy) revert Reentered();
        assembly ("memory-safe") {
            tstore(s, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(s, 0)
        }
    }

    /// @notice ETH only from Seaport during a `checkedFill` (its change).
    receive() external payable {
        bytes32 s = _FILLING;
        bool filling;
        assembly ("memory-safe") {
            filling := tload(s)
        }
        if (!filling || msg.sender != address(SEAPORT)) revert EthOnlyFromSeaport();
    }

    // ---------------------------------------------------------------- our listings
    /// @notice Buys a listing: the payment, a ticket, the transfer to `recipient`, then the sellerPromise and the buyer's
    ///         conditions on the account, then the seller and the royalty receiver are paid.
    function buy(
        Listing calldata l,
        bytes calldata sig,
        Condition[] calldata sellerPromise,
        Condition[] calldata buyerConditions,
        address recipient
    ) external payable locked {
        _checkListing(l, sig, sellerPromise, buyerConditions);
        usedSalt[l.seller][l.salt] = true;
        // the payment, held by the market until the post-check passed
        if (l.currency == address(0)) {
            if (msg.value != l.price) revert WrongPayment();
        } else {
            if (msg.value != 0) revert WrongPayment();
            _pull(l.currency, msg.sender, l.price);
        }
        _ticketTransfer(ITransferSafeCollection(l.collection), l.id, l.seller, recipient);
        _postCheck(l.collection, l.id, recipient, sellerPromise, buyerConditions);
        _settleListing(l, recipient);
    }

    function _settleListing(Listing calldata l, address recipient) private {
        uint256 royalty = _pay(l.collection, l.id, l.seller, l.currency, l.price, l.maxRoyalty);
        emit Sold(l.collection, l.id, l.seller, recipient, l.currency, l.price, royalty);
    }

    function _checkListing(
        Listing calldata l,
        bytes calldata sig,
        Condition[] calldata sellerPromise,
        Condition[] calldata buyerConditions
    ) private view {
        ITransferSafeCollection c = ITransferSafeCollection(l.collection);
        if (c.MARKET() != address(this)) revert NotThisMarket();
        if (block.timestamp > l.expiry) revert Expired();
        if (l.nonce != nonces[l.seller]) revert BadNonce();
        if (usedSalt[l.seller][l.salt]) revert SaltUsed();
        if (keccak256(abi.encode(sellerPromise)) != l.promiseHash) revert BadPromise();
        if (buyerConditions.length == 0) revert Conditions.NoBuyerConditions();
        if (c.ownerOf(l.id) != l.seller) revert NotSeller();
        if (c.transferCount(l.id) != l.transferCount) revert StaleListing();
        if (Conditions.isERC6551Account(l.seller)) revert SellerIsAccount();
        if (!SignatureChecker.isValidSignatureNow(l.seller, _hashListing(l), sig)) revert BadSignature();
    }

    // ---------------------------------------------------------------- our offers
    /// @notice The owner of `id` accepts an offer: a ticket, the transfer to the buyer, the buyer's conditions (and
    ///         the seller's sellerPromise) on the account, then the price from the buyer, the seller paid last.
    function accept(
        Offer calldata o,
        bytes calldata sig,
        uint256 id,
        Condition[] calldata buyerConditions,
        Condition[] calldata sellerPromise
    ) external locked {
        _checkOffer(o, sig, id, buyerConditions);
        usedSalt[o.buyer][o.salt] = true;
        _ticketTransfer(ITransferSafeCollection(o.collection), id, msg.sender, o.buyer);
        _postCheck(o.collection, id, o.buyer, sellerPromise, buyerConditions);
        _pull(o.currency, o.buyer, o.price);
        _settleOffer(o, id);
    }

    function _settleOffer(Offer calldata o, uint256 id) private {
        uint256 royalty = _pay(o.collection, id, msg.sender, o.currency, o.price, o.maxRoyalty);
        emit Sold(o.collection, id, msg.sender, o.buyer, o.currency, o.price, royalty);
    }

    function _checkOffer(Offer calldata o, bytes calldata sig, uint256 id, Condition[] calldata buyerConditions)
        private
        view
    {
        ITransferSafeCollection c = ITransferSafeCollection(o.collection);
        if (c.MARKET() != address(this)) revert NotThisMarket();
        if (block.timestamp > o.expiry) revert Expired();
        if (o.nonce != nonces[o.buyer]) revert BadNonce();
        if (usedSalt[o.buyer][o.salt]) revert SaltUsed();
        if (keccak256(abi.encode(buyerConditions)) != o.conditionsHash) revert BadPromise();
        if (buyerConditions.length == 0) revert Conditions.NoBuyerConditions();
        if (!o.anyId && id != o.id) revert WrongId();
        if (o.currency == address(0)) revert WrongPayment();
        if (c.ownerOf(id) != msg.sender) revert NotSeller();
        if (Conditions.isERC6551Account(msg.sender)) revert SellerIsAccount();
        if (!SignatureChecker.isValidSignatureNow(o.buyer, _hashOffer(o), sig)) revert BadSignature();
    }

    /// @dev After the transfer: the account the market computes, owned by `recipient`; the promise and the buyer's
    ///      conditions hold on it; the ticket is closed.
    function _postCheck(
        address collection,
        uint256 id,
        address recipient,
        Condition[] calldata sellerPromise,
        Condition[] calldata buyerConditions
    ) private {
        Conditions.checkAll(sellerPromise, buyerConditions, _account(collection, id, recipient), collection, id);
        ITransferSafeCollection(collection).closeTicket(id);
    }

    function cancel(uint256 salt) external {
        usedSalt[msg.sender][salt] = true;
        emit SaltCancelled(msg.sender, salt);
    }

    function incrementNonce() external {
        emit NonceIncremented(msg.sender, ++nonces[msg.sender]);
    }

    /// @notice Pays `owed[who]` to `who`, with all the gas. Any caller: a payee with no way to call this still gets paid.
    function claim(address who) external locked {
        uint256 v = owed[who];
        if (v == 0) revert NothingOwed();
        owed[who] = 0;
        (bool ok,) = who.call{value: v}("");
        if (!ok) revert ClaimFailed();
    }

    // ---------------------------------------------------------------- checked fill of any Seaport listing
    /// @notice Fills a Seaport 1.6 listing of ONE NFT (a plain listing needs the token ready; a zone listing gets
    ///         its ticket from the zone) (`f.soldId` of `f.collection`, amount 1, order type 0–3, no
    ///         criteria) with the market as Seaport's fulfiller and recipient, sends the NFT to the caller, then checks
    ///         the buyer's conditions on the account and returns the change (ETH or the ERC-20 balance delta). The
    ///         consideration is in ONE currency `f.currency` (address(0) = ETH) and pays nothing into the account. A
    ///         restricted order of our zone carries the buyer's conditions in `order.extraData` too.
    function checkedFill(
        AdvancedOrder calldata order,
        CriteriaResolver[] calldata resolvers,
        bytes32 fulfillerConduitKey,
        Fill calldata f,
        Condition[] calldata buyerConditions
    ) external payable locked {
        if (buyerConditions.length == 0) revert Conditions.NoBuyerConditions();
        if (ITransferSafeCollection(f.collection).MARKET() != address(this)) revert NotThisMarket();
        address a = Conditions.accountOf(ACCOUNT_IMPL, f.collection, f.soldId);
        _checkOrder(order.parameters, resolvers.length, f, a);
        uint256 before;
        address spender;
        if (f.currency == address(0)) {
            if (f.maxPayment != msg.value) revert WrongPayment();
            before = address(this).balance - msg.value;
        } else {
            if (msg.value != 0) revert WrongPayment();
            before = IERC20(f.currency).balanceOf(address(this));
            _pull(f.currency, msg.sender, f.maxPayment);
            spender = _conduit(fulfillerConduitKey);
            IERC20(f.currency).forceApprove(spender, f.maxPayment);
        }
        // no ticket of the market's own: a plain listing passes the collection's rule only while the token is ready
        // (from an earlier transaction). A transfer or an account batch only PAUSES a plain listing: it binds no state,
        // so the same owner's next `readyToSell` makes it valid again at its old price, until the seller cancels it on
        // Seaport (a market ticket would revive it with no `readyToSell`). A restricted order of the collection's zone
        // gets its ticket from the zone
        _setFilling(true);
        SEAPORT.fulfillAdvancedOrder{value: msg.value}(order, resolvers, fulfillerConduitKey, address(this));
        _setFilling(false);
        if (IERC721(f.collection).ownerOf(f.soldId) != address(this)) revert NotDelivered();
        IERC721(f.collection).transferFrom(address(this), msg.sender, f.soldId);
        Conditions.checkAccount(a, f.collection, f.soldId, msg.sender);
        Conditions.checkAll(new Condition[](0), buyerConditions, a, f.collection, f.soldId);
        // the change
        if (f.currency == address(0)) {
            uint256 change = address(this).balance - before;
            if (change != 0) {
                (bool ok,) = msg.sender.call{value: change}("");
                if (!ok) revert WrongPayment();
            }
        } else {
            IERC20(f.currency).forceApprove(spender, 0);
            uint256 change = IERC20(f.currency).balanceOf(address(this)) - before;
            if (change != 0) IERC20(f.currency).safeTransfer(msg.sender, change);
        }
        emit CheckedFill(f.collection, f.soldId, msg.sender, bytes32(0));
    }

    /// @dev One offer item (the NFT, amount 1), types 0–3, no criteria, one currency, nothing to the account.
    function _checkOrder(OrderParameters calldata p, uint256 nResolvers, Fill calldata f, address a) private view {
        if (nResolvers != 0 || uint8(p.orderType) > uint8(OrderType.PARTIAL_RESTRICTED)) revert BadOrder();
        if (p.offer.length != 1) revert BadOrder();
        if (
            p.offer[0].itemType != ItemType.ERC721 || p.offer[0].token != f.collection
                || p.offer[0].identifierOrCriteria != f.soldId || p.offer[0].startAmount != 1 || p.offer[0].endAmount != 1
        ) revert BadOrder();
        if (Conditions.isERC6551Account(p.offerer)) revert SellerIsAccount();
        if (p.offerer == address(this)) revert BadOrder(); // Seaport skips the signature of its caller
        ItemType want = f.currency == address(0) ? ItemType.NATIVE : ItemType.ERC20;
        for (uint256 i; i < p.consideration.length; i++) {
            if (
                p.consideration[i].itemType != want || p.consideration[i].token != f.currency
                    || p.consideration[i].recipient == a
            ) revert BadOrder();
        }
    }

    // ---------------------------------------------------------------- internals
    /// @dev Opens the ticket, moves the token (the market is approved by the seller), checks the ticket was used.
    function _ticketTransfer(ITransferSafeCollection c, uint256 id, address from, address to) private {
        c.openTicket(id, from, to);
        IERC721(address(c)).transferFrom(from, to, id);
        if (!c.ticketConsumed(id)) revert NotConsumed();
        if (c.ownerOf(id) != to) revert NotDelivered();
    }

    /// @dev The account the market computes; it must be the token's clone, owned by `recipient`.
    function _account(address collection, uint256 id, address recipient) private view returns (address a) {
        a = Conditions.accountOf(ACCOUNT_IMPL, collection, id);
        Conditions.checkAccount(a, collection, id, recipient);
    }

    /// @dev Pays `price`, which the market holds: the royalty = min(ERC-2981, maxRoyalty, price) to the
    ///      receiver, the rest to the seller. ETH a payee refuses goes to `owed`.
    function _pay(
        address collection,
        uint256 id,
        address seller,
        address currency,
        uint256 price,
        uint256 maxRoyalty
    ) private returns (uint256 royalty) {
        address receiver;
        (receiver, royalty) = _royalty(collection, id, price);
        if (royalty > maxRoyalty) royalty = maxRoyalty;
        if (royalty > price) royalty = price;
        if (receiver == address(0)) royalty = 0;
        if (royalty != 0) _send(currency, receiver, royalty);
        _send(currency, seller, price - royalty);
    }

    /// @dev ERC-2981 `royaltyInfo`, read with a gas cap; no valid answer = no royalty.
    function _royalty(address collection, uint256 id, uint256 price) private view returns (address, uint256) {
        bytes memory cd = abi.encodeWithSelector(0x2a55205a, id, price);
        bool ok;
        uint256 r;
        uint256 v;
        assembly ("memory-safe") {
            ok := staticcall(50000, collection, add(cd, 32), mload(cd), 0, 0)
            if and(ok, eq(returndatasize(), 64)) {
                let q := mload(0x40)
                returndatacopy(q, 0, 64)
                r := mload(q)
                v := mload(add(q, 32))
            }
        }
        if (!ok || r >> 160 != 0) return (address(0), 0);
        return (address(uint160(r)), v);
    }

    function _send(address currency, address to, uint256 v) private {
        if (v == 0) return;
        if (currency == address(0)) {
            (bool ok,) = to.call{value: v, gas: 50_000}("");
            if (!ok) {
                owed[to] += v;
                emit Owed(to, v);
            }
        } else {
            IERC20(currency).safeTransfer(to, v);
        }
    }

    /// @dev Pulls exactly `v` (a balance delta: a fee-on-transfer token reverts).
    function _pull(address currency, address from, uint256 v) private {
        uint256 b0 = IERC20(currency).balanceOf(address(this));
        IERC20(currency).safeTransferFrom(from, address(this), v);
        if (IERC20(currency).balanceOf(address(this)) - b0 != v) revert WrongPayment();
    }

    function _conduit(bytes32 key) private view returns (address) {
        if (key == bytes32(0)) return address(SEAPORT);
        (,, address controller) = SEAPORT.information();
        (address conduit, bool exists) = IConduitController(controller).getConduit(key);
        if (!exists) revert BadOrder();
        return conduit;
    }

    function _setFilling(bool on) private {
        bytes32 s = _FILLING;
        assembly ("memory-safe") {
            tstore(s, on)
        }
    }

    function _hashListing(Listing calldata l) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LISTING_TYPEHASH,
                    l.collection,
                    l.id,
                    l.transferCount,
                    l.seller,
                    l.currency,
                    l.price,
                    l.maxRoyalty,
                    l.expiry,
                    l.salt,
                    l.promiseHash,
                    l.nonce
                )
            )
        );
    }

    function _hashOffer(Offer calldata o) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OFFER_TYPEHASH,
                    o.collection,
                    o.id,
                    o.anyId,
                    o.buyer,
                    o.currency,
                    o.price,
                    o.maxRoyalty,
                    o.expiry,
                    o.salt,
                    o.conditionsHash,
                    o.nonce
                )
            )
        );
    }

    /// @notice The EIP-712 digests a front end signs.
    function listingDigest(Listing calldata l) external view returns (bytes32) {
        return _hashListing(l);
    }

    function offerDigest(Offer calldata o) external view returns (bytes32) {
        return _hashOffer(o);
    }
}
