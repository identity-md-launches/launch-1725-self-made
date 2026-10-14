// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookFixture} from "./helpers/HookFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SelfHook} from "../src/SelfHook.sol";
import {LaunchConstants} from "../src/LaunchConstants.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SelfHookTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    MockERC20 internal imd;
    bool internal imdIs0;

    function setUp() public virtual {
        _setup(false);
    }

    function _setup(bool pairIs0) internal {
        imdIs0 = pairIs0;
        vm.etch(LaunchConstants.IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        imd = MockERC20(LaunchConstants.IMD);
        deploySystem(pairIs0);
        seed();
    }

    function parameters(bool buy, bool exactInput, uint256 amount, bool isPartial)
        internal
        view
        returns (SwapParams memory)
    {
        bool zeroForOne = buy == imdIs0;
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            isPartial
                ? TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1))
                : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }

    function assertTrade(bool buy, bool exactInput, uint256 amount, bool isPartial) internal {
        uint256 beforeShop = imd.balanceOf(address(shop));
        uint256 beforeIMD = imd.balanceOf(address(driver));
        uint256 beforeSELF = self.balanceOf(address(driver));
        uint256 pmIMD = imd.balanceOf(address(manager));
        uint256 pmSELF = self.balanceOf(address(manager));
        BalanceDelta delta = driver.swap(key, parameters(buy, exactInput, amount, isPartial));
        int256 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
        int256 selfDelta = imdIs0 ? delta.amount1() : delta.amount0();
        uint256 fee = imd.balanceOf(address(shop)) - beforeShop;
        uint256 gross = buy ? uint256(-imdDelta) : uint256(imdDelta) + fee;
        assertEq(fee, gross / 50, "exactly 2% of gross actual IMD, rounded down");
        assertEq(imd.balanceOf(address(driver)), uint256(int256(beforeIMD) + imdDelta));
        assertEq(self.balanceOf(address(driver)), uint256(int256(beforeSELF) + selfDelta));
        assertEq(
            imd.balanceOf(address(manager)) + imd.balanceOf(address(driver)) + imd.balanceOf(address(shop)),
            pmIMD + beforeIMD + beforeShop
        );
        assertEq(self.balanceOf(address(manager)) + self.balanceOf(address(driver)), pmSELF + beforeSELF);
        assertEq(self.balanceOf(address(shop)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(self.balanceOf(address(hook)), 0);
        assertEq(address(shop).balance, 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), key.currency1), 0);
        if (buy) {
            assertLt(imdDelta, 0);
            assertGe(selfDelta, 0);
        } else {
            assertLt(selfDelta, 0);
            assertGe(imdDelta, 0);
        }
        uint256 specified = exactInput ? uint256(-(buy ? imdDelta : selfDelta)) : uint256(buy ? selfDelta : imdDelta);
        if (isPartial) assertLt(specified, amount, "isPartial fill");
        else assertEq(specified, amount, "specified amount respected");
    }

    function test_buyExactInput() public {
        assertTrade(true, true, 100 ether, false);
    }

    function test_buyExactOutput() public {
        assertTrade(true, false, 100 ether, false);
    }

    function test_sellExactInput() public {
        assertTrade(false, true, 100 ether, false);
    }

    function test_sellExactOutput() public {
        assertTrade(false, false, 100 ether, false);
    }

    function test_partialBuyExactInput() public {
        assertTrade(true, true, 1000 ether, true);
    }

    function test_partialBuyExactOutput() public {
        assertTrade(true, false, 1000 ether, true);
    }

    function test_partialSellExactInput() public {
        assertTrade(false, true, 1000 ether, true);
    }

    function test_partialSellExactOutput() public {
        assertTrade(false, false, 1000 ether, true);
    }

    function testFuzz_swapConservation(bool buy, bool exactInput, uint96 rawAmount, bool isPartial) public {
        uint256 amount = bound(uint256(rawAmount), isPartial ? 1000 ether : 100, 100_000 ether);
        assertTrade(buy, exactInput, amount, isPartial);
    }

    function test_callbacksRejectNonManagerAndQuoteRejectsPublicCaller() public {
        SwapParams memory params = parameters(true, true, 100 ether, false);
        vm.expectRevert(SelfHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, ONE);
        vm.expectRevert(SelfHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SelfHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, toBalanceDelta(0, 0), "");
        vm.expectRevert(SelfHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(SelfHook.NotSelf.selector);
        hook.quoteIMD(key, params);
    }

    function test_permissionsAndInitializationSelector() public {
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.SELF);
        assertEq(HookFlags.SELF, 0x20cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity || p.afterAddLiquidity);
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(this), key, ONE), IHooks.beforeInitialize.selector);
    }

    function test_rejectsDifferentPoolOnlyDuringInitialization() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, ONE);
        other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, ONE);
        other = key;
        other.currency0 = Currency.wrap(address(new MockERC20("other", "OTHER", 0)));
        vm.expectRevert();
        manager.initialize(other, ONE);
    }

    function test_factoryCanCollectWithZeroLiquidityAndWithdraw() public {
        driver.swap(key, parameters(true, true, 100 ether, false));
        uint256 shopBefore = imd.balanceOf(address(shop));
        BalanceDelta collect = driver.modify(key, ModifyLiquidityParams(-120_000, 120_000, 0, bytes32(0)));
        assertGe(collect.amount0(), 0);
        assertGe(collect.amount1(), 0);
        assertTrue(collect.amount0() > 0 || collect.amount1() > 0);
        driver.modify(key, ModifyLiquidityParams(-120_000, 120_000, -1_000_000 ether, bytes32(0)));
        assertEq(imd.balanceOf(address(shop)), shopBefore);
    }

    function test_freshManagerNeedsNoETHAndWorkshopNeedNotHaveIntakeCode() public {
        assertEq(address(manager).balance, 0);
        assertEq(LaunchConstants.INTAKE.code.length, 0);
        assertTrade(true, true, 100 ether, false);
    }

    function test_emptyLiquidityDoesNotTaxUnexecutedRequestedVolume() public {
        driver.modify(key, ModifyLiquidityParams(-120_000, 120_000, -1_000_000 ether, bytes32(0)));
        uint256 beforeBalance = imd.balanceOf(address(shop));
        BalanceDelta delta = driver.swap(key, parameters(true, true, 1000 ether, false));
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(imd.balanceOf(address(shop)), beforeBalance);
    }

    function test_insufficientManagerIMDDefersAndAnyoneRedeemsToWorkshop() public {
        // A large buy consumes less than the pool's output inventory but its fee exceeds
        // the manager's pre-settlement IMD balance. No artificial balance draining is needed.
        uint256 beforeIMD = imd.balanceOf(address(driver));
        BalanceDelta delta = driver.swap(key, parameters(true, true, 60_000_000 ether, false));
        uint256 spent = beforeIMD - imd.balanceOf(address(driver));
        uint256 claim = manager.balanceOf(address(hook), uint160(address(imd)));
        assertGt(claim, 0);
        assertEq(claim, spent / 50);
        assertEq(imd.balanceOf(address(shop)), 0);
        uint256 callerBefore = imd.balanceOf(address(this));
        uint256 redeemed = hook.redeemFees();
        assertEq(redeemed, claim);
        assertEq(imd.balanceOf(address(shop)), claim);
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), 0);
        assertEq(imd.balanceOf(address(this)), callerBefore);
        assertEq(hook.redeemFees(), 0);
        assertTrue(BalanceDelta.unwrap(delta) != 0);
    }

    function test_workshopTransferFailureDefersInsteadOfBlockingTrade() public {
        imd.refuse(address(shop));
        driver.swap(key, parameters(true, true, 100 ether, false));
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), 2 ether);
        imd.refuse(address(0));
        hook.redeemFees();
        assertEq(imd.balanceOf(address(shop)), 2 ether);
    }
}

contract SelfHookReverseOrderTest is SelfHookTest {
    function setUp() public override {
        _setup(true);
    }
}
