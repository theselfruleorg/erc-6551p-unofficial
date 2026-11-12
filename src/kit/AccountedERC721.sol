// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC6551Registry} from "../interfaces/IERC6551Registry.sol";

/// @title AccountedERC721 — the blank kit base: an ERC-721 whose every token owns an ERC-6551 account.
/// @notice The account is created in the same call as the token (`_mintWithAccount`), at the canonical registry with
///         the RAW salt 0; `accountOf` is pure CREATE2 math (no external call). No nesting of a token of this collection in
///         an account of it: a token may not move into a clone that exists of ANY token of this contract (all salts,
///         this chain).
///         ERC-4906 events for the collection's metadata.
///         Nothing else: no traits, no art, no economics.
/// @dev The account of every MINTED id exists (it is created before the token), so the code check below is exact for
///      ids 1..totalMinted. An account of a not-yet-minted id is an empty address that no O(1) on-chain check can
///      recognise (CREATE2 cannot be inverted; a scan of the unminted ids costs ≈ 0.2k gas per id on every transfer
///      to a code-less address); a token sent there is nested in that id's account once it is minted, and that edge
///      points at an id minted LATER, so it makes no cycle. The same empty-address limit has a
///      second case with no such comfort (R-16): the clone of a MINTED id with another salt or implementation does
///      not exist until someone creates it, so an owner can send a token to its own future clone. The token then owns
///      itself and it and its account stay locked for good. Only the sender can do this (test_K92).
abstract contract AccountedERC721 is ERC721 {
    address public constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes32 public constant ACCOUNT_SALT = bytes32(0); // the RAW salt — never hash the tuple

    bytes4 private constant _IID_ERC4906 = 0x49064906;

    /// @notice ERC-4906.
    event MetadataUpdate(uint256 _tokenId);
    /// @notice ERC-4906.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    error OwnershipCycle();

    /// @notice The ERC-6551 account implementation every token's account clones (pinned by the drop).
    function accountImplementation() public view virtual returns (address);

    /// @notice The token's account: `registry.account(impl, 0, chainid, this, id)`, computed by CREATE2 math.
    function accountOf(uint256 id) public view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
                accountImplementation(),
                hex"5af43d82803e903d91602b57fd5bf3",
                abi.encode(ACCOUNT_SALT, block.chainid, address(this), id)
            )
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), ERC6551_REGISTRY, ACCOUNT_SALT, initHash))))
        );
    }

    /// @dev Creates the account, then mints the token (the `_update` checks run inside `_safeMint`).
    function _mintWithAccount(address to, uint256 id) internal returns (address account) {
        account = IERC6551Registry(ERC6551_REGISTRY).createAccount(
            accountImplementation(), ACCOUNT_SALT, block.chainid, address(this), id
        );
        _safeMint(to, id);
    }

    /// @dev No token of this contract inside an account of this contract.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        if (to != address(0) && _isOwnAccount(to)) revert OwnershipCycle();
        return super._update(to, tokenId, auth);
    }

    /// @notice True when `a` is an ERC-6551 registry clone of ANY implementation bound to a token of THIS contract on
    ///         THIS chain (any salt): anyone can create a clone of another implementation for an id, and a token
    ///         inside it could close a cycle. The clone is 173 bytes: 10-byte header ‖ impl ‖ 15-byte tail ‖ salt ‖
    ///         chainId ‖ tokenContract ‖ tokenId.
    function _isOwnAccount(address a) internal view returns (bool) {
        if (a.code.length != 173) return false;
        uint256 head;
        uint256 tail;
        uint256 chainId;
        address tokenContract;
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(a, p, 0, 173)
            head := shr(176, mload(p))
            tail := shr(136, mload(add(p, 30)))
            chainId := mload(add(p, 77))
            tokenContract := and(mload(add(p, 109)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        return head == 0x363d3d373d3d3d363d73 && tail == 0x5af43d82803e903d91602b57fd5bf3
            && tokenContract == address(this) && chainId == block.chainid;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == _IID_ERC4906 || super.supportsInterface(interfaceId);
    }
}
