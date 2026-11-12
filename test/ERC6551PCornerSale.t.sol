// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC6551PBase, IAccount} from "./ERC6551PBase.sol";
import {ERC6551PCollection} from "../src/kit/ERC6551PCollection.sol";
import {ERC6551PAccount} from "../src/account/ERC6551PAccount.sol";
import {ERC6551PMarket} from "../src/sale/ERC6551PMarket.sol";
import {ERC6551PZone} from "../src/sale/ERC6551PZone.sol";
import {Condition, Conditions} from "../src/sale/Conditions.sol";
import {ExampleERC6551PCollection} from "../examples/ExampleERC6551PCollection.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    OrderParameters,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType,
    ZoneParameters,
    SpentItem,
    ReceivedItem
} from "../src/interfaces/ISeaport16.sol";
import {ISeaport16} from "../src/interfaces/ISeaport16.sol";
import {MockSeaport} from "./mocks/MockSeaport.sol";

/// @dev A seller whose `receive` costs more than the market's 50,000 gas push, and with no function that calls the market.
contract CostlyPayee {
    address immutable signer;
    uint256[4] public slots;

    constructor(address s) {
        signer = s;
    }

    function isValidSignature(bytes32 h, bytes calldata sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(sig, (uint8, bytes32, bytes32));
        return ecrecover(h, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0);
    }

    function approveAll(address nft, address op) external {
        (bool ok,) = nft.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", op, true));
        require(ok);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {
        for (uint256 i = 0; i < 4; i++) slots[i] += 1;
    }
}

/// @dev A seller wallet (ERC-1271 by an EOA key) whose `receive` tries to enter the market again while the market pays
///      it (A-21); it records the revert selector and keeps the ETH.
contract ReenteringSeller {
    address immutable signer;
    ERC6551PMarket immutable market;
    bytes4 public seen;

    constructor(address s, ERC6551PMarket m) {
        signer = s;
        market = m;
    }

    function isValidSignature(bytes32 h, bytes calldata sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(sig, (uint8, bytes32, bytes32));
        return ecrecover(h, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0);
    }

    function approveAll(address nft, address op) external {
        (bool ok,) = nft.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", op, true));
        require(ok);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {
        try market.claim(address(this)) {} catch (bytes memory err) {
            seen = bytes4(err);
        }
    }
}

/// @dev Code that an EOA delegates to with EIP-7702 (K-23): it can call the account like a contract owner.
contract Delegate7702 {
    function exec(address a, address to, uint256 v, bytes calldata d) external {
        (bool ok,) = a.call(abi.encodeWithSelector(0x51945447, to, v, d, uint8(0)));
        require(ok, "exec");
    }
}

/// @notice The checked sale on the example collection, with the Seaport stand-in at the Seaport
///         address (the real Seaport 1.6 runs in test/gate/ on a 4663 fork): the plain path, `checkedFill`, the zone,
///         the ticket bindings, the market lock, the seller's gas and an EIP-7702 owner: the cases K-80…K-87, and the
///         cases that a review found without a test on a second collection.
contract ERC6551PCornerSaleTest is ERC6551PBase {
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
        vm.etch(SEAPORT, address(new MockSeaport()).code);
        _deploy();
        ex = new ExampleERC6551PCollection(address(accountImpl), address(market), address(zone));
        (seller, sellerKey) = makeAddrAndKey("seller");
        (id, a) = ex.mint(seller);
        vm.deal(a, 2 ether);
        vm.deal(buyer, 10 ether);
        vm.startPrank(seller);
        ex.setApprovalForAll(op, true);
        ex.setApprovalForAll(address(market), true);
        ex.setApprovalForAll(SEAPORT, true);
        vm.stopPrank();
    }

    function _ready() internal {
        vm.prank(seller);
        IAccount(a).execute(address(ex), 0, abi.encodeCall(ERC6551PCollection.readyToSell, (id)), 0);
    }

    function _drain(uint256 v) internal {
        vm.prank(seller);
        IAccount(a).execute(seller, v, "", 0);
    }

    function _eth(uint256 min) internal pure returns (Condition[] memory l) {
        l = new Condition[](1);
        l[0] = Condition(Conditions.ETH, address(0), 0, min, "");
    }

    function _none() internal pure returns (Condition[] memory) {
        return new Condition[](0);
    }

    function _order(OrderType t, address zone_, bytes32 zoneHash, uint256 price, bytes memory extra)
        internal
        view
        returns (AdvancedOrder memory o)
    {
        OrderParameters memory p;
        p.offerer = seller;
        p.zone = zone_;
        p.offer = new OfferItem[](1);
        p.offer[0] = OfferItem(ItemType.ERC721, address(ex), id, 1, 1);
        p.consideration = new ConsiderationItem[](1);
        p.consideration[0] = ConsiderationItem(ItemType.NATIVE, address(0), 0, price, price, payable(seller));
        p.orderType = t;
        p.endTime = block.timestamp + 1 days;
        p.zoneHash = zoneHash;
        p.totalOriginalConsiderationItems = 1;
        o = AdvancedOrder(p, 1, 1, "", extra);
    }

    function _fill(uint256 maxPay) internal view returns (ERC6551PMarket.Fill memory) {
        return ERC6551PMarket.Fill(address(ex), id, address(0), maxPay);
    }

    function _zoneListing(Condition[] memory buyerC, address fulfiller) internal view returns (ZoneParameters memory z) {
        z.orderHash = keccak256("order");
        z.fulfiller = fulfiller;
        z.offerer = seller;
        z.offer = new SpentItem[](1);
        z.offer[0] = SpentItem(ItemType.ERC721, address(ex), id, 1);
        z.consideration = new ReceivedItem[](1);
        z.consideration[0] = ReceivedItem(ItemType.NATIVE, address(0), 0, 1 ether, payable(seller));
        z.extraData = abi.encode(_none(), buyerC);
        z.orderHashes = new bytes32[](0);
        z.zoneHash = keccak256(abi.encode(ex.transferCount(id), _none()));
    }

    // ---------------------------------------------------------------- the plain path (R-3) on the example
    /// K-30 / A-7 (R-3, stated as a test): the seller drains, makes the token ready again in an earlier transaction, and
    /// a PLAIN fill (an operator or a marketplace conduit moving the token) still passes: Promise 2 does not hold on the
    /// plain path. Promise 1 holds (the drain was the seller's own batch before the sale).
    /// forge-config: default.isolate = true
    function test_K30_plainFillAfterADrainAndANewReadyPasses() public {
        _ready();
        _drain(2 ether);
        assertFalse(ex.saleReadyOf(id));
        _ready();
        vm.prank(op);
        ex.transferFrom(seller, buyer, id);
        assertEq(ex.ownerOf(id), buyer);
        assertEq(a.balance, 0);
    }

    /// K-30, the checked answer: the same drain and new ready make a `checkedFill` of the plain listing revert.
    /// forge-config: default.isolate = true
    function test_K30_checkedFillAfterADrainAndANewReadyReverts() public {
        AdvancedOrder memory o = _order(OrderType.FULL_OPEN, address(0), 0, 1 ether, "");
        _ready();
        _drain(2 ether);
        _ready();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Conditions.ConditionFailed.selector, 0));
        market.checkedFill{value: 1 ether}(o, new CriteriaResolver[](0), 0, _fill(1 ether), _eth(2 ether));
        assertEq(ex.ownerOf(id), seller);
    }

    /// K-80: `checkedFill` of a plain listing on the example: not ready → `SaleNotReady`; ready → the fill passes, the
    /// buyer's condition is read on the account, the overpayment comes back, the market keeps nothing.
    /// forge-config: default.isolate = true
    function test_K80_checkedFillOnTheExample() public {
        AdvancedOrder memory o = _order(OrderType.FULL_OPEN, address(0), 0, 1 ether, "");
        vm.prank(buyer);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        market.checkedFill{value: 1 ether}(o, new CriteriaResolver[](0), 0, _fill(1 ether), _eth(2 ether));
        _ready();
        uint256 b0 = buyer.balance;
        vm.prank(buyer);
        market.checkedFill{value: 1.5 ether}(o, new CriteriaResolver[](0), 0, _fill(1.5 ether), _eth(2 ether));
        assertEq(ex.ownerOf(id), buyer);
        assertEq(IAccount(a).owner(), buyer);
        assertEq(b0 - buyer.balance, 1 ether);
        assertEq(address(market).balance, 0);
    }

    // ---------------------------------------------------------------- the zone on the example
    /// K-81: a zone listing of the example: `authorizeOrder` opens the ticket (offerer → fulfiller), the transfer uses
    /// it, `validateOrder` checks the buyer's conditions and closes it.
    function test_K81_zoneListingOnTheExample() public {
        ZoneParameters memory z = _zoneListing(_eth(2 ether), buyer);
        vm.prank(SEAPORT);
        assertEq(zone.authorizeOrder(z), bytes4(0x01e4d72a));
        vm.prank(SEAPORT);
        ex.transferFrom(seller, buyer, id);
        vm.prank(SEAPORT);
        assertEq(zone.validateOrder(z), bytes4(0x17b1f942));
        assertEq(ex.ownerOf(id), buyer);
    }

    /// K-81: the recipient must be the fulfiller; a drain between the opening and the transfer breaks the ticket.
    function test_K81_zoneTicketBindsTheRecipientAndTheState() public {
        ZoneParameters memory z = _zoneListing(_eth(1), buyer);
        vm.prank(SEAPORT);
        zone.authorizeOrder(z);
        vm.prank(SEAPORT);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, op, id); // not the fulfiller
        _drain(1 ether); // an account batch after the opening
        vm.prank(SEAPORT);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, buyer, id);
    }

    /// K-81: a zone listing with no buyer condition is refused (I-9).
    function test_K81_zoneListingNeedsBuyerConditions() public {
        ZoneParameters memory z = _zoneListing(_none(), buyer);
        vm.prank(SEAPORT);
        vm.expectRevert(Conditions.NoBuyerConditions.selector);
        zone.authorizeOrder(z);
    }

    // ---------------------------------------------------------------- ticket bindings on the example
    /// K-82: a market ticket of the example binds `from`, `to` and the account's state, and serves one transfer.
    function test_K82_ticketBindsFromToStateAndServesOnce() public {
        vm.prank(address(market));
        ex.openTicket(id, seller, buyer);
        vm.prank(address(market));
        vm.expectRevert(ERC6551PCollection.TicketBusy.selector);
        ex.openTicket(id, seller, op);
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, op, id); // another `to`
        vm.prank(op);
        ex.transferFrom(seller, buyer, id); // uses the ticket
        assertTrue(ex.ticketConsumed(id));
        vm.prank(buyer);
        ex.setApprovalForAll(op, true);
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(buyer, seller, id); // a used ticket serves no second transfer
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.NotTicketOpener.selector);
        ex.closeTicket(id); // only the opener closes it
        vm.prank(address(market));
        ex.closeTicket(id);
    }

    /// K-82: an account batch after the opening breaks the ticket (the state binding).
    function test_K82_aBatchAfterTheOpeningBreaksTheTicket() public {
        vm.prank(address(market));
        ex.openTicket(id, seller, buyer);
        _drain(1);
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, buyer, id);
        assertFalse(ex.ticketConsumed(id));
    }

    /// K-18 / K-19 / K-21 on the example: `readyToSell` must be the last leg; a deposit keeps readiness; a gift and a
    /// return end it.
    /// forge-config: default.isolate = true
    function test_K18_K19_K21_readinessRulesOnTheExample() public {
        IAccount.Operation[] memory ops = new IAccount.Operation[](2);
        ops[0] = IAccount.Operation(address(ex), 0, abi.encodeCall(ERC6551PCollection.readyToSell, (id)), 0);
        ops[1] = IAccount.Operation(seller, 1, "", 0);
        vm.prank(seller);
        vm.expectRevert(ERC6551PAccount.ReadyNotLast.selector);
        IAccount(a).executeBatch(ops);
        _ready();
        vm.deal(a, 5 ether); // a deposit
        assertTrue(ex.saleReadyOf(id));
        vm.prank(seller);
        ex.transferFrom(seller, op, id);
        vm.prank(op);
        ex.transferFrom(op, seller, id);
        assertFalse(ex.saleReadyOf(id));
        vm.prank(op);
        vm.expectRevert(ERC6551PCollection.SaleNotReady.selector);
        ex.transferFrom(seller, buyer, id);
    }

    // ---------------------------------------------------------------- the market lock (A-21)
    /// A-21: a seller contract that the market pays tries to enter the market again (`claim`) inside the payment; the
    /// market's lock refuses it (`Reentered`), and the sale completes.
    function test_A21_marketLockRefusesReentryDuringThePayment() public {
        ReenteringSeller w = new ReenteringSeller(seller, market);
        vm.prank(seller);
        ex.transferFrom(seller, address(w), id);
        w.approveAll(address(ex), address(market));
        ERC6551PMarket.Listing memory l = ERC6551PMarket.Listing(
            address(ex),
            id,
            ex.transferCount(id),
            address(w),
            address(0),
            1 ether,
            0,
            block.timestamp + 1 days,
            3,
            keccak256(abi.encode(_none())),
            market.nonces(address(w))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, market.listingDigest(l));
        vm.prank(buyer);
        market.buy{value: 1 ether}(l, abi.encode(v, r, s), _none(), _eth(2 ether), buyer);
        assertEq(ex.ownerOf(id), buyer);
        assertEq(w.seen(), ERC6551PMarket.Reentered.selector);
        assertEq(address(w).balance, 1 ether);
        assertEq(market.owed(address(w)), 0);
    }

    /// K-91: a payee with no way to call the market still gets its owed ETH: any caller pays it, with all the gas, once.
    function test_K91_anyCallerPaysTheOwedPayee() public {
        CostlyPayee w = new CostlyPayee(seller);
        vm.prank(seller);
        ex.transferFrom(seller, address(w), id);
        w.approveAll(address(ex), address(market));
        ERC6551PMarket.Listing memory l = ERC6551PMarket.Listing(
            address(ex),
            id,
            ex.transferCount(id),
            address(w),
            address(0),
            1 ether,
            0,
            block.timestamp + 1 days,
            4,
            keccak256(abi.encode(_none())),
            market.nonces(address(w))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, market.listingDigest(l));
        vm.prank(buyer);
        market.buy{value: 1 ether}(l, abi.encode(v, r, s), _none(), _eth(2 ether), buyer);
        assertEq(market.owed(address(w)), 1 ether);

        vm.prank(makeAddr("stranger"));
        market.claim(address(w));
        assertEq(address(w).balance, 1 ether);
        assertEq(market.owed(address(w)), 0);
        assertEq(address(market).balance, 0);

        vm.expectRevert(ERC6551PMarket.NothingOwed.selector);
        market.claim(address(w));
    }

    // ---------------------------------------------------------------- the seller sets the gas (CondGas)
    /// K-83 (gas griefing by the fulfiller): a caller who sends too little gas for a full-cap condition read gets a
    /// revert (`CondGas`), never a silent false or a skipped condition.
    function test_K83_tooLittleGasForAConditionReadReverts() public {
        Condition memory c = Condition(Conditions.ERC20, address(new MockSeaport()), 0, 0, "");
        vm.expectRevert(Conditions.CondGas.selector);
        this.holdsWithGas{gas: 40_000}(c);
        assertTrue(this.holdsWithGas{gas: 200_000}(Condition(Conditions.ETH, address(0), 0, 1, "")));
    }

    function holdsWithGas(Condition memory c) external view returns (bool) {
        return Conditions.holds(c, a, address(ex), id);
    }

    // ---------------------------------------------------------------- an EIP-7702 owner (K-23)
    /// K-23: an EOA with an EIP-7702 delegation owns the token: it acts through the account and sells normally (its
    /// code is 23 bytes, not a registry clone). If another NFT controls that delegate, it is R-10.
    /// forge-config: default.isolate = true
    function test_K23_anEip7702OwnerActsAndSells() public {
        (address eoa, uint256 eoaKey) = makeAddrAndKey("eoa7702");
        Delegate7702 d = new Delegate7702();
        vm.signAndAttachDelegation(address(d), eoaKey);
        assertEq(eoa.code.length, 23);
        vm.prank(seller);
        ex.transferFrom(seller, eoa, id);
        vm.prank(eoa);
        ex.setApprovalForAll(op, true);
        Delegate7702(eoa).exec(a, address(ex), 0, abi.encodeCall(ERC6551PCollection.readyToSell, (id)));
        assertTrue(ex.saleReadyOf(id));
        vm.prank(op);
        ex.transferFrom(eoa, buyer, id);
        assertEq(ex.ownerOf(id), buyer);
    }

    // ---------------------------------------------------------------- no admin surface (A-43, A-19)
    /// A-43 / I-12: the market, the zone and the account have exactly these functions (from the compiler artifacts):
    /// no owner, no setter, no upgrade. A new function fails this test. A-19: none of them is a Seaport order function,
    /// and the zone's runtime holds no Seaport fill, match, validate or cancel selector (it never calls Seaport).
    function test_A43_A19_theFunctionListsAreFixed() public view {
        _abiIs(
            "/out/ERC6551PMarket.sol/ERC6551PMarket.json",
            "ACCOUNT_IMPL();LISTING_TYPEHASH();OFFER_TYPEHASH();SEAPORT();accept;buy;cancel(uint256);checkedFill;claim(address);"
            "eip712Domain();incrementNonce();listingDigest;nonces(address);offerDigest;owed(address);usedSalt(address,uint256)"
        );
        _abiIs(
            "/out/ERC6551PZone.sol/ERC6551PZone.json",
            "ACCOUNT_IMPL();SEAPORT();authorizeOrder;getSeaportMetadata();supportsInterface(bytes4);validateOrder"
        );
        _abiIs(
            "/out/ERC6551PAccount.sol/ERC6551PAccount.json",
            "JOURNAL();MAX_TUPLES();READ_CAP();execute(address,uint256,bytes,uint8);executeBatch;inBatch();"
            "isValidSignature(bytes32,bytes);isValidSigner(address,bytes);onERC1155BatchReceived;onERC1155Received;"
            "onERC721Received(address,address,uint256,bytes);owner();state();supportsInterface(bytes4);token()"
        );
        bytes4[5] memory seaportCalls = [
            ISeaport16.fulfillAdvancedOrder.selector,
            ISeaport16.fulfillAvailableAdvancedOrders.selector,
            ISeaport16.matchAdvancedOrders.selector,
            ISeaport16.fulfillBasicOrder_efficient_6GL6yc.selector,
            bytes4(0x88147732) // validate(Order[])
        ];
        bytes memory code = address(zone).code;
        for (uint256 i; i + 4 < code.length; i++) {
            if (code[i] != 0x63) continue; // PUSH4
            bytes4 w = bytes4(
                (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                    | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]))
            );
            for (uint256 k; k < seaportCalls.length; k++) {
                assertTrue(w != seaportCalls[k], "the zone holds a Seaport call selector");
            }
        }
    }

    /// @dev `want` is `;`-separated. The artifact's function names (the part before "(" when `want` lists only a name) equal `want`, in order.
    function _abiIs(string memory artifact, string memory want) internal view {
        string memory art = vm.readFile(string.concat(vm.projectRoot(), artifact));
        string[] memory keys = vm.parseJsonKeys(art, ".methodIdentifiers");
        string[] memory w = vm.split(want, ";");
        assertEq(keys.length, w.length, artifact);
        for (uint256 i; i < keys.length; i++) {
            bool exact = vm.indexOf(w[i], "(") != type(uint256).max;
            string memory got = exact ? keys[i] : vm.split(keys[i], "(")[0];
            assertEq(got, w[i], artifact);
        }
    }
}
