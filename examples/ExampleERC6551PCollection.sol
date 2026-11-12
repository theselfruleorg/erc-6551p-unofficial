// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC6551PCollection} from "../src/kit/ERC6551PCollection.sol";
import {IERC6551PCollection} from "../src/interfaces/IERC6551P.sol";

/// @title ExampleERC6551PCollection — the smallest ERC-6551P collection (docs/erc-6551p.md).
/// @notice An EXAMPLE, not a product: anyone may mint, no supply cap, no price, no metadata. It shows the whole
///         adoption: inherit `ERC6551PCollection`, pass the ERC-6551P account implementation, the checked market and
///         the zone (all deployed once, shared by any number of collections), mint with `_mintWithAccount`, and answer
///         the `IERC6551PCollection` ERC-165 id. Every token owns an ERC-6551P account from its first block; every
///         non-owner transfer passes only through readiness or a ticket of the market or the zone.
contract ExampleERC6551PCollection is ERC6551PCollection {
    uint256 public nextId = 1;

    error ZeroAddress();

    constructor(address accountImpl_, address market_, address zone_)
        ERC721("ERC-6551P Example", "EX6551P")
        ERC6551PCollection(accountImpl_, market_, zone_)
    {
        if (accountImpl_.code.length == 0 || market_ == address(0) || zone_ == address(0)) revert ZeroAddress();
    }

    /// @notice Mints the next id to `to`; the token's account is created in the same call.
    function mint(address to) external returns (uint256 id, address account) {
        id = nextId++;
        account = _mintWithAccount(to, id);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC6551PCollection).interfaceId || super.supportsInterface(interfaceId);
    }
}
