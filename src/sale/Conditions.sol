// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC6551PAccountView, ITransferSafeCollection} from "../interfaces/ITransferSafe.sol";

/// @notice One check on the sold token's account after the transfer.
struct Condition {
    uint8 kind;
    address target;
    uint256 id;
    uint256 min;
    bytes data;
}

/// @title Conditions — the checks of the checked sale, shared by ERC6551PMarket and ERC6551PZone.
/// @notice The account is never taken from the collection: it is computed (the canonical registry, the pinned
///         ERC6551PAccount implementation, salt 0, this chain) and must be a 173-byte clone whose `token()` is the sold
///         token and whose `owner()` is the recipient. Every read of a target is a STATICCALL with COND_CAP gas after
///         a guard that leaves the whole cap (the seller can be the caller and set the gas); a failed or malformed
///         read fails the condition, and a failed condition reverts the fill.
library Conditions {
    address internal constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    uint256 internal constant COND_CAP = 60_000;
    uint256 internal constant COND_GUARD = COND_CAP * 64 / 63 + 5_000;

    uint8 internal constant ETH = 0;
    uint8 internal constant ERC20 = 1;
    uint8 internal constant ERC721 = 2;
    uint8 internal constant ERC1155 = 3;
    uint8 internal constant MINT_POSITION = 4;
    uint8 internal constant V4POSITION = 5;
    uint8 internal constant ERC6909 = 6;
    uint8 internal constant IDENTITY = 7;
    uint8 internal constant STATE = 8;
    uint8 internal constant CALLEQ = 9;
    uint8 internal constant CALLGE = 10;
    uint8 internal constant CALLLE = 11;

    error NoBuyerConditions();
    error ConditionFailed(uint256 index);
    error BadAccount();
    error CondGas();

    /// @notice The account of (collection, id): the registry's CREATE2 address with the RAW salt 0.
    function accountOf(address impl, address collection, uint256 id) internal view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
                impl,
                hex"5af43d82803e903d91602b57fd5bf3",
                abi.encode(bytes32(0), block.chainid, collection, id)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), REGISTRY, bytes32(0), initHash)))));
    }

    /// @notice Any ERC-6551 account in the registry's clone format (173 bytes, header and tail), any implementation.
    function isERC6551Account(address x) internal view returns (bool yes) {
        if (x.code.length != 173) return false;
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(x, p, 0, 45)
            let head := shr(176, mload(p))
            let tail := shr(136, mload(add(p, 30)))
            yes := and(eq(head, 0x363d3d373d3d3d363d73), eq(tail, 0x5af43d82803e903d91602b57fd5bf3))
        }
    }

    /// @notice The account `a` of (collection, id) is a real clone of the token and `recipient` owns it now.
    function checkAccount(address a, address collection, uint256 id, address recipient) internal view {
        if (a.code.length != 173) revert BadAccount();
        (uint256 chainId, address tc, uint256 tid) = IERC6551PAccountView(a).token();
        if (chainId != block.chainid || tc != collection || tid != id || IERC6551PAccountView(a).owner() != recipient) {
            revert BadAccount();
        }
    }

    /// @notice `buyer` must be non-empty; `sellerPromise` and `buyer` must all hold on `a`.
    function checkAll(
        Condition[] memory sellerPromise,
        Condition[] memory buyer,
        address a,
        address collection,
        uint256 soldId
    ) internal view {
        if (buyer.length == 0) revert NoBuyerConditions();
        for (uint256 i; i < sellerPromise.length; i++) {
            if (!holds(sellerPromise[i], a, collection, soldId)) revert ConditionFailed(i);
        }
        for (uint256 i; i < buyer.length; i++) {
            if (!holds(buyer[i], a, collection, soldId)) revert ConditionFailed(sellerPromise.length + i);
        }
    }

    function holds(Condition memory c, address a, address collection, uint256 soldId) internal view returns (bool) {
        uint8 k = c.kind;
        if (k == ETH) return a.balance >= c.min;
        if (k == ERC20) return _ge(c.target, abi.encodeWithSelector(0x70a08231, a), c.min);
        if (k == ERC721) return _nft(c.target, c.id, a);
        if (k == ERC1155 || k == ERC6909) return _ge(c.target, abi.encodeWithSelector(0x00fdd58e, a, c.id), c.min);
        if (k == MINT_POSITION) {
            (bool ok, uint256 p) = _word(collection, abi.encodeCall(ITransferSafeCollection.positionOf, (soldId)));
            return ok && p != 0 && _position(c.target, p, a, c.min, false, address(0));
        }
        if (k == V4POSITION) {
            if (c.data.length != 32) return false;
            return _position(c.target, c.id, a, c.min, true, abi.decode(c.data, (address)));
        }
        if (k == IDENTITY) return _identity(c.target, a, collection, soldId);
        if (k == STATE) {
            (bool ok, uint256 st) = _word(a, abi.encodeCall(IERC6551PAccountView.state, ()));
            return ok && st == c.min;
        }
        if (k == CALLEQ || k == CALLGE || k == CALLLE) {
            (bool ok, uint256 v, uint256 len) = _call(c.target, c.data);
            if (!ok || len != 32) return false;
            if (k == CALLEQ) return v == c.min;
            return k == CALLGE ? v >= c.min : v <= c.min;
        }
        return false;
    }

    /// @dev ownerOf(id) == a and getApproved(id) == 0.
    function _nft(address t, uint256 id, address a) private view returns (bool) {
        (bool ok, uint256 o) = _word(t, abi.encodeWithSelector(0x6352211e, id));
        if (!ok || o != uint256(uint160(a))) return false;
        (bool ok2, uint256 ap) = _word(t, abi.encodeWithSelector(0x081812fc, id));
        return ok2 && ap == 0;
    }

    /// @dev A v4 position of PositionManager `pm`: owned by `a`, not approved, no subscriber, liquidity >= min; with
    ///      `checkHook`, the position's pool hook equals the hook the buyer named (address(0) = no hook).
    function _position(address pm, uint256 p, address a, uint256 min, bool checkHook, address hook)
        private
        view
        returns (bool)
    {
        if (!_nft(pm, p, a)) return false;
        (bool ok, uint256 sub) = _word(pm, abi.encodeWithSelector(0x16a24131, p)); // subscriber
        if (!ok || sub != 0) return false;
        if (!_ge(pm, abi.encodeWithSelector(0x1efeed33, p), min)) return false; // getPositionLiquidity
        if (!checkHook) return true;
        // getPoolAndPositionInfo(p) → (PoolKey(c0, c1, fee, spacing, hooks), info): hooks is word 4
        (bool ok2, uint256 h) = _wordAt(pm, abi.encodeWithSelector(0x7ba03aad, p), 4, 192);
        return ok2 && h == uint256(uint160(hook));
    }

    /// @dev The ERC-8004 identity of the sold token: registered at mint, owned by `a`, not approved, wallet = `a`.
    function _identity(address reg, address a, address collection, uint256 soldId) private view returns (bool) {
        (bool ok, uint256 has) = _word(collection, abi.encodeCall(ITransferSafeCollection.hasIdentity, (soldId)));
        if (!ok || has != 1) return false;
        (bool ok2, uint256 agentId) = _word(collection, abi.encodeCall(ITransferSafeCollection.agentIdOf, (soldId)));
        if (!ok2 || !_nft(reg, agentId, a)) return false;
        (bool ok3, uint256 w) = _word(reg, abi.encodeWithSelector(0x00339509, agentId)); // getAgentWallet
        return ok3 && w == uint256(uint160(a));
    }

    function _ge(address t, bytes memory cd, uint256 min) private view returns (bool) {
        (bool ok, uint256 v) = _word(t, cd);
        return ok && v >= min;
    }

    function _word(address t, bytes memory cd) private view returns (bool ok, uint256 v) {
        uint256 len;
        (ok, v, len) = _call(t, cd);
        ok = ok && len >= 32;
    }

    /// @dev Word `i` of a return of at least `minLen` bytes.
    function _wordAt(address t, bytes memory cd, uint256 i, uint256 minLen) private view returns (bool ok, uint256 v) {
        if (gasleft() < COND_GUARD) revert CondGas();
        uint256 len;
        assembly ("memory-safe") {
            ok := staticcall(COND_CAP, t, add(cd, 32), mload(cd), 0, 0)
            len := returndatasize()
            if and(ok, iszero(lt(len, minLen))) {
                let q := mload(0x40)
                returndatacopy(q, mul(i, 32), 32)
                v := mload(q)
            }
        }
        ok = ok && len >= minLen;
    }

    /// @dev A STATICCALL with COND_CAP; the first word (bounded copy) and the return length.
    function _call(address t, bytes memory cd) private view returns (bool ok, uint256 v, uint256 len) {
        if (gasleft() < COND_GUARD) revert CondGas();
        assembly ("memory-safe") {
            ok := staticcall(COND_CAP, t, add(cd, 32), mload(cd), 0, 0)
            len := returndatasize()
            if gt(len, 31) {
                let q := mload(0x40)
                returndatacopy(q, 0, 32)
                v := mload(q)
            }
        }
    }
}
