// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @dev An ERC-20 with every legacy allowance function the account models. `unchecked_` makes the decreases wrap
///      (a token without checked math, K-59). `multicall(bytes[])` and BoringBatchable `batch(bytes[],bool)` are
///      self-DELEGATECALL wrappers.
contract TToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public unchecked_;

    function setUnchecked(bool u) external {
        unchecked_ = u;
    }

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function increaseAllowance(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] += v;
        return true;
    }

    function increaseApproval(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] += v;
        return true;
    }

    function decreaseAllowance(address s, uint256 v) public returns (bool) {
        if (unchecked_) {
            unchecked {
                allowance[msg.sender][s] -= v;
            }
        } else {
            allowance[msg.sender][s] -= v;
        }
        return true;
    }

    function decreaseApproval(address s, uint256 v) external returns (bool) {
        return decreaseAllowance(s, v);
    }

    function approveAndCall(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function approveAndCall(address s, uint256 v, bytes calldata) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external virtual returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }

    function multicall(bytes[] calldata data) external returns (bytes[] memory) {
        return _multicall(data);
    }

    function multicall(uint256, bytes[] calldata data) external returns (bytes[] memory) {
        return _multicall(data);
    }

    function multicall(bytes32, bytes[] calldata data) external returns (bytes[] memory) {
        return _multicall(data);
    }

    function _multicall(bytes[] calldata data) internal returns (bytes[] memory r) {
        r = new bytes[](data.length);
        for (uint256 i; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            require(ok, "multicall");
            r[i] = ret;
        }
    }

    function batch(bytes[] calldata calls, bool revertOnFail) external {
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = address(this).delegatecall(calls[i]);
            require(ok || !revertOnFail, "batch");
        }
    }
}

/// @dev Pulls `token` from `from` (the W8 spend).
contract Spender {
    function pull(TToken token, address from, uint256 v) external {
        token.transferFrom(from, address(this), v);
    }
}

contract TNft is ERC721 {
    constructor() ERC721("T", "T") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract T1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 v) external {
        _mint(to, id, v, "");
    }
}

/// @dev An ERC-1155 that also claims ERC-5006 user records (an operator could make one).
contract T5006 is T1155 {
    function supportsInterface(bytes4 i) public view override returns (bool) {
        return i == 0xc26d96cc || super.supportsInterface(i);
    }
}

/// @dev Claims ERC-1155 and hides ERC-721 behind `getApproved` (refused by the allow-list).
contract TFake1155 is T1155 {
    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }
}

/// @dev Minimal ERC-6909.
contract T6909 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;
    mapping(address => mapping(address => bool)) public isOperator;

    function mint(address to, uint256 id, uint256 v) external {
        balanceOf[to][id] += v;
    }

    function approve(address s, uint256 id, uint256 v) external returns (bool) {
        allowance[msg.sender][s][id] = v;
        return true;
    }

    function setOperator(address s, bool b) external returns (bool) {
        isOperator[msg.sender][s] = b;
        return true;
    }
}

/// @dev A compare-and-set ERC-20: `approve(spender, expected, new)` (shares the ERC-6909 selector).
contract TCas {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address s, uint256 expected, uint256 v) external returns (bool) {
        require(allowance[msg.sender][s] == expected, "cas");
        allowance[msg.sender][s] = v;
        return true;
    }
}

/// @dev ERC-777 operators.
contract T777 {
    mapping(address => mapping(address => bool)) internal _op; // holder → operator

    function authorizeOperator(address o) external {
        _op[msg.sender][o] = true;
    }

    function revokeOperator(address o) external {
        _op[msg.sender][o] = false;
    }

    function isOperatorFor(address o, address holder) external view returns (bool) {
        return _op[holder][o];
    }
}

/// @dev A Pandora-style ERC-404 hybrid: `approve(spender, valueOrId)`, a public `getApproved`, `supportsInterface`
///      false for ERC-721 and ERC-1155.
contract T404 {
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function approve(address s, uint256 v) external returns (bool) {
        if (v > type(uint256).max / 2) getApproved[v] = s;
        else allowance[msg.sender][s] = v;
        return true;
    }

    function setApprovalForAll(address o, bool b) external {
        isApprovedForAll[msg.sender][o] = b;
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x01ffc9a7;
    }
}

/// @dev Permit2 allowance semantics (Uniswap/permit2 Allowance.sol:40: expiration 0 is stored as now).
contract TPermit2 {
    struct A {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => A))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        A storage a = allowance[msg.sender][token][spender];
        a.amount = amount;
        a.expiration = expiration == 0 ? uint48(block.timestamp) : expiration;
    }

    struct TokenSpenderPair {
        address token;
        address spender;
    }

    function lockdown(TokenSpenderPair[] calldata pairs) external {
        for (uint256 i; i < pairs.length; i++) {
            allowance[msg.sender][pairs[i].token][pairs[i].spender].amount = 0;
        }
    }
}

/// @dev A token that lies: `allowance` is always 0 (R-1: the account cannot see the grant).
contract TLiar {
    mapping(address => mapping(address => uint256)) internal _a;

    function approve(address s, uint256 v) external returns (bool) {
        _a[msg.sender][s] = v;
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function realAllowance(address o, address s) external view returns (uint256) {
        return _a[o][s];
    }
}

/// @dev `allowance` burns all gas it gets (A-16, A-31), or reverts.
contract TGasBurner {
    bool public revertInstead;

    function setRevert(bool r) external {
        revertInstead = r;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external view returns (uint256) {
        if (revertInstead) revert("no");
        while (true) {}
        return 0;
    }
}

/// @dev A target whose call makes the owner contract call the account again (K-26), or moves the NFT (K-27).
contract CallbackTarget {
    function poke(address ownerWallet) external {
        OwnerWallet(payable(ownerWallet)).onPoke();
    }
}

interface IExec {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

/// @dev An NFT owner that is a contract: it calls the account, and on a poke it runs `hook` (re-enter, sell, …).
contract OwnerWallet {
    address public account;
    address public hookTarget;
    bytes public hookData;

    function setAccount(address a) external {
        account = a;
    }

    function setHook(address t, bytes calldata d) external {
        hookTarget = t;
        hookData = d;
    }

    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        return IExec(account).execute(to, value, data, 0);
    }

    function call_(address to, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function onPoke() external {
        (bool ok, bytes memory r) = hookTarget.call(hookData);
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {}
}
