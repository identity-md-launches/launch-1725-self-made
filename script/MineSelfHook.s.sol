// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SelfHook} from "../src/SelfHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline CREATE2 preparation only. No broadcast, keys, environment reads, or deployment.
contract MineSelfHook {
    error NoSaltInRange();
    error InvalidRange();

    function run(
        address factory,
        IPoolManager manager,
        address token,
        address workshop,
        uint256 start,
        uint256 attempts
    ) external pure returns (bytes32 salt, address predicted, bytes32 initCodeHash) {
        if (factory == address(0) || attempts > 1_000_000 || start > type(uint256).max - attempts) {
            revert InvalidRange();
        }
        initCodeHash = keccak256(abi.encodePacked(type(SelfHook).creationCode, abi.encode(manager, token, workshop)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))));
            if (HookFlags.matches(predicted, HookFlags.SELF)) return (salt, predicted, initCodeHash);
        }
        revert NoSaltInRange();
    }
}
