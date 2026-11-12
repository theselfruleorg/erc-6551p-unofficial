// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC6551PBase, IAccount} from "./ERC6551PBase.sol";
import {ERC6551PCollection} from "../src/kit/ERC6551PCollection.sol";
import {AccountedERC721} from "../src/kit/AccountedERC721.sol";
import {IERC6551Registry} from "../src/interfaces/IERC6551Registry.sol";
import {ERC6551PAccount} from "../src/account/ERC6551PAccount.sol";
import {ERC6551PMarket} from "../src/sale/ERC6551PMarket.sol";
import {Condition, Conditions} from "../src/sale/Conditions.sol";
import {ExampleERC6551PCollection} from "../examples/ExampleERC6551PCollection.sol";
import {Sink} from "./mocks/CornerMocks.sol";

/// @notice A "market" for one test collection: opens a ticket inside a call that reverts and is caught, then tries the
///         transfer the ticket would have allowed (K-72).
contract RevertingOpener {
    ExampleERC6551PCollection public c;

    function setCollection(ExampleERC6551PCollection c_) external {
        c = c_;
    }

    function openThenRevert(uint256 id, address from, address to) external {
        c.openTicket(id, from, to);
        revert("branch reverts");
    }

    /// @dev The caught branch rolls the ticket back (EIP-1153 writes revert with their frame): the transfer fails, and
    ///      the slot is free for a new ticket.
    function run(uint256 id, address from, address to) external {
        try this.openThenRevert(id, from, to) {} catch {}
        try c.transferFrom(from, to, id) {
            revert("transfer passed");
        } catch (bytes memory err) {
            require(bytes4(err) == ERC6551PCollection.SaleNotReady.selector, "wrong error");
        }
        c.openTicket(id, from, to); // not TicketBusy
        c.transferFrom(from, to, id);
        require(c.ticketConsumed(id), "not consumed");
        c.closeTicket(id);
    }
}

/// @notice Corner cases of ERC-6551P on example collections (K-70…). Two example collections share the one account
///         implementation, market and zone. Tests marked `isolate` run each top-level call as its own transaction.
contract ERC6551PCornerTest is ERC6551PBase {
    ExampleERC6551PCollection ex;
    ExampleERC6551PCollection ex2;
    address op = makeAddr("operator");
    address seller;
    uint256 sellerKey;
    address buyer = makeAddr("buyer");
    uint256 id;
    address a;

    function setUp() public {
        vm.chainId(31337);
        _etchCanonical();
        _deploy();
        ex = new ExampleERC6551PCollection(address(accountImpl), address(market), address(zone));
        ex2 = new ExampleERC6551PCollection(address(accountImpl), address(market), address(zone));
        (seller, sellerKey) = makeAddrAndKey("seller");
        (id, a) = ex.mint(seller);
        ex2.mint(seller); // the same id 1 in the second collection
        vm.deal(a, 2 ether);
        vm.deal(buyer, 10 ether);
        vm.startPrank(seller);
        ex.setApprovalForAll(op, true);
        ex.setApprovalForAll(address(market), true);
        ex2.setApprovalForAll(op, true);
        vm.stopPrank();
    }

    function _ready() internal {
        vm.prank(seller);
        IAccount(a).execute(address(ex), 0, abi.encodeCall(ERC6551PCollection.readyToSell, (id)), 0);
    }

    function _one(uint8 kind, address target, uint256 cid, uint256 min, bytes memory data)
        internal
        pure
        returns (Condition[] memory l)
    {
        l = new Condition[](1);
        l[0] = Condition(kind, target, cid, min, data);
    }

    function _listing() internal view returns (ERC6551PMarket.Listing memory) {
        return ERC6551PMarket.Listing(
            address(ex),
            id,
            ex.transferCount(id),
            seller,
            address(0),
            1 ether,
            0,
            block.timestamp + 1 days,
            1,
            keccak256(abi.encode(new Condition[](0))),
            market.nonces(seller)
        );
    }

    function _sig(ERC6551PMarket.Listing memory l) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, market.listingDigest(l));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- two collections, one market
    /// K-70: a ticket lives in the transient storage of ONE collection; the same id of another collection that shares
    /// the market and the zone gets nothing from it.
    function test_K70_aTicketOfOneCollectionDoesNotReachAnother() public {
        assertEq(ex.MARKET(), ex2.MARKET());
        assertEq(ex2.ownerOf(id), seller);
        vm.prank(address(market));
        ex.openTicket(id, seller, buyer);
        assertFalse(ex2.ticketConsumed(id));
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex2.transferFrom(seller, buyer, id);
        // and the ticket of `ex` still serves its own transfer
        vm.prank(op);
        ex.transferFrom(seller, buyer, id);
        assertTrue(ex.ticketConsumed(id));
    }

    /// K-70: the market computes the account from (collection, id); the same id of the second collection has another
    /// account, so a buyer condition of one is never read on the other.
    function test_K70_sameIdTwoCollectionsTwoAccounts() public view {
        assertTrue(ex.accountOf(id) != ex2.accountOf(id));
        assertEq(Conditions.accountOf(address(accountImpl), address(ex2), id), ex2.accountOf(id));
    }

    /// K-71: a collection whose tokens' accounts are of ANOTHER implementation names our market: the market computes
    /// the account with its own implementation, finds no clone there, and refuses the fill (fail closed).
    function test_K71_aCollectionWithAnotherAccountImplCannotUseTheMarket() public {
        ERC6551PAccount other = new ERC6551PAccount(address(journal));
        ExampleERC6551PCollection ex3 = new ExampleERC6551PCollection(address(other), address(market), address(zone));
        (uint256 id3,) = ex3.mint(seller);
        vm.prank(seller);
        ex3.setApprovalForAll(address(market), true);
        ERC6551PMarket.Listing memory l = ERC6551PMarket.Listing(
            address(ex3),
            id3,
            0,
            seller,
            address(0),
            1 ether,
            0,
            block.timestamp + 1 days,
            7,
            keccak256(abi.encode(new Condition[](0))),
            market.nonces(seller)
        );
        bytes memory sig = _sig(l);
        vm.prank(buyer);
        vm.expectRevert(Conditions.BadAccount.selector);
        market.buy{value: 1 ether}(l, sig, new Condition[](0), _one(Conditions.ETH, address(0), 0, 0, ""), buyer);
        assertEq(ex3.ownerOf(id3), seller);
    }

    // ---------------------------------------------------------------- tickets and reverts
    /// K-72: a ticket opened in a branch that reverts is rolled back with it; nothing stays open for a later transfer.
    function test_K72_aTicketOpenedInARevertingBranchDoesNotStay() public {
        RevertingOpener m = new RevertingOpener();
        ExampleERC6551PCollection ex3 = new ExampleERC6551PCollection(address(accountImpl), address(m), address(zone));
        m.setCollection(ex3);
        (uint256 id3,) = ex3.mint(seller);
        vm.prank(seller);
        ex3.setApprovalForAll(address(m), true);
        m.run(id3, seller, buyer);
        assertEq(ex3.ownerOf(id3), buyer);
    }

    // ---------------------------------------------------------------- self transfers
    /// K-73: an operator's transfer from the owner to the owner is a non-owner transfer: it needs readiness, and it
    /// counts and ends readiness like any other.
    function test_K73_operatorSelfTransferNeedsReadiness() public {
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, seller, id);
    }

    /// forge-config: default.isolate = true
    function test_K73_operatorSelfTransferEndsReadinessAndCounts() public {
        _ready();
        vm.prank(op);
        ex.transferFrom(seller, seller, id);
        assertEq(ex.ownerOf(id), seller);
        assertFalse(ex.saleReadyOf(id));
        assertEq(ex.transferCount(id), 1);
    }

    /// K-73: the owner's own transfer to itself is not a sale, and still counts (a listing signed before it dies).
    function test_K73_ownerSelfTransferCounts() public {
        vm.prank(seller);
        ex.transferFrom(seller, seller, id);
        assertEq(ex.transferCount(id), 1);
    }

    // ---------------------------------------------------------------- views of ids with no owner
    /// K-74: the ERC-5646 fingerprint of an id that was never minted reverts (no state to commit to); readiness is
    /// false and `readyToSell` / `cancelReady` revert.
    function test_K74_unmintedIdHasNoFingerprintAndNoReadiness() public {
        uint256 none = 99;
        vm.expectRevert();
        ex.getStateFingerprint(none);
        assertFalse(ex.saleReadyOf(none));
        vm.expectRevert(ERC6551PCollection.NonexistentToken.selector);
        ex.readyToSell(none);
        vm.expectRevert(ERC6551PCollection.NonexistentToken.selector);
        ex.cancelReady(none);
    }

    /// K-74: the fingerprint changes on a transfer and on an account batch, and not on a deposit.
    function test_K74_fingerprintInputs() public {
        bytes32 f0 = ex.getStateFingerprint(id);
        vm.deal(a, 3 ether); // a deposit
        assertEq(ex.getStateFingerprint(id), f0);
        vm.prank(seller);
        IAccount(a).execute(seller, 1, "", 0);
        bytes32 f1 = ex.getStateFingerprint(id);
        assertTrue(f1 != f0);
        vm.prank(seller);
        ex.transferFrom(seller, seller, id);
        assertTrue(ex.getStateFingerprint(id) != f1);
    }

    // ---------------------------------------------------------------- relative condition kinds
    /// K-75: a collection with no `positionOf` / `hasIdentity` / `agentIdOf` (the example) makes the relative kinds
    /// MINT_POSITION and IDENTITY fail, so a buyer who adds them cannot buy (fail closed, never a false pass).
    function test_K75_relativeKindsFailClosedOnACollectionWithoutThem() public {
        assertFalse(Conditions.holds(Condition(Conditions.MINT_POSITION, POSITION_MANAGER, 0, 0, ""), a, address(ex), id));
        assertFalse(Conditions.holds(Condition(Conditions.IDENTITY, address(this), 0, 0, ""), a, address(ex), id));
        ERC6551PMarket.Listing memory l = _listing();
        bytes memory sig = _sig(l);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Conditions.ConditionFailed.selector, 0));
        market.buy{value: 1 ether}(
            l, sig, new Condition[](0), _one(Conditions.MINT_POSITION, POSITION_MANAGER, 0, 0, ""), buyer
        );
        assertEq(ex.ownerOf(id), seller);
    }

    /// K-75: an unknown kind fails.
    function test_K75_unknownKindFails() public view {
        assertFalse(Conditions.holds(Condition(12, address(0), 0, 0, ""), a, address(ex), id));
        assertFalse(Conditions.holds(Condition(255, address(0), 0, 0, ""), a, address(ex), id));
    }

    // ---------------------------------------------------------------- no nesting, any implementation
    /// K-76: a token may not move into a registry clone of ANY implementation and ANY salt bound to a token of the
    /// same collection (here: a clone of a plain contract, salt 7, for the second token).
    function test_K76_noTokenIntoACloneOfAnotherImplementation() public {
        (uint256 id2,) = ex.mint(seller);
        address impl = address(new Sink());
        address clone = IERC6551Registry(REGISTRY).createAccount(impl, bytes32(uint256(7)), block.chainid, address(ex), id2);
        assertEq(clone.code.length, 173);
        vm.prank(seller);
        vm.expectRevert(AccountedERC721.OwnershipCycle.selector);
        ex.transferFrom(seller, clone, id);
    }

    /// K-76: a clone bound to the SAME id on ANOTHER chain id is not this chain's account; the token may move there
    /// (that clone has no owner on this chain, so it is not a cycle).
    function test_K76_aCloneBoundToAnotherChainIsNotRefused() public {
        address impl = address(new Sink());
        address clone = IERC6551Registry(REGISTRY).createAccount(impl, 0, 1, address(ex), id);
        vm.prank(seller);
        ex.transferFrom(seller, clone, id);
        assertEq(ex.ownerOf(id), clone);
    }

    /// K-77: a token of the example owned by an account of ANOTHER collection (here a token account of `ex2`) cannot be
    /// made ready and cannot be sold by an operator (the seller is an ERC-6551 account).
    function test_K77_anOwnerThatIsAnAccountOfAnotherCollectionCannotSell() public {
        address a2 = ex2.accountOf(id);
        vm.prank(seller);
        ex.transferFrom(seller, a2, id);
        // the account of ex#1 now belongs to ex2#1's account; ex2#1's owner acts through two accounts
        bytes memory ready = abi.encodeCall(ERC6551PCollection.readyToSell, (id));
        bytes memory inner = abi.encodeCall(IAccount.execute, (address(ex), 0, ready, 0));
        vm.prank(seller);
        vm.expectRevert(); // SellerIsAccount, bubbled through both accounts
        IAccount(a2).execute(a, 0, inner, 0);
        vm.prank(a2);
        ex.setApprovalForAll(op, true);
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SellerIsAccount.selector);
        ex.transferFrom(a2, buyer, id);
    }

    // ---------------------------------------------------------------- a chain id change (a fork of the chain)
    /// K-78: after a chain fork with a new chain id, an account answers no owner (it is bound to the old chain id), so
    /// no one can make it call; `accountOf` points at the new chain's (empty) address, so every non-owner transfer
    /// reverts; a listing signed on the old chain fails its EIP-712 domain. The owner's own transfer still works.
    function test_K78_aChainIdChangeFreezesTheAccountAndKillsOldOrders() public {
        ERC6551PMarket.Listing memory l = _listing();
        bytes memory sig = _sig(l);
        vm.chainId(31338);
        assertEq(IAccount(a).owner(), address(0));
        vm.prank(seller);
        vm.expectRevert();
        IAccount(a).execute(seller, 1, "", 0);
        assertTrue(ex.accountOf(id) != a);
        vm.prank(op);
        vm.expectRevert();
        ex.transferFrom(seller, buyer, id);
        vm.prank(buyer);
        vm.expectRevert();
        market.buy{value: 1 ether}(l, sig, new Condition[](0), _one(Conditions.ETH, address(0), 0, 0, ""), buyer);
        vm.prank(seller);
        ex.transferFrom(seller, buyer, id);
        assertEq(ex.ownerOf(id), buyer);
    }

    // ---------------------------------------------------------------- the account and its own collection
    /// K-79: the account cannot receive its own token, and cannot receive another token of its collection either
    /// (the collection refuses the transfer first).
    function test_K79_theAccountHoldsNoTokenOfItsOwnCollection() public {
        (uint256 id2,) = ex.mint(seller);
        vm.prank(seller);
        vm.expectRevert(AccountedERC721.OwnershipCycle.selector);
        ex.transferFrom(seller, a, id2);
        vm.prank(seller);
        vm.expectRevert(AccountedERC721.OwnershipCycle.selector);
        ex.safeTransferFrom(seller, a, id);
        // a token of ANOTHER collection may live in the account (R-8)
        vm.prank(seller);
        ex2.transferFrom(seller, a, id);
        assertEq(ex2.ownerOf(id), a);
    }

    // ---------------------------------------------------------------- limits the final evaluation names (R-14, R-15)
    /// K-85 (R-14): anyone can create ANOTHER account for the same token (another salt or
    /// implementation). The NFT owner controls it, and its actions do not change the canonical account's `state()`, so
    /// readiness does not end. The two promises cover only the canonical account (salt 0, the collection's
    /// implementation); front ends show only that one.
    /// forge-config: default.isolate = true
    function test_K85_anotherAccountOfTheSameTokenIsOutsideThePromises() public {
        address other = IERC6551Registry(REGISTRY).createAccount(address(accountImpl), bytes32(uint256(1)), block.chainid, address(ex), id);
        assertTrue(other != a);
        vm.deal(other, 1 ether);
        _ready();
        vm.prank(seller);
        IAccount(other).execute(seller, 1 ether, "", 0); // the owner acts through the second account
        assertTrue(ex.saleReadyOf(id)); // the canonical account did not act
        vm.prank(op);
        ex.transferFrom(seller, buyer, id);
        assertEq(IAccount(other).owner(), buyer);
    }

    /// K-92 (R-16): an empty address has no code to read, so the no-nesting check cannot see a future clone of a token
    /// that already exists (any other salt or implementation). The sender can burn its own token this way: the
    /// clone then owns the token, and no address can act for it. Nobody else can force this.
    function test_K92_tokenSentToItsOwnEmptyCloneIsAnOwnerMadeBurn() public {
        vm.deal(a, 1 ether);
        bytes32 salt = bytes32(uint256(1));
        address clone = _erc6551Address(address(accountImpl), salt, block.chainid, address(ex), id);
        assertEq(clone.code.length, 0);
        vm.prank(seller);
        ex.transferFrom(seller, clone, id); // passes: nothing to read at that address yet
        IERC6551Registry(REGISTRY).createAccount(address(accountImpl), salt, block.chainid, address(ex), id);
        assertEq(IAccount(clone).owner(), clone);
        assertEq(IAccount(a).owner(), clone);
        vm.prank(seller);
        vm.expectRevert();
        IAccount(a).execute(seller, 1 ether, "", 0);
        assertEq(a.balance, 1 ether);
    }

    /// K-86 (R-15): a cycle through ANOTHER collection is possible with two owner transfers: a token
    /// of `ex2` into the account of `ex`#1, then `ex`#1 into the account of `ex2`#1. Neither account can act again (each
    /// one's owner is the other); only the owner who made it loses. The collection closes cycles inside itself only.
    function test_K86_aCycleThroughAnotherCollectionIsAnOwnerMadeBurn() public {
        address a2 = ex2.accountOf(id);
        vm.prank(seller);
        ex2.transferFrom(seller, a, id); // ex2#1 into ex#1's account
        vm.prank(seller);
        ex.transferFrom(seller, a2, id); // ex#1 into ex2#1's account
        assertEq(IAccount(a).owner(), a2);
        assertEq(IAccount(a2).owner(), a);
        vm.prank(seller);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(a).execute(seller, 1, "", 0);
        vm.prank(seller);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(a2).execute(seller, 0, "", 0);
    }
}
