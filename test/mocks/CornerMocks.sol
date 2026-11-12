// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {T1155} from "./AccountMocks.sol";

interface IExecAny {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

/// @dev A second owner for one leg: on receipt it tries to use the account (it is the owner for a moment), records
///      the revert selector, and sends the NFT straight back (an A → B → A round trip inside one leg).
contract Bouncer {
    address public account;
    bytes4 public seen;

    function setAccount(address a) external {
        account = a;
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        try IExecAny(account).execute(address(this), 0, "", 0) {
            seen = bytes4(0);
        } catch (bytes memory r) {
            seen = bytes4(r);
        }
        ERC721(msg.sender).transferFrom(address(this), from, tokenId);
        return 0x150b7a02;
    }
}

/// @dev A leg target that calls the account back directly (it is not the owner).
contract CallsBack {
    function go(address account) external {
        IExecAny(account).execute(address(this), 0, "", 0);
    }

    function goBatch(address account) external {
        (bool ok, bytes memory r) = account.call(abi.encodeWithSignature("executeBatch((address,uint256,bytes,uint8)[])", new bytes[](0)));
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }
}

/// @dev Accepts anything: a fallback and receive.
contract Sink {
    uint256 public hits;

    fallback() external payable {
        hits++;
    }

    receive() external payable {}
}

/// @dev An ERC-20 whose `allowance` getter can be switched to lie by anyone (R-1: a getter that changes inside the
///      batch, for example after a proxy upgrade in an earlier leg).
contract TSwitch {
    mapping(address => mapping(address => uint256)) public realAllowance;
    bool public lie;

    function setLie(bool l) external {
        lie = l;
    }

    function approve(address s, uint256 v) external returns (bool) {
        realAllowance[msg.sender][s] = v;
        return true;
    }

    function allowance(address o, address s) external view returns (uint256) {
        return lie ? 0 : realAllowance[o][s];
    }
}

/// @dev An ERC-20 whose `allowance` answers a set number of bytes: the real value in the first word, junk after.
contract TShape {
    mapping(address => mapping(address => uint256)) internal _a;
    uint256 public size = 32;

    function setSize(uint256 s) external {
        size = s;
    }

    function approve(address s, uint256 v) external returns (bool) {
        _a[msg.sender][s] = v;
        return true;
    }

    function allowance(address o, address s) external view returns (uint256) {
        uint256 v = _a[o][s];
        uint256 n = size;
        assembly {
            let p := mload(0x40)
            mstore(p, v)
            mstore(add(p, 32), not(0))
            mstore(add(p, 64), not(0))
            return(p, n)
        }
    }
}

/// @dev USDT-style: `approve` returns nothing and refuses a nonzero → nonzero change.
contract TUsdt {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external {
        require(v == 0 || allowance[msg.sender][s] == 0, "usdt");
        allowance[msg.sender][s] = v;
    }

    function transferFrom(address f, address to, uint256 v) external {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
    }
}

/// @dev Pulls a USDT-style token.
contract UsdtSpender {
    function pull(TUsdt t, address from, uint256 v) external {
        t.transferFrom(from, address(this), v);
    }
}

/// @dev An ERC-1155 that also says it is an ERC-721 (not a proven ERC-1155: no operator).
contract T1155As721 is T1155 {
    function supportsInterface(bytes4 i) public view override returns (bool) {
        return i == 0x80ac58cd || super.supportsInterface(i);
    }
}

/// @dev The three lending authorizations the account models: Aave credit delegation, Morpho, Compound III.
contract TLender {
    mapping(address => mapping(address => uint256)) public borrowAllowance;
    mapping(address => mapping(address => bool)) public isAuthorized;
    mapping(address => mapping(address => bool)) public isAllowed;

    function approveDelegation(address d, uint256 v) external {
        borrowAllowance[msg.sender][d] = v;
    }

    function setAuthorization(address a, bool b) external {
        isAuthorized[msg.sender][a] = b;
    }

    function allow(address a, bool b) external {
        isAllowed[msg.sender][a] = b;
    }
}
