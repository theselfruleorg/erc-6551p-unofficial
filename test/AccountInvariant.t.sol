// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC6551PBase, IAccount} from "./ERC6551PBase.sol";
import {ERC6551PAccount} from "../src/account/ERC6551PAccount.sol";
import {JournalLog} from "../src/kit/JournalLog.sol";
import {IERC6551Registry} from "../src/interfaces/IERC6551Registry.sol";
import {
    TToken, Spender, TNft, T1155, T6909, TCas, T777, T404, TPermit2, TGasBurner
} from "./mocks/AccountMocks.sol";

/// @dev Drives random batches of the account through every modeled surface, random owner changes, deposits, NFTs in
///      and out, and random gas limits. The invariants are asserted by AccountInvariantTest after each call.
contract AccountHandler is Test {
    address public immutable account;
    TNft public immutable coll;
    TToken public tok;
    T1155 public t1155;
    T6909 public t6909;
    TCas public cas;
    T777 public t777;
    T404 public t404;
    TPermit2 public p2;
    TNft public nft;
    TGasBurner public burner;
    Spender public spender;
    address[] public spenders;
    address[] public owners;
    uint256 public batches; // successful batches
    uint256 public lastState;
    bool public stateMovedWithoutBatch;
    bool public stateStuck;
    uint256 public ethBefore;
    bool public ethLeftWithoutBatch;

    constructor(address account_, TNft coll_, address[] memory owners_) {
        account = account_;
        coll = coll_;
        owners = owners_;
        tok = new TToken();
        tok.setUnchecked(true);
        t1155 = new T1155();
        t6909 = new T6909();
        cas = new TCas();
        t777 = new T777();
        t404 = new T404();
        p2 = new TPermit2();
        nft = new TNft();
        burner = new TGasBurner();
        spender = new Spender();
        spenders.push(address(spender));
        spenders.push(address(0xBEEF));
        spenders.push(address(0xCAFE));
        tok.mint(account, 1e24);
        t1155.mint(account, 1, 100);
        t6909.mint(account, 1, 100);
        nft.mint(account, 1);
        nft.mint(account, 2);
        lastState = IAccount(account).state();
    }

    function spenderCount() external view returns (uint256) {
        return spenders.length;
    }

    function _owner() internal view returns (address) {
        return coll.ownerOf(1);
    }

    function _grantCall(uint256 kind, address s, uint256 v) internal view returns (address to, bytes memory d) {
        kind = kind % 16;
        if (kind == 0) return (address(tok), abi.encodeWithSignature("approve(address,uint256)", s, v));
        if (kind == 1) return (address(tok), abi.encodeWithSignature("increaseAllowance(address,uint256)", s, v));
        if (kind == 2) return (address(tok), abi.encodeWithSignature("decreaseAllowance(address,uint256)", s, v));
        if (kind == 3) return (address(tok), abi.encodeWithSignature("approveAndCall(address,uint256,bytes)", s, v, hex"01"));
        if (kind == 4) return (address(t1155), abi.encodeWithSignature("setApprovalForAll(address,bool)", s, v % 2 == 0));
        if (kind == 5) return (address(t6909), abi.encodeWithSignature("approve(address,uint256,uint256)", s, 1, v));
        if (kind == 6) return (address(t6909), abi.encodeWithSignature("setOperator(address,bool)", s, v % 2 == 0));
        if (kind == 7) return (address(cas), abi.encodeWithSignature("approve(address,uint256,uint256)", s, 0, v));
        if (kind == 8) return (address(t777), abi.encodeWithSignature("authorizeOperator(address)", s));
        if (kind == 9) return (address(t777), abi.encodeWithSignature("revokeOperator(address)", s));
        if (kind == 10) {
            return (
                address(p2),
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)", address(tok), s, uint160(v), uint48(v % 3 == 0 ? 0 : block.timestamp + v % 1000)
                )
            );
        }
        if (kind == 11) return (address(nft), abi.encodeWithSignature("approve(address,uint256)", s, 1 + v % 2));
        if (kind == 12) return (address(nft), abi.encodeWithSignature("setApprovalForAll(address,bool)", s, true));
        if (kind == 13) return (address(t404), abi.encodeWithSignature("approve(address,uint256)", s, v));
        if (kind == 14) return (address(burner), abi.encodeWithSignature("approve(address,uint256)", s, v));
        // a spend through the Spender (uses up an approval)
        return (address(spender), abi.encodeCall(Spender.pull, (tok, account, v % 1000)));
    }

    function _wrapN(bytes memory d, uint256 n) internal pure returns (bytes memory) {
        for (uint256 i; i < n % 4; i++) {
            bytes[] memory a = new bytes[](1);
            a[0] = d;
            d = abi.encodeWithSignature("multicall(bytes[])", a);
        }
        return d;
    }

    /// @notice A random batch of 1–4 legs, each a grant call (maybe wrapped), with a random gas limit.
    function batch(uint256 seed, uint8 legs, uint32 gasLimit) external {
        uint256 n = 1 + legs % 4;
        IAccount.Operation[] memory ops = new IAccount.Operation[](n);
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address s = spenders[r % spenders.length];
            (address to, bytes memory d) = _grantCall(r >> 8, s, (r >> 16) % 5000);
            // only token calls are wrapped (TToken has multicall)
            if (to == address(tok)) d = _wrapN(d, r >> 32);
            ops[i] = IAccount.Operation(to, 0, d, 0);
        }
        _run(ops, gasLimit);
    }

    /// @notice The W8 pattern with a random amount: approve, spend, reset.
    function w8(uint256 v) external {
        v = bound(v, 1, 1e18);
        IAccount.Operation[] memory ops = new IAccount.Operation[](3);
        ops[0] = IAccount.Operation(address(tok), 0, abi.encodeWithSignature("approve(address,uint256)", address(spender), v), 0);
        ops[1] = IAccount.Operation(address(spender), 0, abi.encodeCall(Spender.pull, (tok, account, v / 2)), 0);
        ops[2] = IAccount.Operation(address(tok), 0, abi.encodeWithSignature("approve(address,uint256)", address(spender), 0), 0);
        _run(ops, 0);
    }

    function _run(IAccount.Operation[] memory ops, uint32 gasLimit) internal {
        uint256 g = gasLimit == 0 ? 5_000_000 : bound(gasLimit, 50_000, 5_000_000);
        uint256 s0 = IAccount(account).state();
        uint256 e0 = account.balance;
        vm.prank(_owner());
        (bool ok,) = account.call{gas: g}(abi.encodeWithSelector(ERC6551PAccount.executeBatch.selector, ops));
        uint256 s1 = IAccount(account).state();
        if (ok) {
            batches++;
            if (s1 == s0) stateStuck = true;
        } else if (s1 != s0) {
            stateMovedWithoutBatch = true;
        }
        if (!ok && account.balance < e0) ethLeftWithoutBatch = true;
        lastState = s1;
    }

    /// @notice A non-owner tries to call the account.
    function intruder(address who) external {
        if (who == _owner()) return;
        uint256 s0 = IAccount(account).state();
        vm.prank(who);
        (bool ok,) = account.call(abi.encodeWithSelector(0x51945447, who, uint256(1), bytes(""), uint8(0)));
        if (ok || IAccount(account).state() != s0) stateMovedWithoutBatch = true;
    }

    /// @notice The NFT changes hands (a sale).
    function sell(uint256 who) external {
        address to = owners[who % owners.length];
        address from = _owner();
        if (to == from) return;
        vm.prank(from);
        coll.transferFrom(from, to, 1);
    }

    /// @notice Anyone deposits; deposits never change state().
    function deposit(uint96 v) external {
        uint256 s0 = IAccount(account).state();
        vm.deal(account, account.balance + v);
        tok.mint(account, v);
        if (IAccount(account).state() != s0) stateMovedWithoutBatch = true;
    }
}

/// @notice The account invariants (I-1, I-2, I-3, I-4 for the modeled surfaces, I-5, I-6):
///         after any sequence of random batches, sales, intruders and deposits, no modeled grant of the account
///         exists at rest, the account approved no NFT and made no NFT operator, state() changed in every successful
///         batch and nowhere else.
contract AccountInvariantTest is ERC6551PBase {
    AccountHandler h;
    address acct;
    TNft coll;

    function setUp() public {
        vm.chainId(31337);
        _etchCanonical();
        JournalLog j = new JournalLog();
        ERC6551PAccount impl_ = new ERC6551PAccount(address(j));
        coll = new TNft();
        coll.mint(alice, 1);
        acct = IERC6551Registry(REGISTRY).createAccount(address(impl_), bytes32(0), block.chainid, address(coll), 1);
        address[] memory owners_ = new address[](3);
        owners_[0] = alice;
        owners_[1] = bob;
        owners_[2] = solver;
        h = new AccountHandler(acct, coll, owners_);
        targetContract(address(h));
    }

    /// @dev I-2: no modeled grant made by a batch at rest, on any spender, on any surface.
    function invariant_I2_noStandingGrant() public view {
        for (uint256 i; i < h.spenderCount(); i++) {
            address s = h.spenders(i);
            assertEq(h.tok().allowance(acct, s), 0, "ERC-20 allowance");
            assertFalse(h.t1155().isApprovedForAll(acct, s), "ERC-1155 operator");
            assertEq(h.t6909().allowance(acct, s, 1), 0, "ERC-6909 allowance");
            assertFalse(h.t6909().isOperator(acct, s), "ERC-6909 operator");
            assertEq(h.cas().allowance(acct, s), 0, "compare-and-set allowance");
            assertFalse(h.t777().isOperatorFor(s, acct), "ERC-777 operator");
            (uint160 amount, uint48 exp,) = h.p2().allowance(acct, address(h.tok()), s);
            assertTrue(amount == 0 || exp < block.timestamp, "Permit2 live allowance");
            assertFalse(h.nft().isApprovedForAll(acct, s), "NFT operator");
            assertEq(h.t404().allowance(acct, s), 0, "ERC-404 allowance");
            assertFalse(h.t404().isApprovedForAll(acct, s), "ERC-404 operator");
        }
        assertEq(h.nft().getApproved(1), address(0), "NFT approval");
        assertEq(h.nft().getApproved(2), address(0), "NFT approval");
    }

    /// @dev I-5 / I-6: state() moved in every successful batch and nowhere else; ETH left only in a batch.
    function invariant_I5_I6_state() public view {
        assertFalse(h.stateStuck(), "a successful batch left state() unchanged");
        assertFalse(h.stateMovedWithoutBatch(), "state() moved outside a batch, or an intruder passed");
        assertFalse(h.ethLeftWithoutBatch(), "ETH left without a successful batch");
        assertEq(IAccount(acct).state(), h.lastState());
    }

    /// @dev The run is not vacuous: batches (W8 and grant-free ones) succeeded.
    function afterInvariant() public view {
        assertGt(h.batches(), 0, "no batch succeeded");
    }

    /// @dev I-1, I-3.
    function invariant_I1_I3_ownerAndSignatures() public view {
        assertEq(IAccount(acct).owner(), coll.ownerOf(1));
        assertEq(IAccount(acct).isValidSignature(keccak256("x"), hex"00"), bytes4(0xffffffff));
        assertEq(IAccount(acct).isValidSigner(coll.ownerOf(1), ""), bytes4(0));
        assertFalse(IAccount(acct).inBatch());
    }
}
