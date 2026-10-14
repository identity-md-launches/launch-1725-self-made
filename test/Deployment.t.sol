// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {MineSelfHook} from "../script/MineSelfHook.s.sol";
import {SelfHook} from "../src/SelfHook.sol";
import {SelfToken} from "../src/SelfToken.sol";
import {Workshop} from "../src/Workshop.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DeploymentTest is Test {
    function test_offlineMinerUsesFactoryAndActualConstructorArguments() public {
        SelfToken token = new SelfToken();
        Workshop shop = new Workshop();
        // An empty-chain constructor must work before external contracts are available.
        IPoolManager manager = IPoolManager(makeAddr("manager supplied by launch"));
        MineSelfHook miner = new MineSelfHook();
        (bytes32 salt, address predicted,) =
            miner.run(address(this), manager, address(token), address(shop), 0, 200_000);
        SelfHook hook = new SelfHook{salt: salt}(manager, address(token), address(shop));
        assertEq(address(hook), predicted);
        assertEq(HookFlags.flagsOf(predicted), 0x20cc);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(hook.workshop(), address(shop));
        _noEscapeHatches(address(hook));
        _noEscapeHatches(address(shop));
        _noAdmin(address(hook));
        _noAdmin(address(shop));
    }

    function test_minerRangeChecks() public {
        MineSelfHook miner = new MineSelfHook();
        IPoolManager manager = IPoolManager(makeAddr("manager"));
        address token = address(new SelfToken());
        address shop = address(new Workshop());
        vm.expectRevert(MineSelfHook.NoSaltInRange.selector);
        miner.run(address(this), manager, token, shop, 0, 0);
        vm.expectRevert(MineSelfHook.InvalidRange.selector);
        miner.run(address(this), manager, token, shop, type(uint256).max, 2);
    }

    function _noEscapeHatches(address target) private view {
        bytes memory runtime = target.code;
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function _noAdmin(address target) private {
        string[10] memory signatures = [
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "pause()",
            "setIntake(address)",
            "withdraw(address,uint256)",
            "setPrice(uint256)",
            "setWorkshop(address)",
            "setFee(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = target.call(abi.encodeWithSignature(signatures[i], address(this), 1));
            assertFalse(ok, signatures[i]);
        }
    }
}
