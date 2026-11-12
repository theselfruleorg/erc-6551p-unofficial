// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {JournalLog} from "../src/kit/JournalLog.sol";
import {ERC6551PAccount} from "../src/account/ERC6551PAccount.sol";
import {ERC6551PMarket} from "../src/sale/ERC6551PMarket.sol";
import {ERC6551PZone} from "../src/sale/ERC6551PZone.sol";
import {ISeaport16} from "../src/interfaces/ISeaport16.sol";

/// @notice The account surface the suites drive (ERC6551PAccount).
interface IAccount {
    struct Operation {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    function owner() external view returns (address);
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function state() external view returns (uint256);
    function inBatch() external view returns (bool);
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
    function executeBatch(Operation[] calldata ops) external payable returns (bytes[] memory);
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4);
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice The kit's shared test setup: the canonical ERC-6551 registry (and the other canonical code the suites read)
///         is etched at its canonical address from test/fixtures, so the suites run offline against the real registry.
///         The contract name matches the base of the first deployment, so the suites are the same files.
abstract contract ERC6551PBase is Test {
    address constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_V3 = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant GUARDIAN = 0x2FE5ccb0d7Ea195FEb87987d3573F9fcCE2b5D57;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address solver = makeAddr("solver");

    JournalLog journal;
    ERC6551PAccount accountImpl;
    ERC6551PMarket market;
    ERC6551PZone zone;
    /// @dev The account implementation of the last `_deploy()` (the CREATE2 math of the suites uses it).
    address IMPL;

    function _etchCanonical() internal {
        vm.etch(REGISTRY, vm.parseBytes(_fixture("erc6551_registry")));
        vm.etch(ACCOUNT_V3, vm.parseBytes(_fixture("account_v3")));
        vm.etch(GUARDIAN, vm.parseBytes(_fixture("account_guardian")));
        vm.etch(CREATE2_DEPLOYER, vm.parseBytes(_fixture("create2_deployer")));
    }

    function _fixture(string memory name) internal view returns (string memory) {
        string memory raw = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/", name, ".runtime.hex"));
        return vm.replace(raw, "\n", "");
    }

    /// @dev The account implementation, the market and the zone (once per suite).
    function _deploy() internal {
        if (address(accountImpl) != address(0)) return;
        journal = new JournalLog();
        accountImpl = new ERC6551PAccount(address(journal));
        market = new ERC6551PMarket(ISeaport16(SEAPORT), address(accountImpl));
        zone = new ERC6551PZone(SEAPORT, address(accountImpl));
        IMPL = address(accountImpl);
    }

    // ---- ERC-6551 address math, offline (the registry's CREATE2, RAW salt) ----
    function _erc6551Address(address impl, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        internal
        pure
        returns (address)
    {
        bytes memory code = abi.encodePacked(
            hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
            impl,
            hex"5af43d82803e903d91602b57fd5bf3",
            abi.encode(salt, chainId, tokenContract, tokenId)
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), REGISTRY, salt, keccak256(code))))));
    }
}
