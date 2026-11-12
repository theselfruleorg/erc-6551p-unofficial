// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ITransferSafeAccount} from "../interfaces/ITransferSafe.sol";

/// @title ERC6551PAccount — the transfer-safe ERC-6551 account (ERC-6551P).
/// @notice An ERC-1167 clone made by the canonical ERC-6551 registry inside the mint. Only the NFT's current owner
///         can make it call, CALL only, and the owner is checked again after every leg. No modeled grant made or
///         raised by a batch outlives the batch (the grant tables below are read before and after the legs); the
///         account never approves an NFT to a nonzero address and never makes an NFT operator (only a proven
///         ERC-1155 gets an operator, reset in the same batch); a fixed list of selectors and targets is refused at
///         any decoded depth. It validates no signature and has no valid signer, no executor, override, permission,
///         lock, module, 4337 entry point, DELEGATECALL, CREATE or upgrade path. `state()` changes at the start of
///         every batch. No owner, no initializer, no storage but `_state`.
/// @dev The tables are code constants (fixed at deploy). Known self-call wrappers (`multicall` ×3, BoringBatchable
///      `batch`) are decoded recursively, each inner call a leg on the same target; a grant call or a wrapper must be
///      canonically ABI-encoded (`BadEncoding`). A read of an untrusted target is a STATICCALL with READ_CAP gas
///      after a `ReadGas` guard, with a bounded copy; a read that fails fails the batch. JOURNAL is the JournalLog:
///      a `readyToSell` leg may be followed only by `JOURNAL.log(bytes)` legs with no value (a journal entry can
///      describe the batch).
contract ERC6551PAccount is ITransferSafeAccount {
    // ---------------------------------------------------------------- environment
    /// @notice The JournalLog: the only target a leg after `readyToSell` may call.
    address public immutable JOURNAL;

    // ---------------------------------------------------------------- gas and caps
    /// @notice The gas each read of an untrusted target gets (a STATICCALL; the whole cap is guaranteed).
    uint256 public constant READ_CAP = 50_000;
    /// @notice The most grant tuples one batch may carry.
    uint256 public constant MAX_TUPLES = 64;
    uint256 internal constant READ_GUARD = READ_CAP * 64 / 63 + 5_000;
    uint256 internal constant OWNER_RESERVE = 15_000; // one owner() re-check after a leg
    uint256 internal constant FINAL_RESERVE = 40_000; // the comparison loop, the flag, the return

    /// @dev Transient: the batch flag (also `inBatch()`).
    bytes32 internal constant BATCH_SLOT = keccak256("erc6551p.account.batch");

    // ---------------------------------------------------------------- selectors
    bytes4 internal constant APPROVE = 0x095ea7b3; // approve(address,uint256) — ERC-20, ERC-721, hybrids
    bytes4 internal constant INCREASE_ALLOWANCE = 0x39509351;
    bytes4 internal constant APPROVE_AND_CALL = 0x3177029f; // ERC-1363 approveAndCall(address,uint256)
    bytes4 internal constant APPROVE_AND_CALL_DATA = 0xcae9ca51; // approveAndCall(address,uint256,bytes)
    bytes4 internal constant SET_APPROVAL_FOR_ALL = 0xa22cb465;
    bytes4 internal constant APPROVE3 = 0x426a8493; // approve(address,uint256,uint256): ERC-6909 or compare-and-set
    bytes4 internal constant SET_OPERATOR = 0x558a7297; // ERC-6909 setOperator(address,bool)
    bytes4 internal constant INCREASE_APPROVAL = 0xd73dd623;
    bytes4 internal constant DECREASE_ALLOWANCE = 0xa457c2d7;
    bytes4 internal constant DECREASE_APPROVAL = 0x66188463;
    bytes4 internal constant TEMPORARY_APPROVE = 0x42232a4c; // ERC-7674 temporaryApprove(address,uint256): transient
    bytes4 internal constant DS_APPROVE = 0xdaea85c5; // DSToken (Maker) approve(address): allowance = max
    bytes4 internal constant AUTHORIZE_OPERATOR = 0x959b8c3f; // ERC-777
    bytes4 internal constant REVOKE_OPERATOR = 0xfad8b32a; // ERC-777
    bytes4 internal constant PERMIT2_APPROVE = 0x87517c45; // approve(address,address,uint160,uint48)
    bytes4 internal constant APPROVE_DELEGATION = 0xc04a8a10; // Aave debt token
    bytes4 internal constant SET_AUTHORIZATION = 0xeecea000; // Morpho
    bytes4 internal constant ALLOW = 0x110496e5; // Compound III

    bytes4 internal constant MULTICALL = 0xac9650d8; // multicall(bytes[])
    bytes4 internal constant MULTICALL_DEADLINE = 0x5ae401dc; // multicall(uint256,bytes[])
    bytes4 internal constant MULTICALL_HASH = 0x1f0464d1; // multicall(bytes32,bytes[])
    bytes4 internal constant BATCH = 0xd2423b51; // BoringBatchable batch(bytes[],bool)

    bytes4 internal constant READY_TO_SELL = 0x4b8f6ae4; // readyToSell(uint256)
    bytes4 internal constant JOURNAL_LOG = 0x0be77f56; // log(bytes)

    // read-back getters
    bytes4 internal constant ALLOWANCE2 = 0xdd62ed3e; // allowance(address,address)
    bytes4 internal constant ALLOWANCE3 = 0x598af9e7; // allowance(address,address,uint256)
    bytes4 internal constant PERMIT2_ALLOWANCE = 0x927da105; // allowance(address,address,address)
    bytes4 internal constant IS_APPROVED_FOR_ALL = 0xe985e9c5;
    bytes4 internal constant IS_OPERATOR = 0xb6363cf2; // ERC-6909 isOperator(owner, spender)
    bytes4 internal constant IS_OPERATOR_FOR = 0xd95b6371; // ERC-777 isOperatorFor(operator, holder)
    bytes4 internal constant BORROW_ALLOWANCE = 0x6bd76d24;
    bytes4 internal constant IS_AUTHORIZED = 0x65e4ad9e;
    bytes4 internal constant IS_ALLOWED = 0xa1654379;
    bytes4 internal constant GET_APPROVED = 0x081812fc;
    bytes4 internal constant SUPPORTS_INTERFACE = 0x01ffc9a7;
    bytes4 internal constant IID_ERC721 = 0x80ac58cd;
    bytes4 internal constant IID_ERC1155 = 0xd9b67a26;
    bytes4 internal constant IID_ERC5006 = 0xc26d96cc; // ERC-1155 user records: an operator can make one

    // ---------------------------------------------------------------- tuple kinds
    uint8 internal constant K_ALLOW2 = 1; // allowance(account, a)
    uint8 internal constant K_EITHER = 2; // allowance(account, a, id) and/or allowance(account, a)
    uint8 internal constant K_FOR_ALL = 3; // isApprovedForAll(account, a)
    uint8 internal constant K_OPERATOR = 4; // isOperator(account, a)
    uint8 internal constant K_777 = 5; // isOperatorFor(a, account)
    uint8 internal constant K_PERMIT2 = 6; // allowance(account, token, a) → amount while not expired
    uint8 internal constant K_BORROW = 7; // borrowAllowance(account, a)
    uint8 internal constant K_AUTHORIZED = 8; // isAuthorized(account, a)
    uint8 internal constant K_ALLOWED = 9; // isAllowed(account, a)

    struct Tuple {
        uint8 kind;
        address target;
        address who;
        uint256 arg; // the ERC-6909 id, or the Permit2 token
        uint256 leg;
        uint256 pre; // K_EITHER: the 3-argument read
        uint256 pre2; // K_EITHER: the 2-argument read; K_PERMIT2: the expiration
        uint8 have; // K_EITHER: bit 0 = 3-argument read succeeded, bit 1 = 2-argument read succeeded
    }

    struct Ctx {
        Tuple[] t;
        uint256 n;
        uint256 postReads;
        address tokenContract;
    }

    struct Operation {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    error NotOwner();
    error Reentered();
    error SelfCall();
    error OperationNotSupported();
    error ReadyNotLast();
    error Refused(address target, bytes4 selector);
    error BadEncoding();
    error TooManyGrants();
    error ReadGas();
    error ReadFailed(address target);
    error GasReserve();
    error OwnerChanged();
    error StandingGrant(uint256 leg, address target, address who);
    error OwnershipCycle();

    uint256 internal _state;

    constructor(address journal) {
        JOURNAL = journal;
    }

    // ---------------------------------------------------------------- ERC-6551
    receive() external payable {}

    /// @notice (chainId, tokenContract, tokenId) from the clone's footer.
    function token() public view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(address(), p, 0x4d, 0x60)
            chainId := mload(p)
            tokenContract := and(mload(add(p, 0x20)), 0xffffffffffffffffffffffffffffffffffffffff)
            tokenId := mload(add(p, 0x40))
        }
    }

    /// @notice The NFT's owner; address(0) on another chain or while `ownerOf` reverts (inside the mint).
    function owner() public view returns (address o) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x6352211e))
            mstore(add(p, 4), tokenId)
            if staticcall(gas(), tokenContract, p, 36, 0, 0) {
                if eq(returndatasize(), 32) {
                    returndatacopy(p, 0, 32)
                    o := and(mload(p), 0xffffffffffffffffffffffffffffffffffffffff)
                }
            }
        }
    }

    function state() external view returns (uint256) {
        return _state;
    }

    /// @notice True while a batch of this account runs.
    function inBatch() public view returns (bool b) {
        bytes32 s = BATCH_SLOT;
        assembly ("memory-safe") {
            b := tload(s)
        }
    }

    /// @notice No address is a valid signer: the owner acts by calling `execute`.
    function isValidSigner(address, bytes calldata) external pure returns (bytes4) {
        return bytes4(0);
    }

    /// @notice The account validates no signature (ERC-1271 always fails).
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 // ERC-165
            || id == 0x6faff5f1 // IERC6551Account
            || id == 0x51945447 // IERC6551Executable
            || id == 0x150b7a02 // IERC721Receiver
            || id == 0x4e2312e0 // IERC1155Receiver
            || id == type(ITransferSafeAccount).interfaceId;
    }

    /// @notice Accepts an ERC-721, except this account's own NFT (a cycle).
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        (uint256 chainId, address tokenContract, uint256 ownId) = token();
        if (msg.sender == tokenContract && tokenId == ownId && chainId == block.chainid) revert OwnershipCycle();
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xbc197c81;
    }

    // ---------------------------------------------------------------- execute
    /// @notice One leg. Returns `abi.encode(bytes result)` as Tokenbound AccountV3.
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        address o = _enter();
        Ctx memory c = _ctx();
        _checkLeg(c, to, data, operation, 0); // a lone readyToSell is its own last leg
        _preRead(c);
        uint256 reserve = _reserve(c, 1);
        result = _call(o, to, value, data, reserve);
        _postCheck(c);
        _exit();
    }

    /// @notice Legs in order; returns each leg's result.
    function executeBatch(Operation[] calldata ops) external payable returns (bytes[] memory results) {
        address o = _enter();
        Ctx memory c = _ctx();
        uint256 n = ops.length;
        bool ready;
        for (uint256 i; i < n; i++) {
            Operation calldata op = ops[i];
            if (ready) {
                if (op.to != JOURNAL || op.value != 0 || op.data.length < 4 || bytes4(op.data[:4]) != JOURNAL_LOG) {
                    revert ReadyNotLast();
                }
            }
            _checkLeg(c, op.to, op.data, op.operation, i);
            if (_isReady(c, op.to, op.data)) ready = true;
        }
        _preRead(c);
        results = new bytes[](n);
        for (uint256 i; i < n; i++) {
            Operation calldata op = ops[i];
            results[i] = _call(o, op.to, op.value, op.data, _reserve(c, n - i));
        }
        _postCheck(c);
        _exit();
    }

    // ---------------------------------------------------------------- the batch steps
    /// @dev Steps 1–3: the owner, the flag, the state hash.
    function _enter() internal returns (address o) {
        o = owner();
        if (o == address(0) || msg.sender != o) revert NotOwner();
        bytes32 s = BATCH_SLOT;
        bool busy;
        assembly ("memory-safe") {
            busy := tload(s)
        }
        if (busy) revert Reentered();
        assembly ("memory-safe") {
            tstore(s, 1)
        }
        _state = uint256(keccak256(abi.encode(_state, msg.data)));
    }

    function _exit() internal {
        bytes32 s = BATCH_SLOT;
        assembly ("memory-safe") {
            tstore(s, 0)
        }
    }

    function _ctx() internal view returns (Ctx memory c) {
        c.t = new Tuple[](MAX_TUPLES);
        (, c.tokenContract,) = token();
    }

    function _isReady(Ctx memory c, address to, bytes calldata data) internal pure returns (bool) {
        return to == c.tokenContract && data.length >= 4 && bytes4(data[:4]) == READY_TO_SELL;
    }

    /// @dev Step 6: one leg with all gas but the reserve; then the owner must be unchanged.
    function _call(address o, address to, uint256 value, bytes calldata data, uint256 reserve)
        internal
        returns (bytes memory ret)
    {
        uint256 g = gasleft();
        if (g <= reserve + 10_000) revert GasReserve();
        bool ok;
        (ok, ret) = to.call{value: value, gas: g - reserve - 10_000}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (owner() != o) revert OwnerChanged();
    }

    /// @dev The gas the remaining owner re-checks, every post-read and the end of the batch need.
    function _reserve(Ctx memory c, uint256 legsLeft) internal pure returns (uint256) {
        return c.postReads * READ_GUARD + legsLeft * OWNER_RESERVE + FINAL_RESERVE;
    }

    // ---------------------------------------------------------------- step 4: the leg rules and the decoder
    function _checkLeg(Ctx memory c, address to, bytes calldata data, uint8 operation, uint256 leg) internal view {
        if (operation != 0) revert OperationNotSupported();
        if (to == address(this)) revert SelfCall();
        if (_refusedTarget(to)) revert Refused(to, data.length >= 4 ? bytes4(data[:4]) : bytes4(0));
        _scan(c, to, data, leg, true);
    }

    /// @dev One call on `to` (a leg, or an inner call of a known wrapper on the same target).
    function _scan(Ctx memory c, address to, bytes calldata data, uint256 leg, bool top) internal view {
        if (data.length < 4) return;
        bytes4 sel = bytes4(data[:4]);
        if (_refusedSelector(sel)) revert Refused(to, sel);
        if (!top && to == c.tokenContract && sel == READY_TO_SELL) revert ReadyNotLast();
        if (sel == MULTICALL) {
            _scanCalls(c, to, data, 4, 1, leg); // (bytes[]): head = [offset 0x20]
        } else if (sel == MULTICALL_DEADLINE || sel == MULTICALL_HASH) {
            _scanCalls(c, to, data, 36, 2, leg); // (word, bytes[]): head = [word][offset 0x40]
        } else if (sel == BATCH) {
            _bool(data, 36); // (bytes[], bool): head = [offset 0x40][bool]
            _scanCalls(c, to, data, 4, 2, leg);
        } else {
            _grant(c, to, sel, data, leg);
        }
    }

    /// @dev Decodes a canonically encoded `bytes[]` whose offset word sits at `data[at]` (the arguments start at 4
    ///      and have `headWords` head words) and scans each element. Canonical = every offset and length exactly
    ///      where Solidity's encoder puts them, and the call data ends exactly at the end of the array.
    function _scanCalls(Ctx memory c, address to, bytes calldata data, uint256 at, uint256 headWords, uint256 leg)
        internal
        view
    {
        if (_word(data, at) != headWords * 32) revert BadEncoding();
        uint256 elems = 4 + headWords * 32 + 32; // the offsets start here; each offset is relative to `elems`
        uint256 n = _word(data, elems - 32);
        if (n > (data.length - elems) / 32) revert BadEncoding();
        uint256 next = n * 32; // where the next element must start, relative to `elems`
        for (uint256 i; i < n; i++) {
            if (_word(data, elems + i * 32) != next) revert BadEncoding();
            next = _scanElement(c, to, data, elems, next, leg);
        }
        if (elems + next != data.length) revert BadEncoding();
    }

    /// @dev One `bytes` element at `elems + off`: [len][data, zero-padded to 32]. Returns where the next one starts.
    function _scanElement(Ctx memory c, address to, bytes calldata data, uint256 elems, uint256 off, uint256 leg)
        internal
        view
        returns (uint256)
    {
        uint256 p = elems + off + 32;
        uint256 len = _word(data, p - 32);
        if (len > data.length) revert BadEncoding();
        uint256 end = off + 32 + (len + 31) / 32 * 32;
        if (elems + end > data.length) revert BadEncoding();
        _scan(c, to, data[p:p + len], leg, false);
        return end;
    }

    /// @dev Step 4 for a grant selector: exact length, canonical words, then the tuples (or the refusal).
    function _grant(Ctx memory c, address to, bytes4 sel, bytes calldata data, uint256 leg) internal view {
        if (sel == APPROVE) {
            _len(data, 2);
            address a = _addr(data, 4);
            uint256 v = _word(data, 36);
            if (_nftLike(to, v)) {
                if (a != address(0)) revert Refused(to, sel);
            } else {
                _push(c, K_ALLOW2, to, a, 0, leg, 1);
            }
        } else if (
            sel == INCREASE_ALLOWANCE || sel == APPROVE_AND_CALL || sel == INCREASE_APPROVAL
                || sel == DECREASE_ALLOWANCE || sel == DECREASE_APPROVAL || sel == TEMPORARY_APPROVE
        ) {
            _len(data, 2);
            _push(c, K_ALLOW2, to, _addr(data, 4), 0, leg, 1);
        } else if (sel == DS_APPROVE) {
            _len(data, 1);
            _push(c, K_ALLOW2, to, _addr(data, 4), 0, leg, 1);
        } else if (sel == APPROVE_AND_CALL_DATA) {
            // (address, uint256, bytes): head 3 words, offset 0x60, then the bytes
            if (data.length < 4 + 128 || _word(data, 68) != 0x60) revert BadEncoding();
            uint256 len = _word(data, 100);
            if (len > data.length || data.length != 4 + 128 + (len + 31) / 32 * 32) revert BadEncoding();
            _push(c, K_ALLOW2, to, _addr(data, 4), 0, leg, 1);
        } else if (sel == SET_APPROVAL_FOR_ALL) {
            _len(data, 2);
            address a = _addr(data, 4);
            if (_bool(data, 36)) {
                if (!_proven1155(to)) revert Refused(to, sel);
                _push(c, K_FOR_ALL, to, a, 0, leg, 1);
            }
        } else if (sel == APPROVE3) {
            _len(data, 3);
            _push(c, K_EITHER, to, _addr(data, 4), _word(data, 36), leg, 2);
        } else if (sel == SET_OPERATOR) {
            _len(data, 2);
            _bool(data, 36);
            _push(c, K_OPERATOR, to, _addr(data, 4), 0, leg, 1);
        } else if (sel == AUTHORIZE_OPERATOR || sel == REVOKE_OPERATOR) {
            _len(data, 1);
            _push(c, K_777, to, _addr(data, 4), 0, leg, 1);
        } else if (sel == PERMIT2_APPROVE) {
            _len(data, 4);
            address tok = _addr(data, 4);
            address spender = _addr(data, 36);
            if (_word(data, 68) >> 160 != 0 || _word(data, 100) >> 48 != 0) revert BadEncoding();
            _push(c, K_PERMIT2, to, spender, uint256(uint160(tok)), leg, 1);
        } else if (sel == APPROVE_DELEGATION) {
            _len(data, 2);
            _push(c, K_BORROW, to, _addr(data, 4), 0, leg, 1);
        } else if (sel == SET_AUTHORIZATION) {
            _len(data, 2);
            _bool(data, 36);
            _push(c, K_AUTHORIZED, to, _addr(data, 4), 0, leg, 1);
        } else if (sel == ALLOW) {
            _len(data, 2);
            _bool(data, 36);
            _push(c, K_ALLOWED, to, _addr(data, 4), 0, leg, 1);
        }
    }

    function _push(Ctx memory c, uint8 kind, address target, address who, uint256 arg, uint256 leg, uint256 reads)
        internal
        pure
    {
        if (c.n == MAX_TUPLES) revert TooManyGrants();
        Tuple memory t = c.t[c.n++];
        t.kind = kind;
        t.target = target;
        t.who = who;
        t.arg = arg;
        t.leg = leg;
        c.postReads += reads;
    }

    // ---------------------------------------------------------------- the tables of refusals
    function _refusedSelector(bytes4 s) internal pure returns (bool) {
        return s == 0x88147732 // Seaport validate(Order[])
            || s == 0xec6cb13f // CoW setPreSignature(bytes,bool)
            || s == 0xd4d9bdcd // Safe approveHash(bytes32)
            || s == 0x5df8122f // ERC-1820 setManager(address,address)
            || s == 0x29965a1d // ERC-1820 setInterfaceImplementer(address,bytes32,address)
            || s == 0x2b9261de // v4 subscribe(uint256,address,bytes)
            || s == 0xe030565e // ERC-4907 setUser(uint256,address,uint64)
            || s == 0x883d1d5f // ERC-5006 createUserRecord(address,address,uint256,uint64,uint64)
            || s == 0xdfabc033 // ERC-404 erc721Approve(address,uint256)
            || s == 0x4d966072 // ERC-404 erc20Approve(address,uint256)
            || s == 0x8cb0a511 // ERC-3525 approve(uint256,address,uint256)
            || s == 0x55cd4e06 // ERC-3525 setApprovalForSlot(address,uint256,address,bool)
            || s == 0x30ff3140 // delegate.xyz v2 delegateAll
            || s == 0xd90e73ab // delegate.xyz v2 delegateContract
            || s == 0x003c2ba6 // delegate.xyz v2 delegateERC20
            || s == 0xb18e2bbb // delegate.xyz v2 delegateERC721
            || s == 0xab764683 // delegate.xyz v2 delegateERC1155
            || s == 0x685ee3e8 // delegate.xyz v1 delegateForAll
            || s == 0x49c95d29 // delegate.xyz v1 delegateForContract
            || s == 0x537a5c3d // delegate.xyz v1 delegateForToken
            || s == 0xa3b22fc4 // MakerDAO hope(address)
            || s == 0xfa6e671d // Balancer setRelayerApproval(address,address,bool)
            || s == 0x9f5c462a // Euler EVC setAccountOperator(address,address,bool)
            || s == 0xc14c11bf // Euler EVC setOperator(bytes19,address,uint256)
            || s == 0x1f8b5215 // Euler EVC call(address,address,uint256,bytes) (runs a self-call with the caller kept)
            || s == 0xc16ae7a4 // Euler EVC batch((address,address,uint256,bytes)[]) (the same)
            || s == 0x0b63fb62 // Maker DssCdpManager cdpAllow(uint256,address,uint256)
            || s == 0xb68f4004 // Maker DssCdpManager urnAllow(address,uint256)
            || s == 0x57e6aa36 // Superfluid setFlowrate(address,address,int96)
            || s == 0xe15536b6 // Superfluid createFlow(address,address,address,int96,bytes)
            || s == 0x7243fb93 // Superfluid grantPermissions(address,address)
            || s == 0x30885591 // Superfluid updateFlowOperatorPermissions(address,address,uint8,int96)
            || s == 0x39255d5b // Superfluid host callAgreement(address,bytes,bytes)
            || s == 0x6ad3ca7d // Superfluid host batchCall((uint32,address,bytes)[])
            || s == 0x5a6c6dbc // Superfluid GDAv1Forwarder distributeFlow(address,address,address,int96,bytes)
            || s == 0x651aeb70 // Superfluid MacroForwarder runMacro(address,bytes)
            || s == 0xddbf54fd // Venus Comptroller updateDelegate(address,bool)
            || s == 0x85b53fc8 // dYdX SoloMargin setOperators((address,bool)[])
            || s == 0xc44193c3 // CryptoPunks offerPunkForSale(uint256,uint256)
            || s == 0xbf31196f // CryptoPunks offerPunkForSaleToAddress(uint256,uint256,address)
            || s == 0x039721b1 // Tokenbound setPermissions(address[],bool[]) (keyed to the root owner: this account, across a sale)
            || s == 0x7a8f7356 // Tokenbound setOverrides(bytes4[],address[]) (the same)
            || s == 0xdd467064 // Tokenbound lock(uint256) (the same root owner: it would freeze the inner account across a sale)
            || s == 0x2d1ef5ae // ERC-8004 setAgentWallet(uint256,address,uint256,bytes) (a sale does not reset it: a seller's key would stay)
            || s == 0x3fddcf19 // ERC-8004 unsetAgentWallet(uint256) (the account signs nothing, so it could never be named again)
            || s == 0x46c02d7a // 0x v3 preSign(bytes32)
            || s == 0xea7faa61; // 0x v4 registerAllowedOrderSigner(address,bool)
    }

    function _refusedTarget(address a) internal pure returns (bool) {
        return a == 0x0000000000000068F116a894984e2DB1123eB395 // Seaport 1.6
            || a == 0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC // Seaport 1.5
            || a == 0x00000000000001ad428e4906aE43D8F9852d0dD6 // Seaport 1.4
            || a == 0x0000000000000aD24e80fd803C6ac37206a45f15 // Seaport 1.3
            || a == 0x00000000000006c7676171937C444f6BDe3D6282 // Seaport 1.2
            || a == 0x00000000006c3852cbEf3e08E8dF289169EdE581 // Seaport 1.1
            || a == 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24 // ERC-1820 registry
            || a == 0x00000000000000447e69651d841bD8D104Bed493 // delegate.xyz v2
            || a == 0x00000000000076A84feF008CDAbe6409d2FE638B // delegate.xyz v1
            || a == 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3; // MetaMask DelegationManager
    }

    // ---------------------------------------------------------------- probes (before the legs)
    /// @dev NFT-like: `getApproved(v)` answers 32 bytes, or `supportsInterface(ERC-721)` is true.
    function _nftLike(address to, uint256 v) internal view returns (bool) {
        (bool ok, uint256 len,) = _probe(to, abi.encodeWithSelector(GET_APPROVED, v));
        if (ok && len == 32) return true;
        return _supports(to, IID_ERC721) == 1;
    }

    /// @dev A proven ERC-1155: supports ERC-1155, answers false (not a failure) for ERC-721 and ERC-5006, has no
    ///      getApproved.
    function _proven1155(address to) internal view returns (bool) {
        if (_supports(to, IID_ERC1155) != 1 || _supports(to, IID_ERC721) != 0 || _supports(to, IID_ERC5006) != 0) {
            return false;
        }
        (bool ok, uint256 len,) = _probe(to, abi.encodeWithSelector(GET_APPROVED, uint256(0)));
        return !(ok && len == 32);
    }

    /// @dev 1 = true, 0 = false, 2 = no valid answer.
    function _supports(address to, bytes4 iid) internal view returns (uint256) {
        (bool ok, uint256 len, uint256 w) = _probe(to, abi.encodeWithSelector(SUPPORTS_INTERFACE, iid));
        if (!ok || len < 32) return 2;
        return w == 1 ? 1 : (w == 0 ? 0 : 2);
    }

    /// @dev A STATICCALL with READ_CAP; a call that used its whole cap fails the batch (ReadGas), so a probe is
    ///      never classified by gas.
    function _probe(address to, bytes memory cd) internal view returns (bool ok, uint256 len, uint256 w) {
        if (gasleft() < READ_GUARD) revert ReadGas();
        uint256 g0 = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(READ_CAP, to, add(cd, 32), mload(cd), 0, 0)
            len := returndatasize()
            if gt(len, 31) {
                let p := mload(0x40)
                returndatacopy(p, 0, 32)
                w := mload(p)
            }
        }
        if (!ok && g0 - gasleft() >= READ_CAP) revert ReadGas();
    }

    // ---------------------------------------------------------------- step 5 and step 7: the reads
    function _preRead(Ctx memory c) internal view {
        for (uint256 i; i < c.n; i++) {
            Tuple memory t = c.t[i];
            if (t.kind == K_EITHER) {
                (bool ok3, uint256 v3) = _tryRead(t.target, _cd(t, true));
                (bool ok2, uint256 v2) = _tryRead(t.target, _cd(t, false));
                if (!ok3 && !ok2) revert ReadFailed(t.target);
                t.have = (ok3 ? 1 : 0) | (ok2 ? 2 : 0);
                t.pre = v3;
                t.pre2 = v2;
            } else if (t.kind == K_PERMIT2) {
                (t.pre, t.pre2) = _readPermit2(t);
            } else {
                t.pre = _read(t);
            }
        }
    }

    function _postCheck(Ctx memory c) internal view {
        for (uint256 i; i < c.n; i++) {
            Tuple memory t = c.t[i];
            if (t.kind == K_EITHER) {
                // the same getters must answer before and after (a getter that starts or stops answering fails)
                (bool ok3, uint256 v3) = _tryRead(t.target, _cd(t, true));
                (bool ok2, uint256 v2) = _tryRead(t.target, _cd(t, false));
                if (ok3 != (t.have & 1 != 0) || ok2 != (t.have & 2 != 0)) revert ReadFailed(t.target);
                if ((ok3 && v3 > t.pre) || (ok2 && v2 > t.pre2)) revert StandingGrant(t.leg, t.target, t.who);
            } else if (t.kind == K_PERMIT2) {
                // a live grant may not grow, and may not last longer (same amount, later expiration)
                (uint256 amount, uint256 expiration) = _readPermit2(t);
                if (amount > t.pre || (amount != 0 && expiration > t.pre2)) {
                    revert StandingGrant(t.leg, t.target, t.who);
                }
            } else if (_read(t) > t.pre) {
                revert StandingGrant(t.leg, t.target, t.who);
            }
        }
    }

    /// @dev The value of one tuple; a failed or short read fails the batch.
    function _read(Tuple memory t) internal view returns (uint256 v) {
        bool ok;
        (ok, v) = _tryRead(t.target, _cd(t, false));
        if (!ok) revert ReadFailed(t.target);
    }

    /// @dev The live Permit2 amount and its expiration. Permit2 refuses a spend only when block.timestamp >
    ///      expiration (it stores expiration 0 as now), so an amount with expiration < now is 0.
    function _readPermit2(Tuple memory t) internal view returns (uint256 amount, uint256 expiration) {
        bytes memory cd = abi.encodeWithSelector(PERMIT2_ALLOWANCE, address(this), address(uint160(t.arg)), t.who);
        bool ok;
        (ok, amount, expiration) = _read2(t.target, cd);
        if (!ok) revert ReadFailed(t.target);
        if (expiration < block.timestamp) (amount, expiration) = (0, 0);
    }

    function _cd(Tuple memory t, bool three) internal view returns (bytes memory) {
        uint8 k = t.kind;
        if (k == K_EITHER) {
            return three
                ? abi.encodeWithSelector(ALLOWANCE3, address(this), t.who, t.arg)
                : abi.encodeWithSelector(ALLOWANCE2, address(this), t.who);
        }
        if (k == K_ALLOW2) return abi.encodeWithSelector(ALLOWANCE2, address(this), t.who);
        if (k == K_FOR_ALL) return abi.encodeWithSelector(IS_APPROVED_FOR_ALL, address(this), t.who);
        if (k == K_OPERATOR) return abi.encodeWithSelector(IS_OPERATOR, address(this), t.who);
        if (k == K_777) return abi.encodeWithSelector(IS_OPERATOR_FOR, t.who, address(this));
        if (k == K_BORROW) return abi.encodeWithSelector(BORROW_ALLOWANCE, address(this), t.who);
        if (k == K_AUTHORIZED) return abi.encodeWithSelector(IS_AUTHORIZED, address(this), t.who);
        return abi.encodeWithSelector(IS_ALLOWED, address(this), t.who);
    }

    /// @dev One word; `ok` only for a successful call that returned at least 32 bytes inside its cap.
    function _tryRead(address to, bytes memory cd) internal view returns (bool ok, uint256 v) {
        if (gasleft() < READ_GUARD) revert ReadGas();
        uint256 len;
        assembly ("memory-safe") {
            ok := staticcall(READ_CAP, to, add(cd, 32), mload(cd), 0, 0)
            len := returndatasize()
            if gt(len, 31) {
                let p := mload(0x40)
                returndatacopy(p, 0, 32)
                v := mload(p)
            }
        }
        ok = ok && len >= 32;
    }

    /// @dev Two words (the Permit2 allowance: amount, expiration; the nonce is not needed).
    function _read2(address to, bytes memory cd) internal view returns (bool ok, uint256 a, uint256 b) {
        if (gasleft() < READ_GUARD) revert ReadGas();
        uint256 len;
        assembly ("memory-safe") {
            ok := staticcall(READ_CAP, to, add(cd, 32), mload(cd), 0, 0)
            len := returndatasize()
            if gt(len, 63) {
                let p := mload(0x40)
                returndatacopy(p, 0, 64)
                a := mload(p)
                b := mload(add(p, 32))
            }
        }
        ok = ok && len >= 64;
    }

    // ---------------------------------------------------------------- calldata words
    function _word(bytes calldata data, uint256 at) internal pure returns (uint256 w) {
        if (at + 32 > data.length) revert BadEncoding();
        assembly ("memory-safe") {
            w := calldataload(add(data.offset, at))
        }
    }

    function _addr(bytes calldata data, uint256 at) internal pure returns (address) {
        uint256 w = _word(data, at);
        if (w >> 160 != 0) revert BadEncoding();
        return address(uint160(w));
    }

    function _bool(bytes calldata data, uint256 at) internal pure returns (bool) {
        uint256 w = _word(data, at);
        if (w > 1) revert BadEncoding();
        return w == 1;
    }

    /// @dev Exactly `words` static arguments after the selector.
    function _len(bytes calldata data, uint256 words) internal pure {
        if (data.length != 4 + words * 32) revert BadEncoding();
    }
}
