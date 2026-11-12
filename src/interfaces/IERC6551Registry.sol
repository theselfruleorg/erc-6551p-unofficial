// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The two functions of the canonical ERC-6551 registry
///         (0x000000006551c19487814612e58FE06813775758) that this kit uses.
interface IERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address account);

    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address account);
}
