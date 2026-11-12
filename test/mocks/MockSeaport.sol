// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    OrderParameters,
    ItemType,
    OrderType,
    ZoneParameters,
    SpentItem,
    ReceivedItem
} from "../../src/interfaces/ISeaport16.sol";

interface IZone {
    function authorizeOrder(ZoneParameters calldata) external returns (bytes4);
    function validateOrder(ZoneParameters calldata) external returns (bytes4);
}

/// @dev A Seaport 1.6 stand-in for `fulfillAdvancedOrder` in the order of seaport-core OrderFulfiller.sol: for a
///      restricted order (types 2–3) whose zone is not the caller, `authorizeOrder` (:135); the offer items to
///      `recipient` (:405-427; ERC-721 by `transferFrom` from the offerer — this contract is the "conduit"); the
///      consideration from the caller (:478-484); all remaining ETH back to the caller (:491-499); `validateOrder`
///      (:159). No signatures, no amounts over time, no criteria. Storage-free: it is etched at the Seaport address.
contract MockSeaport {
    function information() external view returns (string memory, bytes32, address) {
        return ("1.6", bytes32(0), address(this));
    }

    function fulfillAdvancedOrder(AdvancedOrder calldata o, CriteriaResolver[] calldata, bytes32, address recipient)
        external
        payable
        returns (bool)
    {
        OrderParameters calldata p = o.parameters;
        if (recipient == address(0)) recipient = msg.sender;
        ZoneParameters memory z = _zp(o, msg.sender);
        bool restricted = (p.orderType == OrderType.FULL_RESTRICTED || p.orderType == OrderType.PARTIAL_RESTRICTED)
            && msg.sender != p.zone;
        if (restricted) {
            require(IZone(p.zone).authorizeOrder(z) == 0x01e4d72a, "authorize");
        }
        for (uint256 i; i < p.offer.length; i++) {
            require(p.offer[i].itemType == ItemType.ERC721, "mock: ERC-721 offers only");
            IERC721(p.offer[i].token).transferFrom(p.offerer, recipient, p.offer[i].identifierOrCriteria);
        }
        for (uint256 i; i < p.consideration.length; i++) {
            if (p.consideration[i].itemType == ItemType.NATIVE) {
                (bool ok,) = p.consideration[i].recipient.call{value: p.consideration[i].startAmount}("");
                require(ok, "native");
            } else if (p.consideration[i].itemType == ItemType.ERC20) {
                require(
                    IERC20(p.consideration[i].token).transferFrom(
                        msg.sender, p.consideration[i].recipient, p.consideration[i].startAmount
                    ),
                    "erc20"
                );
            } else {
                // an NFT consideration item (an offer order): from the fulfiller
                IERC721(p.consideration[i].token).transferFrom(
                    msg.sender, p.consideration[i].recipient, p.consideration[i].identifierOrCriteria
                );
            }
        }
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund");
        }
        if (restricted) {
            require(IZone(p.zone).validateOrder(z) == 0x17b1f942, "validate");
        }
        return true;
    }

    function _zp(AdvancedOrder calldata o, address fulfiller) private pure returns (ZoneParameters memory z) {
        OrderParameters calldata p = o.parameters;
        z.orderHash = keccak256(abi.encode(p));
        z.fulfiller = fulfiller;
        z.offerer = p.offerer;
        z.offer = new SpentItem[](p.offer.length);
        for (uint256 i; i < p.offer.length; i++) {
            z.offer[i] = SpentItem(
                p.offer[i].itemType, p.offer[i].token, p.offer[i].identifierOrCriteria, p.offer[i].startAmount
            );
        }
        z.consideration = new ReceivedItem[](p.consideration.length);
        for (uint256 i; i < p.consideration.length; i++) {
            z.consideration[i] = ReceivedItem(
                p.consideration[i].itemType,
                p.consideration[i].token,
                p.consideration[i].identifierOrCriteria,
                p.consideration[i].startAmount,
                p.consideration[i].recipient
            );
        }
        z.extraData = o.extraData;
        z.orderHashes = new bytes32[](0);
        z.startTime = p.startTime;
        z.endTime = p.endTime;
        z.zoneHash = p.zoneHash;
    }
}
