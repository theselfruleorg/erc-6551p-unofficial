// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC6551PBase, IAccount} from "./ERC6551PBase.sol";
import {ERC6551PCollection} from "../src/kit/ERC6551PCollection.sol";
import {AccountedERC721} from "../src/kit/AccountedERC721.sol";
import {IERC6551PCollection} from "../src/interfaces/IERC6551P.sol";
import {ITransferSafeAccount} from "../src/interfaces/ITransferSafe.sol";
import {ERC6551PMarket} from "../src/sale/ERC6551PMarket.sol";
import {Condition, Conditions} from "../src/sale/Conditions.sol";
import {ExampleERC6551PCollection} from "../examples/ExampleERC6551PCollection.sol";

/// @notice ERC-6551P against a collection that is the example (examples/ExampleERC6551PCollection.sol): the shared
///         account implementation, the shared market and zone, and the kit's collection rule. It also pins the ERC-165
///         ids the proposal (docs/erc-6551p.md) states. Tests marked `isolate` run each top-level call as
///         its own transaction (transient storage is cleared between them, as on chain).
contract ERC6551PExampleTest is ERC6551PBase {
    /// @dev The ids the proposal states; computed by the compiler from src/interfaces/ (never by hand).
    bytes4 constant IID_COLLECTION = 0x6b7481e3;
    bytes4 constant IID_ACCOUNT = 0x92ad233c;

    ExampleERC6551PCollection ex;
    address op = makeAddr("operator");
    address seller;
    uint256 sellerKey;
    address buyer = makeAddr("buyer");
    uint256 id;
    address a;

    function setUp() public {
        vm.chainId(31337);
        _etchCanonical();
        _deploy(); // the shared account implementation, market and zone
        ex = new ExampleERC6551PCollection(address(accountImpl), address(market), address(zone));
        (seller, sellerKey) = makeAddrAndKey("seller");
        (id, a) = ex.mint(seller);
        vm.deal(a, 2 ether);
        vm.deal(buyer, 10 ether);
        vm.startPrank(seller);
        ex.setApprovalForAll(op, true);
        ex.setApprovalForAll(address(market), true);
        vm.stopPrank();
    }

    function _ready() internal {
        vm.prank(seller);
        IAccount(a).execute(address(ex), 0, abi.encodeCall(ERC6551PCollection.readyToSell, (id)), 0);
    }

    function _eth(uint256 min) internal pure returns (Condition[] memory l) {
        l = new Condition[](1);
        l[0] = Condition(Conditions.ETH, address(0), 0, min, "");
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

    function _buy(ERC6551PMarket.Listing memory l, bytes memory sig, Condition[] memory buyerConditions) internal {
        vm.prank(buyer);
        market.buy{value: l.price}(l, sig, new Condition[](0), buyerConditions, buyer);
    }

    // ---------------------------------------------------------------- identity
    function test_interfaceIds() public view {
        assertEq(type(IERC6551PCollection).interfaceId, IID_COLLECTION);
        assertEq(type(ITransferSafeAccount).interfaceId, IID_ACCOUNT);
        assertTrue(ex.supportsInterface(IID_COLLECTION));
        assertTrue(ex.supportsInterface(0xf5112315)); // ERC-5646
        assertTrue(ex.supportsInterface(0x49064906)); // ERC-4906
        assertTrue(ex.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(accountImpl.supportsInterface(IID_ACCOUNT));
        assertFalse(accountImpl.supportsInterface(0x1626ba7e)); // no ERC-1271
    }

    function test_mintCreatesTheAccount() public view {
        assertEq(a, ex.accountOf(id));
        assertEq(a.code.length, 173);
        (uint256 chainId, address tc, uint256 tid) = IAccount(a).token();
        assertEq(chainId, 31337);
        assertEq(tc, address(ex));
        assertEq(tid, id);
        assertEq(IAccount(a).owner(), seller);
        assertEq(ex.transferCount(id), 0); // the example mints straight to the owner (no hop)
    }

    // ---------------------------------------------------------------- the collection rule
    function test_operatorTransferNeedsReadiness() public {
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, buyer, id);
    }

    function test_readyInTheSameTransactionDoesNotCount() public {
        _ready();
        assertTrue(ex.saleReadyOf(id));
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, buyer, id);
    }

    /// forge-config: default.isolate = true
    function test_readyFromAnEarlierTransactionPasses() public {
        _ready();
        vm.prank(op);
        ex.transferFrom(seller, buyer, id);
        assertEq(IAccount(a).owner(), buyer);
        assertFalse(ex.saleReadyOf(id));
        assertEq(ex.transferCount(id), 1);
    }

    /// forge-config: default.isolate = true
    function test_anyAccountBatchEndsReadiness() public {
        _ready();
        vm.prank(seller);
        IAccount(a).execute(seller, 1 ether, "", 0);
        assertFalse(ex.saleReadyOf(id));
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, buyer, id);
    }

    function test_ownerTransferIsNotASale() public {
        vm.prank(seller);
        ex.transferFrom(seller, buyer, id);
        assertEq(IAccount(a).owner(), buyer);
    }

    function test_noSaleInsideTheAccountsOwnBatch() public {
        vm.prank(seller);
        ex.setApprovalForAll(a, true);
        vm.prank(seller);
        vm.expectRevert(); // the account's leg: AccountInBatch, bubbled by the account
        IAccount(a).execute(address(ex), 0, abi.encodeCall(ex.transferFrom, (seller, buyer, id)), 0);
        assertEq(ex.ownerOf(id), seller);
    }

    function test_noTokenIntoAnAccountOfTheCollection() public {
        (uint256 id2, address a2) = ex.mint(seller);
        vm.prank(seller);
        vm.expectRevert(AccountedERC721.OwnershipCycle.selector);
        ex.transferFrom(seller, a2, id);
        assertEq(ex.ownerOf(id2), seller);
    }

    function test_onlyTheMarketOrTheZoneOpensATicket() public {
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.NotTicketOpener.selector);
        ex.openTicket(id, seller, op);
    }

    // ---------------------------------------------------------------- the checked sale on a second collection
    function test_marketBuyChecksTheBuyersConditions() public {
        uint256 sb = seller.balance;
        ERC6551PMarket.Listing memory l = _listing();
        _buy(l, _sig(l), _eth(2 ether));
        assertEq(ex.ownerOf(id), buyer);
        assertEq(IAccount(a).owner(), buyer);
        assertEq(a.balance, 2 ether);
        assertEq(seller.balance - sb, 1 ether); // no ERC-2981 on the example: no royalty
        assertEq(address(market).balance, 0);
    }

    function test_drainBeforeTheFillReverts() public {
        ERC6551PMarket.Listing memory l = _listing();
        bytes memory sig = _sig(l);
        vm.prank(seller);
        IAccount(a).execute(seller, 1 ether, "", 0);
        vm.expectRevert(abi.encodeWithSelector(Conditions.ConditionFailed.selector, 0));
        _buy(l, sig, _eth(2 ether));
        assertEq(ex.ownerOf(id), seller);
    }

    function test_listingDiesWhenTheTokenMoves() public {
        ERC6551PMarket.Listing memory l = _listing();
        bytes memory sig = _sig(l);
        vm.prank(seller);
        ex.transferFrom(seller, op, id);
        vm.prank(op);
        ex.transferFrom(op, seller, id);
        vm.expectRevert(ERC6551PMarket.StaleListing.selector);
        _buy(l, sig, _eth(1));
    }
}
