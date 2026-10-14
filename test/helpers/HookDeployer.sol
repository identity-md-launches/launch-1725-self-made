// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SelfToken} from "../../src/SelfToken.sol";
import {SelfHook} from "../../src/SelfHook.sol";
import {Workshop} from "../../src/Workshop.sol";
import {HookFlags} from "../../src/HookFlags.sol";

/// @dev The hook creates the Workshop in its constructor, so every test obtains a Workshop from a hook.
abstract contract HookDeployer is Test {
    /// @dev Mines a CREATE2 salt for the hook bits and deploys the hook, which deploys its own Workshop.
    /// Usable without a real PoolManager: the constructor only checks that the address is nonzero.
    function deployHook(IPoolManager manager_, address token_) internal returns (SelfHook deployed) {
        bytes32 initHash = keccak256(abi.encodePacked(type(SelfHook).creationCode, abi.encode(manager_, token_)));
        for (uint256 salt; salt < 300_000; ++salt) {
            address predicted = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (HookFlags.matches(predicted, HookFlags.SELF)) {
                deployed = new SelfHook{salt: bytes32(salt)}(manager_, token_);
                break;
            }
        }
        require(address(deployed) != address(0), "salt not found");
    }

    /// @dev For Workshop-only tests: a hook with a placeholder manager address, read the Workshop from it.
    function workshopFromHook() internal returns (Workshop) {
        SelfHook deployed = deployHook(IPoolManager(makeAddr("manager supplied by launch")), address(new SelfToken()));
        return Workshop(deployed.workshop());
    }
}
