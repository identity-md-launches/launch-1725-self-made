// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {HookDeployer} from "./helpers/HookDeployer.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {SelfHook} from "../src/SelfHook.sol";
import {Workshop} from "../src/Workshop.sol";
import {LaunchConstants} from "../src/LaunchConstants.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract SwapHandler is Test {
    PoolDriver internal driver;
    SelfHook internal hook;
    PoolKey internal key;
    MockERC20 internal imd;
    address internal shop;
    uint256 public totalFees;

    constructor(PoolDriver driver_, SelfHook hook_, PoolKey memory key_, address shop_) {
        driver = driver_;
        hook = hook_;
        key = key_;
        shop = shop_;
        imd = MockERC20(LaunchConstants.IMD);
    }

    function trade(bool buy, bool exactInput, uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e10, 1000 ether);
        bool imdIs0 = Currency.unwrap(key.currency0) == LaunchConstants.IMD;
        bool direction = buy == imdIs0;
        uint256 beforeFee = imd.balanceOf(shop);
        BalanceDelta delta = driver.swap(
            key,
            SwapParams(
                direction,
                exactInput ? -int256(amount) : int256(amount),
                direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        int256 pairDelta = imdIs0 ? delta.amount0() : delta.amount1();
        uint256 fee = imd.balanceOf(shop) - beforeFee;
        uint256 gross = buy ? uint256(-pairDelta) : uint256(pairDelta) + fee;
        assertEq(fee, gross / 50);
        totalFees += fee;
    }

    function redeem() external {
        hook.redeemFees();
    }
}

contract HookInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    MockERC20 internal imd;
    SwapHandler internal handler;

    function setUp() public {
        vm.etch(LaunchConstants.IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        imd = MockERC20(LaunchConstants.IMD);
        deploySystem(true);
        seed();
        handler = new SwapHandler(driver, hook, key, address(shop));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SwapHandler.trade.selector;
        selectors[1] = SwapHandler.redeem.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_conservationAndExactFees() public view {
        assertEq(imd.balanceOf(address(driver)) + imd.balanceOf(address(manager)) + imd.balanceOf(address(shop)), FUNDS);
        assertEq(imd.balanceOf(address(shop)), handler.totalFees());
        assertEq(self.balanceOf(address(driver)) + self.balanceOf(address(manager)), FUNDS);
        assertEq(self.totalSupply(), 1e27);
        assertEq(self.balanceOf(address(shop)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), key.currency1), 0);
    }
}

contract WorkshopHandler is Test {
    Workshop internal shop;

    constructor(Workshop shop_) {
        shop = shop_;
    }

    function advanceAndCommission(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 12 hours));
        if (shop.canCommission()) shop.commission();
    }

    function finish(uint256 rawIndex, bool success) external {
        uint256 count = shop.workCount();
        if (count == 0) return;
        uint256 index = rawIndex % count;
        (bytes32 id,,,,,, Workshop.State state) = shop.works(index);
        if (state != Workshop.State.Pending) return;
        vm.prank(LaunchConstants.INTAKE);
        if (success) shop.onResult(id, keccak256(abi.encode(index)), "ipfs://artifact");
        else shop.onFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
    }
}

contract WorkshopInvariantTest is HookDeployer {
    Workshop internal shop;
    WorkshopHandler internal handler;
    MockERC20 internal imd;
    uint256 constant PRICE = 5 ether;
    uint256 constant FUNDS = 10_000 ether;

    function setUp() public {
        vm.warp(10 days);
        vm.etch(LaunchConstants.IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        vm.etch(LaunchConstants.INTAKE, address(new MockIntake()).code);
        MockIntake(LaunchConstants.INTAKE).configure(PRICE, false, false, false);
        imd = MockERC20(LaunchConstants.IMD);
        shop = workshopFromHook();
        handler = new WorkshopHandler(shop);
        imd.mint(address(shop), FUNDS);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = WorkshopHandler.advanceAndCommission.selector;
        selectors[1] = WorkshopHandler.finish.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_onlyIntakeAndBountyCanSpend() public view {
        uint256 count = shop.workCount();
        assertEq(imd.balanceOf(LaunchConstants.INTAKE), count * PRICE);
        assertEq(imd.balanceOf(address(handler)), count * (PRICE / 50));
        assertEq(imd.balanceOf(address(shop)), FUNDS - count * (PRICE + PRICE / 50));
        assertEq(imd.allowance(address(shop), LaunchConstants.INTAKE), 0);
        assertEq(shop.nextTemplate(), count % 4);
        assertLe(shop.commissionsToday(), 4);
    }

    function invariant_cadenceAndRotation() public view {
        uint48 previous;
        uint256 day;
        uint256 daily;
        for (uint256 i; i < shop.workCount(); ++i) {
            (,,, uint48 at,, uint8 index,) = shop.works(i);
            assertEq(index, i % 4);
            if (i != 0) assertGe(at, uint256(previous) + 6 hours);
            previous = at;
            if (at / 1 days == day) {
                ++daily;
            } else {
                day = at / 1 days;
                daily = 1;
            }
            assertLe(daily, 4);
        }
    }
}
