// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20TemporaryApproval} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20TemporaryApproval.sol";
import {ERC6551PBase, IAccount} from "./ERC6551PBase.sol";
import {ERC6551PAccount} from "../src/account/ERC6551PAccount.sol";
import {JournalLog} from "../src/kit/JournalLog.sol";
import {IERC6551Registry} from "../src/interfaces/IERC6551Registry.sol";
import {
    TToken,
    Spender,
    TNft,
    T1155,
    T5006,
    TFake1155,
    T6909,
    TCas,
    T777,
    T404,
    TPermit2,
    TLiar,
    TGasBurner,
    CallbackTarget,
    OwnerWallet
} from "./mocks/AccountMocks.sol";
import {Bouncer, CallsBack, Sink, TSwitch, TShape, TUsdt, UsdtSpender, T1155As721, TLender} from "./mocks/CornerMocks.sol";

/// @dev An ERC-20 with ERC-7674 temporary approvals (OpenZeppelin's draft extension), K-88.
contract TTemp is ERC20TemporaryApproval {
    constructor() ERC20("Temp", "TMP") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }
}

/// @dev A DSToken-style ERC-20 (Maker): `approve(address)` sets the allowance to the maximum (K-89).
contract TDsToken {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address guy) external returns (bool) {
        allowance[msg.sender][guy] = type(uint256).max;
        return true;
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        return true;
    }
}

contract TempSpender {
    function pull(TTemp t, address from, uint256 v) external {
        t.transferFrom(from, address(this), v);
    }
}

/// @dev An ERC-721 with a self-DELEGATECALL multicall (the v4 PositionManager shape).
contract TNftMulti is TNft {
    function multicall(bytes[] calldata data) external returns (bytes[] memory r) {
        r = new bytes[](data.length);
        for (uint256 i; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            require(ok, "multicall");
            r[i] = ret;
        }
    }
}

/// @dev Records the account's inBatch() during a leg.
contract InBatchProbe {
    bool public seen;

    function probe() external {
        seen = IAccount(msg.sender).inBatch();
    }
}

/// @notice ERC6551PAccount alone (the K-* and A-* rows name the cases): a test collection owns the
///         account through the canonical registry bytes.
contract AccountTest is ERC6551PBase {
    TNft coll;
    address acct;
    ERC6551PAccount impl_;
    JournalLog log_;
    TToken tok;
    Spender spender;
    address S = makeAddr("S");

    function setUp() public {
        vm.chainId(31337);
        _etchCanonical();
        log_ = new JournalLog();
        impl_ = new ERC6551PAccount(address(log_));
        coll = new TNft();
        coll.mint(alice, 1);
        acct = IERC6551Registry(REGISTRY).createAccount(address(impl_), bytes32(0), block.chainid, address(coll), 1);
        tok = new TToken();
        tok.mint(acct, 1000);
        spender = new Spender();
        vm.deal(acct, 1 ether);
    }

    // ---------------------------------------------------------------- helpers
    function _exec(address to, bytes memory data) internal returns (bytes memory) {
        vm.prank(alice);
        return IAccount(acct).execute(to, 0, data, 0);
    }

    function _op(address to, bytes memory data) internal pure returns (IAccount.Operation memory) {
        return IAccount.Operation(to, 0, data, 0);
    }

    function _batch(IAccount.Operation[] memory ops) internal returns (bytes[] memory) {
        vm.prank(alice);
        return IAccount(acct).executeBatch(ops);
    }

    function _ops2(IAccount.Operation memory a, IAccount.Operation memory b)
        internal
        pure
        returns (IAccount.Operation[] memory o)
    {
        o = new IAccount.Operation[](2);
        o[0] = a;
        o[1] = b;
    }

    function _ops3(IAccount.Operation memory a, IAccount.Operation memory b, IAccount.Operation memory c)
        internal
        pure
        returns (IAccount.Operation[] memory o)
    {
        o = new IAccount.Operation[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _approve(address s, uint256 v) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("approve(address,uint256)", s, v);
    }

    function _wrap(bytes memory inner) internal pure returns (bytes memory) {
        bytes[] memory a = new bytes[](1);
        a[0] = inner;
        return abi.encodeWithSignature("multicall(bytes[])", a);
    }

    function _expectGrant(uint256 leg, address target, address who) internal {
        vm.expectRevert(abi.encodeWithSelector(ERC6551PAccount.StandingGrant.selector, leg, target, who));
    }

    function _expectRefused(address target, bytes4 sel) internal {
        vm.expectRevert(abi.encodeWithSelector(ERC6551PAccount.Refused.selector, target, sel));
    }

    // ---------------------------------------------------------------- identity, entry points (§7.1.1–2)
    function test_token_owner_supportsInterface() public view {
        (uint256 c, address tc, uint256 id) = IAccount(acct).token();
        assertEq(c, 31337);
        assertEq(tc, address(coll));
        assertEq(id, 1);
        assertEq(IAccount(acct).owner(), alice);
        assertEq(acct.code.length, 173);
        ERC6551PAccount a = ERC6551PAccount(payable(acct));
        assertTrue(a.supportsInterface(0x01ffc9a7));
        assertTrue(a.supportsInterface(0x6faff5f1));
        assertTrue(a.supportsInterface(0x51945447));
        assertTrue(a.supportsInterface(0x150b7a02));
        assertTrue(a.supportsInterface(0x4e2312e0));
        assertTrue(a.supportsInterface(0x92ad233c));
        assertFalse(a.supportsInterface(0x1626ba7e)); // not ERC-1271
        assertEq(a.JOURNAL(), address(log_));
    }

    function test_K44_ownerIsZeroWhileOwnerOfReverts() public {
        address unminted =
            IERC6551Registry(REGISTRY).createAccount(address(impl_), bytes32(0), block.chainid, address(coll), 99);
        assertEq(IAccount(unminted).owner(), address(0));
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(unminted).execute(alice, 0, "", 0);
    }

    function test_ownerOnChainOnly() public {
        vm.chainId(1);
        assertEq(IAccount(acct).owner(), address(0));
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(acct).execute(alice, 0, "", 0);
    }

    function test_I1_onlyTheOwnerCalls() public {
        vm.prank(bob);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(acct).execute(bob, 1, "", 0);
        vm.prank(alice);
        coll.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(acct).execute(alice, 1, "", 0);
        vm.prank(bob);
        IAccount(acct).execute(bob, 1, "", 0);
    }

    function test_I3_noSignatures(bytes32 h, bytes calldata sig, address who) public view {
        assertEq(IAccount(acct).isValidSignature(h, sig), bytes4(0xffffffff));
        assertEq(IAccount(acct).isValidSigner(who, sig), bytes4(0));
        assertEq(IAccount(acct).isValidSigner(alice, ""), bytes4(0));
    }

    function test_executeReturnsAbiEncodedBytes() public {
        vm.prank(alice);
        (bool ok, bytes memory raw) = acct.call(
            abi.encodeWithSelector(0x51945447, address(tok), 0, abi.encodeWithSignature("balanceOf(address)", acct), uint8(0))
        );
        assertTrue(ok);
        // [0x20][0x20][1000]: what a caller that decodes the AccountV3 shape reads
        assertEq(raw.length, 96);
        assertEq(abi.decode(raw, (bytes)), abi.encode(uint256(1000)));
        bytes[] memory r = _batch(_ops2(_op(address(tok), abi.encodeWithSignature("balanceOf(address)", acct)), _op(bob, "")));
        assertEq(abi.decode(r[0], (uint256)), 1000);
        assertEq(r[1].length, 0);
    }

    function test_receiversAndNoFallback() public {
        T1155 t = new T1155();
        t.mint(acct, 7, 3);
        assertEq(t.balanceOf(acct, 7), 3);
        TNft n = new TNft();
        n.mint(address(this), 5);
        n.safeTransferFrom(address(this), acct, 5);
        assertEq(n.ownerOf(5), acct);
        (bool ok,) = acct.call(abi.encodeWithSignature("lock(uint256)", 1));
        assertFalse(ok);
        (ok,) = acct.call(abi.encodeWithSignature("setOverrides(bytes4[],address[])", new bytes4[](0), new address[](0)));
        assertFalse(ok);
        (ok,) = acct.call(abi.encodeWithSignature("setPermissions(address[],bool[])", new address[](0), new bool[](0)));
        assertFalse(ok);
        (ok,) = acct.call(abi.encodeWithSelector(0x19822f7c)); // validateUserOp
        assertFalse(ok);
        (ok,) = acct.call{value: 1}("");
        assertTrue(ok);
    }

    function test_K24_ownNftIsRefused() public {
        vm.prank(address(coll));
        vm.expectRevert(ERC6551PAccount.OwnershipCycle.selector);
        ERC6551PAccount(payable(acct)).onERC721Received(alice, alice, 1, "");
        vm.prank(address(coll));
        assertEq(ERC6551PAccount(payable(acct)).onERC721Received(alice, alice, 2, ""), bytes4(0x150b7a02));
    }

    function test_K25_operationAndSelfCall() public {
        for (uint8 op = 1; op <= 3; op++) {
            vm.prank(alice);
            vm.expectRevert(ERC6551PAccount.OperationNotSupported.selector);
            IAccount(acct).execute(bob, 0, "", op);
        }
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.SelfCall.selector);
        IAccount(acct).execute(acct, 0, "", 0);
    }

    // ---------------------------------------------------------------- the batch (§7.1.3)
    function test_I5_stateChangesEveryBatchOnly() public {
        uint256 s0 = IAccount(acct).state();
        _exec(bob, "");
        uint256 s1 = IAccount(acct).state();
        assertTrue(s1 != s0);
        // deposits do not change it
        tok.mint(acct, 5);
        vm.deal(acct, 2 ether);
        assertEq(IAccount(acct).state(), s1);
        // a reverted batch rolls it back
        vm.prank(alice);
        vm.expectRevert();
        IAccount(acct).execute(address(tok), 0, abi.encodeCall(TToken.transfer, (bob, 10 ** 9)), 0);
        assertEq(IAccount(acct).state(), s1);
        // the same calldata twice gives a new state each time
        _exec(bob, "");
        assertTrue(IAccount(acct).state() != s1);
    }

    function test_inBatchDuringALeg() public {
        InBatchProbe p = new InBatchProbe();
        assertFalse(IAccount(acct).inBatch());
        _exec(address(p), abi.encodeCall(InBatchProbe.probe, ()));
        assertTrue(p.seen());
        assertFalse(IAccount(acct).inBatch());
    }

    function test_K26_reentryRefused() public {
        OwnerWallet w = new OwnerWallet();
        vm.prank(alice);
        coll.transferFrom(alice, address(w), 1);
        w.setAccount(acct);
        CallbackTarget t = new CallbackTarget();
        w.setHook(acct, abi.encodeWithSelector(0x51945447, bob, uint256(1), bytes(""), uint8(0)));
        vm.expectRevert(ERC6551PAccount.Reentered.selector);
        w.exec(address(t), 0, abi.encodeCall(CallbackTarget.poke, (address(w))));
    }

    function test_K27_A30_ownerChangesInsideALeg() public {
        OwnerWallet w = new OwnerWallet();
        vm.prank(alice);
        coll.transferFrom(alice, address(w), 1);
        w.setAccount(acct);
        CallbackTarget t = new CallbackTarget();
        // the owner contract sells the NFT during leg 1
        w.setHook(address(coll), abi.encodeWithSignature("transferFrom(address,address,uint256)", address(w), bob, 1));
        vm.expectRevert(ERC6551PAccount.OwnerChanged.selector);
        w.exec(address(t), 0, abi.encodeCall(CallbackTarget.poke, (address(w))));
        assertEq(coll.ownerOf(1), address(w));
    }

    // ---------------------------------------------------------------- ERC-20 grants (§7.1.4)
    function test_K1_approveThenSpendExactlyPasses() public {
        _batch(
            _ops2(
                _op(address(tok), _approve(address(spender), 100)),
                _op(address(spender), abi.encodeCall(Spender.pull, (tok, acct, 100)))
            )
        );
        assertEq(tok.allowance(acct, address(spender)), 0);
        assertEq(tok.balanceOf(address(spender)), 100);
    }

    function test_K2_spendLessRevertsUnlessReset_W8() public {
        IAccount.Operation memory a = _op(address(tok), _approve(address(spender), 100));
        IAccount.Operation memory b = _op(address(spender), abi.encodeCall(Spender.pull, (tok, acct, 60)));
        vm.prank(alice);
        _expectGrant(0, address(tok), address(spender));
        IAccount(acct).executeBatch(_ops2(a, b));
        _batch(_ops3(a, b, _op(address(tok), _approve(address(spender), 0))));
        assertEq(tok.allowance(acct, address(spender)), 0);
    }

    function test_A1_K3_standingApproveRefused() public {
        vm.prank(alice);
        _expectGrant(0, address(tok), S);
        IAccount(acct).execute(address(tok), 0, _approve(S, type(uint256).max), 0);
        // a lowering passes; a built-in grant the account never made does not block (R-5)
        vm.prank(acct);
        tok.approve(S, 50);
        _exec(address(tok), _approve(S, 10));
        assertEq(tok.allowance(acct, S), 10);
        vm.prank(alice);
        _expectGrant(0, address(tok), S);
        IAccount(acct).execute(address(tok), 0, _approve(S, 11), 0);
    }

    function test_legacyAndErc1363Grants() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("increaseAllowance(address,uint256)", S, 1),
            abi.encodeWithSignature("increaseApproval(address,uint256)", S, 1),
            abi.encodeWithSignature("approveAndCall(address,uint256)", S, 1),
            abi.encodeWithSignature("approveAndCall(address,uint256,bytes)", S, 1, hex"c0ffee"),
            abi.encodeWithSignature("approveAndCall(address,uint256,bytes)", S, 1, "")
        ];
        for (uint256 i; i < calls.length; i++) {
            vm.prank(alice);
            _expectGrant(0, address(tok), S);
            IAccount(acct).execute(address(tok), 0, calls[i], 0);
        }
    }

    function test_K59_decreaseThatWrapsIsAGrant() public {
        tok.setUnchecked(true);
        vm.prank(alice);
        _expectGrant(0, address(tok), S);
        IAccount(acct).execute(address(tok), 0, abi.encodeWithSignature("decreaseAllowance(address,uint256)", S, 1), 0);
        vm.prank(alice);
        _expectGrant(0, address(tok), S);
        IAccount(acct).execute(address(tok), 0, abi.encodeWithSignature("decreaseApproval(address,uint256)", S, 1), 0);
    }

    function test_K53_compareAndSetReadsTheTwoArgumentAllowance() public {
        TCas c = new TCas();
        vm.prank(alice);
        _expectGrant(0, address(c), S);
        IAccount(acct).execute(address(c), 0, abi.encodeWithSignature("approve(address,uint256,uint256)", S, 0, 5), 0);
    }

    function test_erc6909AllowanceAndOperator() public {
        T6909 t = new T6909();
        vm.prank(alice);
        _expectGrant(0, address(t), S);
        IAccount(acct).execute(address(t), 0, abi.encodeWithSignature("approve(address,uint256,uint256)", S, 3, 5), 0);
        vm.prank(alice);
        _expectGrant(0, address(t), S);
        IAccount(acct).execute(address(t), 0, abi.encodeWithSignature("setOperator(address,bool)", S, true), 0);
        _batch(
            _ops2(
                _op(address(t), abi.encodeWithSignature("setOperator(address,bool)", S, true)),
                _op(address(t), abi.encodeWithSignature("setOperator(address,bool)", S, false))
            )
        );
    }

    function test_K51_erc777Operator() public {
        T777 t = new T777();
        IAccount.Operation memory auth = _op(address(t), abi.encodeWithSignature("authorizeOperator(address)", S));
        vm.prank(alice);
        _expectGrant(0, address(t), S);
        IAccount(acct).execute(auth.to, 0, auth.data, 0);
        _batch(_ops2(auth, _op(address(t), abi.encodeWithSignature("revokeOperator(address)", S))));
    }

    // ---------------------------------------------------------------- Permit2 (K-9, K-10, A-32)
    function test_K9_A32_permit2ExpirationZeroIsLive() public {
        TPermit2 p = new TPermit2();
        bytes memory zeroExp = abi.encodeWithSignature("approve(address,address,uint160,uint48)", tok, S, 5, 0);
        vm.prank(alice);
        _expectGrant(0, address(p), S);
        IAccount(acct).execute(address(p), 0, zeroExp, 0);
        bytes memory future = abi.encodeWithSignature(
            "approve(address,address,uint160,uint48)", tok, S, 5, uint48(block.timestamp + 1)
        );
        vm.prank(alice);
        _expectGrant(0, address(p), S);
        IAccount(acct).execute(address(p), 0, future, 0);
        // an expiration in the past is no grant
        vm.warp(1000);
        _exec(address(p), abi.encodeWithSignature("approve(address,address,uint160,uint48)", tok, S, 5, uint48(999)));
        // a reset in the batch passes
        _batch(
            _ops2(
                _op(address(p), future),
                _op(address(p), abi.encodeWithSignature("approve(address,address,uint160,uint48)", tok, S, 0, 0))
            )
        );
    }

    function test_permit2LiveGrantCannotBeExtended() public {
        TPermit2 p = new TPermit2();
        vm.warp(1000);
        // a live grant the account did not make in a batch (R-5): an approve of the same amount with a later
        // expiration would pass "amount ≤ amount"; the account refuses it
        vm.prank(acct);
        p.approve(address(tok), S, 5, 2000);
        vm.prank(alice);
        _expectGrant(0, address(p), S);
        IAccount(acct).execute(
            address(p), 0, abi.encodeWithSignature("approve(address,address,uint160,uint48)", tok, S, 5, uint48(9999)), 0
        );
        // a shorter one passes
        _exec(address(p), abi.encodeWithSignature("approve(address,address,uint160,uint48)", tok, S, 5, uint48(1500)));
    }

    function test_K10_permit2LockdownIsLoweringOnly() public {
        TPermit2 p = new TPermit2();
        TPermit2.TokenSpenderPair[] memory pairs = new TPermit2.TokenSpenderPair[](1);
        pairs[0] = TPermit2.TokenSpenderPair(address(tok), S);
        _exec(address(p), abi.encodeCall(TPermit2.lockdown, (pairs)));
        assertEq(TPermit2.lockdown.selector, bytes4(0xcc53287f));
    }

    function test_permit2CanonicalWords() public {
        TPermit2 p = new TPermit2();
        bytes memory bad = abi.encodeWithSignature("approve(address,address,uint256,uint256)", tok, S, 1, 1 << 48);
        // same selector as approve(address,address,uint160,uint48)? No: the types differ; build the bytes by hand
        bad = abi.encodePacked(bytes4(0x87517c45), abi.encode(address(tok), S, uint256(1), uint256(1) << 48));
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(p), 0, bad, 0);
        bad = abi.encodePacked(bytes4(0x87517c45), abi.encode(address(tok), S, uint256(1) << 160, uint256(1)));
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(p), 0, bad, 0);
    }

    // ---------------------------------------------------------------- NFTs (K-11 … K-14, K-52 … K-58)
    function test_K11_A36_approveIdZeroOnAnNftIsRefused() public {
        TNft n = new TNft();
        n.mint(acct, 0);
        _expectRefused(address(n), 0x095ea7b3);
        _exec(address(n), _approve(S, 0));
    }

    function test_K12_K13_revocationPasses() public {
        TNft n = new TNft();
        n.mint(acct, 4);
        _exec(address(n), _approve(address(0), 4));
        assertEq(n.getApproved(4), address(0));
    }

    function test_A37_K57_noPerTokenApproval() public {
        TNft n = new TNft();
        n.mint(acct, 4);
        _expectRefused(address(n), 0x095ea7b3);
        _exec(address(n), _approve(S, 4));
        // an id the account does not hold: the probe still sees an NFT-like target (supportsInterface)
        _expectRefused(address(n), 0x095ea7b3);
        _exec(address(n), _approve(S, 12345));
    }

    function test_K14_A38_nftOperatorRefused() public {
        TNft n = new TNft();
        _expectRefused(address(n), 0xa22cb465);
        _exec(address(n), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true));
        // false always passes
        _exec(address(n), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, false));
        // inside a wrapper
        TNftMulti m = new TNftMulti();
        _expectRefused(address(m), 0xa22cb465);
        _exec(address(m), _wrap(abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true)));
    }

    function test_K8_proven1155OperatorIsATuple() public {
        T1155 t = new T1155();
        bytes memory on = abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true);
        vm.prank(alice);
        _expectGrant(0, address(t), S);
        IAccount(acct).execute(address(t), 0, on, 0);
        _batch(_ops2(_op(address(t), on), _op(address(t), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, false))));
    }

    function test_V06_erc5006AndFake1155OperatorRefused() public {
        T5006 t = new T5006();
        _expectRefused(address(t), 0xa22cb465);
        _exec(address(t), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true));
        TFake1155 f = new TFake1155();
        _expectRefused(address(f), 0xa22cb465);
        _exec(address(f), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true));
    }

    function test_K52_K56_K58_A44_erc404() public {
        T404 t = new T404();
        // approve of an AMOUNT on the hybrid is refused too (NFT-like target: a public getApproved)
        _expectRefused(address(t), 0x095ea7b3);
        _exec(address(t), _approve(S, 5));
        _expectRefused(address(t), 0x095ea7b3);
        _exec(address(t), _approve(S, type(uint256).max - 1));
        _expectRefused(address(t), 0xa22cb465);
        _exec(address(t), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true));
        _expectRefused(address(t), 0xdfabc033);
        _exec(address(t), abi.encodeWithSignature("erc721Approve(address,uint256)", S, 1));
        _expectRefused(address(t), 0x4d966072);
        _exec(address(t), abi.encodeWithSignature("erc20Approve(address,uint256)", S, 1));
    }

    function test_K4_A34_nestedPositionApproveRefused() public {
        TNftMulti m = new TNftMulti();
        m.mint(acct, 9);
        bytes memory d = _approve(S, 9);
        for (uint256 depth; depth < 6; depth++) {
            d = _wrap(d);
        }
        _expectRefused(address(m), 0x095ea7b3);
        _exec(address(m), d);
        // the same through BoringBatchable batch and multicall(uint256,bytes[])
        bytes[] memory one = new bytes[](1);
        one[0] = _approve(S, 9);
        _expectRefused(address(m), 0x095ea7b3);
        _exec(address(m), abi.encodeWithSignature("batch(bytes[],bool)", one, true));
        _expectRefused(address(m), 0x095ea7b3);
        _exec(address(m), abi.encodeWithSignature("multicall(uint256,bytes[])", block.timestamp, one));
        _expectRefused(address(m), 0x095ea7b3);
        _exec(address(m), abi.encodeWithSignature("multicall(bytes32,bytes[])", bytes32(0), one));
    }

    function test_wrappedErc20GrantIsATuple() public {
        bytes memory d = _wrap(_wrap(_approve(S, 7)));
        vm.prank(alice);
        _expectGrant(0, address(tok), S);
        IAccount(acct).execute(address(tok), 0, d, 0);
        bytes[] memory two = new bytes[](2);
        two[0] = _approve(S, 7);
        two[1] = _approve(S, 0);
        _exec(address(tok), abi.encodeWithSignature("multicall(bytes[])", two));
        _exec(address(tok), abi.encodeWithSignature("batch(bytes[],bool)", two, true));
    }

    // ---------------------------------------------------------------- refused selectors and targets (K-49, K-68)
    function test_K49_K68_refusedTargets() public {
        address[10] memory targets = [
            0x0000000000000068F116a894984e2DB1123eB395,
            0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC,
            0x00000000000001ad428e4906aE43D8F9852d0dD6,
            0x0000000000000aD24e80fd803C6ac37206a45f15,
            0x00000000000006c7676171937C444f6BDe3D6282,
            0x00000000006c3852cbEf3e08E8dF289169EdE581,
            0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24,
            0x00000000000000447e69651d841bD8D104Bed493,
            0x00000000000076A84feF008CDAbe6409d2FE638B,
            0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3
        ];
        for (uint256 i; i < targets.length; i++) {
            _expectRefused(targets[i], bytes4(0));
            _exec(targets[i], "");
        }
    }

    /// @dev Review 2026-11-06 (R10): a Tokenbound account inside this account has this account as its root owner, so
    ///      its permissions and overrides survive the sale of the NFT. The two writes are refused on any target.
    function test_K93_tokenboundPermissionWritesRefused() public {
        address[] memory callers = new address[](0);
        bool[] memory flags = new bool[](0);
        bytes4[] memory sels = new bytes4[](0);
        bytes memory perms = abi.encodeWithSignature("setPermissions(address[],bool[])", callers, flags);
        bytes memory overrides = abi.encodeWithSignature("setOverrides(bytes4[],address[])", sels, callers);
        _expectRefused(address(tok), 0x039721b1);
        _exec(address(tok), perms);
        _expectRefused(address(tok), 0x7a8f7356);
        _exec(address(tok), overrides);
        _expectRefused(address(tok), 0x039721b1);
        _exec(address(tok), _wrap(perms));
    }

    /// @dev R11: Tokenbound `lock(uint256)` is keyed to the same root owner as K-93 (this account): a seller could
    ///      freeze an inner Tokenbound account for up to 365 days across the sale.
    function test_K94_tokenboundLockRefused() public {
        bytes memory lockCall = abi.encodeWithSignature("lock(uint256)", block.timestamp + 365 days);
        _expectRefused(address(tok), 0xdd467064);
        _exec(address(tok), lockCall);
        _expectRefused(address(tok), 0xdd467064);
        _exec(address(tok), _wrap(lockCall));
    }

    /// @dev The ERC-8004 wallet link is not reset by a sale of the NFT (the identity token stays
    ///      in the account), so a seller could leave its own key as `agentWallet`; and once changed or cleared, the
    ///      link can never name the account again (the account signs nothing). Both writes are refused on any target.
    function test_K95_agentWalletWritesRefused() public {
        bytes memory setCall =
            abi.encodeWithSignature("setAgentWallet(uint256,address,uint256,bytes)", 1, address(0xBEEF), block.timestamp, "");
        bytes memory unsetCall = abi.encodeWithSignature("unsetAgentWallet(uint256)", 1);
        _expectRefused(address(tok), 0x2d1ef5ae);
        _exec(address(tok), setCall);
        _expectRefused(address(tok), 0x3fddcf19);
        _exec(address(tok), unsetCall);
        _expectRefused(address(tok), 0x2d1ef5ae);
        _exec(address(tok), _wrap(setCall));
        _expectRefused(address(tok), 0x3fddcf19);
        _exec(address(tok), _wrap(unsetCall));
    }

    function test_K49_refusedSelectorsAtAnyDepth() public {
        bytes4[24] memory sels = [
            bytes4(0x88147732),
            0xec6cb13f,
            0xd4d9bdcd,
            0x5df8122f,
            0x29965a1d,
            0x2b9261de,
            0xe030565e,
            0x883d1d5f,
            0xdfabc033,
            0x4d966072,
            0x8cb0a511,
            0x55cd4e06,
            0x30ff3140,
            0xd90e73ab,
            0x003c2ba6,
            0xb18e2bbb,
            0xab764683,
            0x685ee3e8,
            0x49c95d29,
            0x537a5c3d,
            0xa3b22fc4,
            0xfa6e671d,
            0x9f5c462a,
            0xea7faa61
        ];
        for (uint256 i; i < sels.length; i++) {
            bytes memory d = abi.encodePacked(sels[i], bytes32(0));
            _expectRefused(address(tok), sels[i]);
            _exec(address(tok), d);
            _expectRefused(address(tok), sels[i]);
            _exec(address(tok), _wrap(_wrap(d)));
        }
    }

    /// K-84 (final audit 2026-10-30): the sibling writes and the self-call wrappers of protocols whose operator right
    /// has no read-back in the account: Euler EVC `setOperator(bytes19,…)` and its `call` / `batch` (which run a
    /// self-targeted item with the caller kept, so a refused `setAccountOperator` could pass inside them), Maker
    /// DssCdpManager `cdpAllow` / `urnAllow`, Superfluid streams and flow-operator permissions (CFAv1Forwarder
    /// `setFlowrate`, `createFlow`, `grantPermissions`, `updateFlowOperatorPermissions`; host `callAgreement`,
    /// `batchCall`). Refused with any arguments, directly and inside a known wrapper.
    function test_K84_operatorSiblingsAndProtocolWrappersRefused() public {
        bytes4[11] memory sels = [
            bytes4(0xc14c11bf), // EVC setOperator(bytes19,address,uint256)
            0x1f8b5215, // EVC call(address,address,uint256,bytes)
            0xc16ae7a4, // EVC batch((address,address,uint256,bytes)[])
            0x0b63fb62, // Maker cdpAllow(uint256,address,uint256)
            0xb68f4004, // Maker urnAllow(address,uint256)
            0x57e6aa36, // Superfluid setFlowrate(address,address,int96)
            0xe15536b6, // Superfluid createFlow(address,address,address,int96,bytes)
            0x7243fb93, // Superfluid grantPermissions(address,address)
            0x30885591, // Superfluid updateFlowOperatorPermissions(address,address,uint8,int96)
            0x39255d5b, // Superfluid host callAgreement(address,bytes,bytes)
            0x6ad3ca7d // Superfluid host batchCall((uint32,address,bytes)[])
        ];
        for (uint256 i; i < sels.length; i++) {
            bytes memory d = abi.encodePacked(sels[i], bytes32(0));
            _expectRefused(address(tok), sels[i]);
            _exec(address(tok), d);
            _expectRefused(address(tok), sels[i]);
            _exec(address(tok), _wrap(d));
        }
    }

    /// K-88 (final audit 2026-10-30, pass 2): an ERC-7674 `temporaryApprove` lives in transient storage until the end of
    /// the TRANSACTION, not of the batch; a seller that is a contract could batch it, sell through a ticket path
    /// (`accept`, a zone offer) in the same transaction, and pull after the sale. It is a modeled grant: the read-back
    /// (`allowance`, which includes the temporary allowance) refuses it at rest, and approve → spend → passes.
    function test_K88_erc7674TemporaryApproveIsAModeledGrant() public {
        TTemp t = new TTemp();
        t.mint(acct, 1000);
        bytes memory d = abi.encodeWithSelector(bytes4(0x42232a4c), S, uint256(100)); // temporaryApprove(address,uint256)
        _expectGrant(0, address(t), S);
        _exec(address(t), d);
        // used up inside the batch: passes
        TempSpender ts = new TempSpender();
        IAccount.Operation[] memory ops = _ops2(
            _op(address(t), abi.encodeWithSelector(bytes4(0x42232a4c), address(ts), uint256(100))),
            _op(address(ts), abi.encodeCall(TempSpender.pull, (t, acct, 100)))
        );
        _batch(ops);
        assertEq(t.balanceOf(address(ts)), 100);
        assertEq(t.allowance(acct, address(ts)), 0);
    }

    /// K-89 (final audit 2026-10-30, pass 2): DSToken `approve(address)` (Maker) sets the allowance to the maximum. It is
    /// a modeled grant (`allowance(account, guy)`): refused at rest unless reset in the batch.
    function test_K89_dsTokenSingleArgumentApproveIsAModeledGrant() public {
        TDsToken t = new TDsToken();
        bytes memory d = abi.encodeWithSelector(bytes4(0xdaea85c5), S); // approve(address)
        _expectGrant(0, address(t), S);
        _exec(address(t), d);
        // reset in the same batch: passes
        _batch(_ops2(_op(address(t), d), _op(address(t), abi.encodeWithSelector(bytes4(0x095ea7b3), S, uint256(0)))));
        assertEq(t.allowance(acct, S), 0);
        // short or long calldata
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(t), 0, abi.encodePacked(bytes4(0xdaea85c5), bytes32(uint256(uint160(S))), uint8(1)), 0);
    }

    /// K-90 (final audit 2026-10-30, pass 3): more writes with no read-back — Superfluid GDA `distributeFlow` and the
    /// MacroForwarder `runMacro` (the same streams as K-84), Venus `updateDelegate` and dYdX `setOperators` (a delegate
    /// borrows or acts for the account), CryptoPunks `offerPunkForSale` / `offerPunkForSaleToAddress` and 0x v3
    /// `preSign` (standing sale orders). Refused with any arguments, directly and inside a known wrapper.
    function test_K90_moreRightsWithNoReadBackRefused() public {
        bytes4[7] memory sels = [
            bytes4(0x5a6c6dbc), // Superfluid GDAv1Forwarder distributeFlow(address,address,address,int96,bytes)
            0x651aeb70, // Superfluid MacroForwarder runMacro(address,bytes)
            0xddbf54fd, // Venus Comptroller updateDelegate(address,bool)
            0x85b53fc8, // dYdX SoloMargin setOperators((address,bool)[])
            0xc44193c3, // CryptoPunks offerPunkForSale(uint256,uint256)
            0xbf31196f, // CryptoPunks offerPunkForSaleToAddress(uint256,uint256,address)
            0x46c02d7a // 0x v3 preSign(bytes32)
        ];
        for (uint256 i; i < sels.length; i++) {
            bytes memory d = abi.encodePacked(sels[i], bytes32(0));
            _expectRefused(address(tok), sels[i]);
            _exec(address(tok), d);
            _expectRefused(address(tok), sels[i]);
            _exec(address(tok), _wrap(d));
        }
    }

    // ---------------------------------------------------------------- encoding (K-50, K-60, the decoder)
    function test_K50_nonCanonicalBool() public {
        T1155 t = new T1155();
        bytes memory d = abi.encodePacked(bytes4(0xa22cb465), abi.encode(S, uint256(2)));
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(t), 0, d, 0);
    }

    function test_K60_shortOrLongGrantCalldata() public {
        bytes memory good = _approve(S, 1);
        bytes memory long_ = bytes.concat(good, hex"00");
        bytes memory short_ = new bytes(good.length - 1);
        for (uint256 i; i < short_.length; i++) {
            short_[i] = good[i];
        }
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(tok), 0, long_, 0);
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(tok), 0, short_, 0);
        // a dirty address word
        bytes memory dirty = abi.encodePacked(bytes4(0x095ea7b3), uint256(uint160(S)) | (1 << 200), uint256(1));
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(tok), 0, dirty, 0);
    }

    function test_decoderRefusesNonCanonicalWrappers() public {
        bytes memory inner = _approve(S, 1);
        bytes memory canonical = _wrap(inner);
        // trailing bytes
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(tok), 0, bytes.concat(canonical, bytes32(0)), 0);
        // the array offset moved (a valid ABI encoding for Solidity, not the canonical one)
        bytes memory moved = abi.encodePacked(
            bytes4(0xac9650d8), uint256(0x40), uint256(0), uint256(1), uint256(0x20), uint256(inner.length), inner, new bytes(28)
        );
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(tok), 0, moved, 0);
        // an element offset that points back into the head
        bytes memory overlap = abi.encodePacked(bytes4(0xac9650d8), uint256(0x20), uint256(1), uint256(0), uint256(68));
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(tok), 0, overlap, 0);
        // a huge length
        bytes memory huge = abi.encodePacked(bytes4(0xac9650d8), uint256(0x20), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(tok), 0, huge, 0);
    }

    // ---------------------------------------------------------------- reads (K-15, K-16, K-17, A-15, A-16, A-31)
    function test_K15_A16_failedReadFailsClosed() public {
        TGasBurner g = new TGasBurner();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC6551PAccount.ReadFailed.selector, address(g)));
        IAccount(acct).execute(address(g), 0, _approve(S, 1), 0);
        g.setRevert(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC6551PAccount.ReadFailed.selector, address(g)));
        IAccount(acct).execute(address(g), 0, _approve(S, 1), 0);
        // a grant on an address with no code fails closed (no grant on a contract created in the same batch)
        address none = makeAddr("no-code");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC6551PAccount.ReadFailed.selector, none));
        IAccount(acct).execute(none, 0, _approve(S, 1), 0);
        // a lending grant on a token without its getter
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC6551PAccount.ReadFailed.selector, address(tok)));
        IAccount(acct).execute(address(tok), 0, abi.encodeWithSignature("approveDelegation(address,uint256)", S, 1), 0);
    }

    function test_K16_A31_lowGasRevertsNeverSkips() public {
        bytes memory cd = abi.encodeWithSelector(0x51945447, address(tok), uint256(0), _approve(S, 1), uint8(0));
        for (uint256 g = 30_000; g < 400_000; g += 7_919) {
            vm.prank(alice);
            (bool ok,) = acct.call{gas: g}(cd);
            assertFalse(ok);
            assertEq(tok.allowance(acct, S), 0);
        }
    }

    function test_K17_tooManyGrants() public {
        bytes[] memory many = new bytes[](65);
        for (uint256 i; i < 65; i++) {
            many[i] = _approve(address(uint160(1000 + i)), 0);
        }
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.TooManyGrants.selector);
        IAccount(acct).execute(address(tok), 0, abi.encodeWithSignature("multicall(bytes[])", many), 0);
        bytes[] memory ok64 = new bytes[](64);
        for (uint256 i; i < 64; i++) {
            ok64[i] = many[i];
        }
        vm.prank(alice);
        IAccount(acct).execute{gas: 15_000_000}(address(tok), 0, abi.encodeWithSignature("multicall(bytes[])", ok64), 0);
    }

    function test_A15_lyingTargetIsResidualR1() public {
        TLiar l = new TLiar();
        _exec(address(l), _approve(S, 99));
        assertEq(l.realAllowance(acct, S), 99, "R-1: a target that lies about its own grant is not covered");
    }

    // ---------------------------------------------------------------- readyToSell is the last leg (K-18)
    function test_K18_readyToSellMustBeLast() public {
        bytes memory ready = abi.encodeWithSignature("readyToSell(uint256)", 1);
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.ReadyNotLast.selector);
        IAccount(acct).executeBatch(_ops2(_op(address(coll), ready), _op(bob, "")));
        // a journal entry may follow (a journal entry can come last); value or another target may not
        IAccount.Operation memory j = _op(address(log_), abi.encodeCall(JournalLog.log, (hex"01")));
        IAccount.Operation memory jv = IAccount.Operation(address(log_), 1, abi.encodeCall(JournalLog.log, (hex"01")), 0);
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.ReadyNotLast.selector);
        IAccount(acct).executeBatch(_ops3(_op(address(coll), ready), j, jv));
        // TNft has no readyToSell: the check passes and the leg itself reverts
        vm.prank(alice);
        vm.expectRevert();
        IAccount(acct).executeBatch(_ops2(_op(address(coll), ready), j));
    }

    // ---------------------------------------------------------------- corner cases
    /// @dev An owner contract sends the NFT away and gets it back inside ONE leg: the owner after the leg is the same,
    ///      so the batch passes; the middle owner could not use the account (the batch flag is set).
    function test_C01_ownerRoundTripInsideALeg() public {
        OwnerWallet w = new OwnerWallet();
        vm.prank(alice);
        coll.transferFrom(alice, address(w), 1);
        w.setAccount(acct);
        Bouncer b = new Bouncer();
        b.setAccount(acct);
        w.setHook(
            address(coll), abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(w), address(b), 1)
        );
        CallbackTarget t = new CallbackTarget();
        w.exec(address(t), 0, abi.encodeCall(CallbackTarget.poke, (address(w))));
        assertEq(coll.ownerOf(1), address(w));
        assertEq(b.seen(), ERC6551PAccount.Reentered.selector);
    }

    /// @dev A leg target that calls the account itself is not the owner.
    function test_C02_legTargetCallsTheAccount() public {
        CallsBack cb = new CallsBack();
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(acct).execute(address(cb), 0, abi.encodeCall(CallsBack.go, (acct)), 0);
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(acct).execute(address(cb), 0, abi.encodeCall(CallsBack.goBatch, (acct)), 0);
    }

    /// @dev Legs to the account's own collection, to the registry and to another token's account.
    function test_C03_legsToTheCollectionTheRegistryAndAnotherAccount() public {
        // the collection is NFT-like: no approval and no operator
        _expectRefused(address(coll), 0x095ea7b3);
        _exec(address(coll), _approve(S, 1));
        _expectRefused(address(coll), 0xa22cb465);
        _exec(address(coll), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true));
        // the registry: creating an account is not a grant
        bytes memory create =
            abi.encodeCall(IERC6551Registry.createAccount, (address(impl_), bytes32(uint256(5)), block.chainid, address(coll), 1));
        address made = abi.decode(_exec(REGISTRY, create), (address));
        assertEq(made.code.length, 173);
        // another token's account: this account is not its owner
        coll.mint(alice, 2);
        address acct2 = IERC6551Registry(REGISTRY).createAccount(address(impl_), bytes32(0), block.chainid, address(coll), 2);
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.NotOwner.selector);
        IAccount(acct).execute(acct2, 0, abi.encodeWithSelector(0x51945447, bob, uint256(0), bytes(""), uint8(0)), 0);
    }

    /// @dev Value with no call data, call data shorter than a selector, and precompile targets.
    function test_C04_valueOnlyShortCalldataAndPrecompiles() public {
        uint256 b0 = bob.balance;
        vm.prank(alice);
        IAccount(acct).execute(bob, 0.1 ether, "", 0);
        assertEq(bob.balance - b0, 0.1 ether);
        Sink sink = new Sink();
        _exec(address(sink), hex"095ea7"); // 3 bytes: no selector, nothing to decode
        assertEq(sink.hits(), 1);
        _exec(address(4), hex"deadbeef"); // the identity precompile
        _exec(address(2), "abc"); // sha256
        // a grant selector to a precompile: the reads echo the input, before = after, nothing stands
        _exec(address(4), _approve(S, 1));
    }

    /// @dev R-1: a getter that changes inside the batch (here a switch; on a real token a proxy upgrade in an earlier
    ///      leg) hides the grant from the read after the legs.
    function test_C05_getterChangedInsideTheBatchIsResidualR1() public {
        TSwitch t = new TSwitch();
        _batch(_ops2(_op(address(t), abi.encodeCall(TSwitch.setLie, (true))), _op(address(t), _approve(S, 99))));
        assertEq(t.realAllowance(acct, S), 99, "R-1: a target whose getter changes in the batch is not covered");
    }

    /// @dev A getter that answers fewer than 32 bytes fails closed; one that answers more is read by its first word.
    function test_C06_getterReturnShapes() public {
        TShape t = new TShape();
        t.setSize(31);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC6551PAccount.ReadFailed.selector, address(t)));
        IAccount(acct).execute(address(t), 0, _approve(S, 1), 0);
        t.setSize(96);
        _expectGrant(0, address(t), S);
        vm.prank(alice);
        IAccount(acct).execute(address(t), 0, _approve(S, 1), 0);
        _exec(address(t), _approve(S, 0));
    }

    function _nest(bytes memory d, uint256 depth) internal pure returns (bytes memory) {
        for (uint256 i; i < depth; i++) {
            bytes[] memory a = new bytes[](1);
            a[0] = d;
            d = abi.encodeWithSignature("multicall(bytes[])", a);
        }
        return d;
    }

    /// @dev Deep nesting: the decoder finds the grant at every depth it can walk; deeper than the EVM stack allows, the
    ///      batch reverts (fail closed) and nothing stands.
    function test_C07_deepNestingFailsClosed() public {
        _expectGrant(0, address(tok), S);
        vm.prank(alice);
        IAccount(acct).execute{gas: 20_000_000}(address(tok), 0, _nest(_approve(S, 1), 20), 0);
        uint256 maxDecoded;
        bytes memory d = _nest(_approve(S, 1), 20);
        for (uint256 depth = 21; depth <= 160; depth++) {
            d = _nest(d, 1);
            if (depth > 40 && depth % 10 != 0) continue;
            vm.prank(alice);
            (bool ok, bytes memory r) =
                acct.call{gas: 20_000_000}(abi.encodeWithSelector(0x51945447, address(tok), uint256(0), d, uint8(0)));
            assertFalse(ok);
            assertEq(tok.allowance(acct, S), 0);
            if (r.length >= 4 && bytes4(r) == ERC6551PAccount.StandingGrant.selector) maxDecoded = depth;
        }
        assertEq(maxDecoded, 30, "the decoder walks 30 nested wrappers; deeper fails closed on the EVM stack");
    }

    /// @dev An ERC-1155 that also claims ERC-721 is not a proven ERC-1155: no operator.
    function test_C08_erc1155ThatAlsoAnswersErc721Refused() public {
        T1155As721 t = new T1155As721();
        _expectRefused(address(t), 0xa22cb465);
        _exec(address(t), abi.encodeWithSignature("setApprovalForAll(address,bool)", S, true));
    }

    /// @dev USDT-style approve (no return value, zero first): W8 passes, a leftover allowance does not.
    function test_C09_usdtStyleApprove() public {
        TUsdt t = new TUsdt();
        t.mint(acct, 1000);
        UsdtSpender sp = new UsdtSpender();
        _batch(
            _ops3(
                _op(address(t), _approve(address(sp), 100)),
                _op(address(sp), abi.encodeCall(UsdtSpender.pull, (t, acct, 60))),
                _op(address(t), _approve(address(sp), 0))
            )
        );
        assertEq(t.allowance(acct, address(sp)), 0);
        assertEq(t.balanceOf(address(sp)), 60);
        _expectGrant(0, address(t), address(sp));
        _batch(
            _ops2(_op(address(t), _approve(address(sp), 100)), _op(address(sp), abi.encodeCall(UsdtSpender.pull, (t, acct, 60))))
        );
    }

    /// @dev The lending authorizations are tuples: a standing one reverts, one set and reset in the batch passes, a
    ///      non-canonical bool is refused.
    function test_C23_lendingAuthorizationsAreTuples() public {
        TLender l = new TLender();
        bytes[3] memory grant = [
            abi.encodeWithSignature("approveDelegation(address,uint256)", S, 5),
            abi.encodeWithSignature("setAuthorization(address,bool)", S, true),
            abi.encodeWithSignature("allow(address,bool)", S, true)
        ];
        bytes[3] memory reset = [
            abi.encodeWithSignature("approveDelegation(address,uint256)", S, 0),
            abi.encodeWithSignature("setAuthorization(address,bool)", S, false),
            abi.encodeWithSignature("allow(address,bool)", S, false)
        ];
        for (uint256 i; i < 3; i++) {
            _expectGrant(0, address(l), S);
            _exec(address(l), grant[i]);
            _batch(_ops2(_op(address(l), grant[i]), _op(address(l), reset[i])));
        }
        assertEq(l.borrowAllowance(acct, S), 0);
        assertFalse(l.isAuthorized(acct, S));
        assertFalse(l.isAllowed(acct, S));
        vm.prank(alice);
        vm.expectRevert(ERC6551PAccount.BadEncoding.selector);
        IAccount(acct).execute(address(l), 0, abi.encodePacked(bytes4(0x110496e5), abi.encode(S, uint256(2))), 0);
    }

    // ---------------------------------------------------------------- fuzz: the decoder and the reads
    /// @dev Any bytes as a multicall payload: the batch reverts, or it passed and no allowance stands.
    function testFuzz_decoderRandomPayload(bytes calldata junk) public {
        bytes memory d = bytes.concat(bytes4(0xac9650d8), junk);
        vm.prank(alice);
        (bool ok,) = acct.call(abi.encodeWithSelector(0x51945447, address(tok), uint256(0), d, uint8(0)));
        ok; // either way
        assertEq(tok.allowance(acct, S), 0);
    }

    /// @dev An approve at a random depth of random wrappers, with random siblings: always caught.
    function testFuzz_decoderNestedApproveAlwaysCaught(uint8 depth, uint8 kinds, uint96 v, uint8 siblings) public {
        vm.assume(v != 0);
        bytes memory d = _approve(S, v);
        for (uint256 i; i < depth % 8; i++) {
            uint256 k = (uint256(kinds) >> (i % 4) * 2) % 4;
            uint256 n = 1 + siblings % 3;
            bytes[] memory a = new bytes[](n);
            for (uint256 j; j < n; j++) {
                a[j] = j == 0 ? d : abi.encodeWithSignature("balanceOf(address)", acct);
            }
            if (k == 0) d = abi.encodeWithSignature("multicall(bytes[])", a);
            else if (k == 1) d = abi.encodeWithSignature("multicall(uint256,bytes[])", uint256(1), a);
            else if (k == 2) d = abi.encodeWithSignature("multicall(bytes32,bytes[])", bytes32(0), a);
            else d = abi.encodeWithSignature("batch(bytes[],bool)", a, true);
        }
        vm.prank(alice);
        _expectGrant(0, address(tok), S);
        IAccount(acct).execute(address(tok), 0, d, 0);
        // without the account the same call really grants (the decoder is not tested against a no-op)
        vm.prank(acct);
        (bool ok,) = address(tok).call(d);
        assertTrue(ok);
        assertEq(tok.allowance(acct, S), v);
    }

    /// @dev A random word flipped inside a canonical wrapper: the batch reverts, or no allowance stands.
    function testFuzz_decoderMutatedWrapper(uint16 at, uint256 word) public {
        bytes[] memory a = new bytes[](2);
        a[0] = abi.encodeWithSignature("balanceOf(address)", acct);
        a[1] = _approve(S, 5);
        bytes memory d = abi.encodeWithSignature("multicall(bytes[])", a);
        uint256 off = 4 + (uint256(at) % ((d.length - 4) / 32)) * 32;
        assembly {
            mstore(add(add(d, 32), off), word)
        }
        vm.prank(alice);
        (bool ok,) = acct.call(abi.encodeWithSelector(0x51945447, address(tok), uint256(0), d, uint8(0)));
        ok;
        assertEq(tok.allowance(acct, S), 0);
    }

    /// @dev Random gas: a grant batch never passes with a standing grant, a grant-free batch passes or reverts whole.
    function testFuzz_readsUnderRandomGas(uint32 g) public {
        uint256 gas_ = bound(g, 21_000, 3_000_000);
        bytes memory cd = abi.encodeWithSelector(0x51945447, address(tok), uint256(0), _approve(S, 3), uint8(0));
        vm.prank(alice);
        (bool ok,) = acct.call{gas: gas_}(cd);
        assertFalse(ok);
        assertEq(tok.allowance(acct, S), 0);
    }
}
