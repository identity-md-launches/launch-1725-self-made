// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {MineSelfHook} from "../script/MineSelfHook.s.sol";
import {SelfHook} from "../src/SelfHook.sol";
import {SelfToken} from "../src/SelfToken.sol";
import {Workshop} from "../src/Workshop.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {LaunchConstants} from "../src/LaunchConstants.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract DeploymentTest is Test {
    // An empty-chain constructor must work before external contracts are available.
    IPoolManager internal manager = IPoolManager(makeAddr("manager supplied by launch"));

    function _mineAndDeploy(address token) internal returns (SelfHook hook, address predicted) {
        MineSelfHook miner = new MineSelfHook();
        bytes32 salt;
        (salt, predicted,) = miner.run(address(this), manager, token, 0, 200_000);
        hook = new SelfHook{salt: salt}(manager, token);
    }

    function test_offlineMinerUsesFactoryAndActualConstructorArguments() public {
        SelfToken token = new SelfToken();
        (SelfHook hook, address predicted) = _mineAndDeploy(address(token));
        assertEq(address(hook), predicted);
        assertEq(HookFlags.flagsOf(predicted), 0x20cc);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        address shop = hook.workshop();
        _noEscapeHatches(address(hook));
        _noEscapeHatches(shop);
        _noAdmin(address(hook));
        _noAdmin(shop);
    }

    function test_hookDeploysItsOwnWorkshopWithNoExternalCode() public {
        assertEq(LaunchConstants.IMD.code.length, 0);
        assertEq(LaunchConstants.INTAKE.code.length, 0);
        SelfToken token = new SelfToken();
        (SelfHook hook,) = _mineAndDeploy(address(token));
        address shop = hook.workshop();
        // The Workshop is a fresh contract created by the hook's first CREATE, with real Workshop code.
        assertTrue(shop != address(0));
        assertTrue(shop != address(hook));
        assertEq(shop, vm.computeCreateAddress(address(hook), 1));
        assertEq(shop.code, address(new Workshop()).code);
        assertGt(shop.code.length, 0);
        Workshop workshop = Workshop(shop);
        assertEq(address(workshop.IMD()), LaunchConstants.IMD);
        assertEq(address(workshop.INTAKE()), LaunchConstants.INTAKE);
        assertEq(workshop.ACTION(), LaunchConstants.ACTION);
        assertEq(workshop.workCount(), 0);
        assertEq(workshop.nextTemplate(), 0);
        assertEq(workshop.nextCommissionAt(), 0);
    }

    function test_eachHookDeploysADistinctWorkshop() public {
        (SelfHook first,) = _mineAndDeploy(address(new SelfToken()));
        (SelfHook second,) = _mineAndDeploy(address(new SelfToken()));
        assertTrue(first.workshop() != second.workshop());
        assertEq(first.workshop(), vm.computeCreateAddress(address(first), 1));
        assertEq(second.workshop(), vm.computeCreateAddress(address(second), 1));
    }

    function test_constructorRejectsInvalidArgumentsBeforeCreatingAWorkshop() public {
        address token = address(new SelfToken());
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(SelfHook.InvalidAddress.selector);
        new SelfHook(IPoolManager(address(0)), token);
        vm.expectRevert(SelfHook.InvalidAddress.selector);
        new SelfHook(manager, address(0));
        vm.expectRevert(SelfHook.InvalidAddress.selector);
        new SelfHook(manager, LaunchConstants.IMD);
        // A reverted construction leaves neither a hook nor a Workshop behind.
        assertEq(next.code.length, 0);
        assertEq(vm.computeCreateAddress(next, 1).code.length, 0);
    }

    function test_constructorRejectsAnAddressWithoutTheHookBits() public {
        address token = address(new SelfToken());
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(next, HookFlags.SELF));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, next));
        new SelfHook(manager, token);
        // The Workshop created before the permission check is rolled back with the construction.
        assertEq(vm.computeCreateAddress(next, 1).code.length, 0);
    }

    function test_minerRangeChecks() public {
        MineSelfHook miner = new MineSelfHook();
        address token = address(new SelfToken());
        vm.expectRevert(MineSelfHook.NoSaltInRange.selector);
        miner.run(address(this), manager, token, 0, 0);
        vm.expectRevert(MineSelfHook.InvalidRange.selector);
        miner.run(address(this), manager, token, type(uint256).max, 2);
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
