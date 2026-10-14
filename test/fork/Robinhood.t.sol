// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookFixture} from "../helpers/HookFixture.sol";
import {Workshop} from "../../src/Workshop.sol";
import {LaunchConstants} from "../../src/LaunchConstants.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Opt-in live integration: FOUNDRY_PROFILE=fork forge test -vv
/// @dev Real Robinhood IMD and Intake. PoolManager is local, per the launch floor.
contract RobinhoodForkTest is HookFixture {
    string internal constant RPC = "https://rpc.mainnet.chain.robinhood.com";
    IERC20Metadata internal imd;
    address internal keeper;

    function setUp() public {
        vm.createSelectFork(RPC);
        emit log_named_uint("Robinhood fork block", block.number);
        assertEq(block.chainid, 4663);
        assertGt(LaunchConstants.IMD.code.length, 0);
        assertGt(LaunchConstants.INTAKE.code.length, 0);
        imd = IERC20Metadata(LaunchConstants.IMD);
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);
        deploySystem(false);
        seed();
        keeper = makeAddr("fork keeper");
    }

    function _commission() internal returns (bytes32 id) {
        vm.prank(keeper);
        id = shop.commission();
    }

    function _price() internal view returns (uint256) {
        return shop.INTAKE().priceOf(shop.ACTION(), address(imd));
    }

    function _fund() internal {
        uint256 price = _price();
        deal(address(imd), address(shop), (price + price / 50) * 10);
    }

    function testFork_tradeFeesFundRealIntakeAndPayBounty() public {
        uint256 price = _price();
        assertGt(price, 0);
        uint256 required = price + price / 50;
        uint256 trade = required * 50;
        driver.swap(key, SwapParams(false, -int256(trade), TickMath.MAX_SQRT_PRICE - 1));
        assertEq(imd.balanceOf(address(shop)), required);
        assertEq(self.balanceOf(address(shop)), 0);
        assertEq(address(shop).balance, 0);
        bytes32 id = _commission();
        assertTrue(id != bytes32(0));
        assertEq(imd.balanceOf(address(shop)), 0);
        assertEq(imd.balanceOf(keeper), price / 50);
        assertEq(imd.allowance(address(shop), LaunchConstants.INTAKE), 0);
        assertEq(shop.workCount(), 1);
    }

    function testFork_fourSwapModesPayOnlyIMD() public {
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            bool exactInput = mode % 2 == 0;
            uint256 beforeShop = imd.balanceOf(address(shop));
            BalanceDelta delta = driver.swap(
                key,
                SwapParams(
                    !buy,
                    exactInput ? -int256(100 ether) : int256(100 ether),
                    buy ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
                )
            );
            uint256 fee = imd.balanceOf(address(shop)) - beforeShop;
            int256 pairDelta = delta.amount1();
            uint256 gross = buy ? uint256(-pairDelta) : uint256(pairDelta) + fee;
            assertEq(fee, gross / 50);
            assertGt(fee, 0);
            assertEq(self.balanceOf(address(shop)), 0);
            assertEq(address(shop).balance, 0);
        }
    }

    function testFork_allFourTemplatesAcceptedByRealIntake() public {
        _fund();
        bytes32 previous;
        for (uint256 i; i < 4; ++i) {
            bytes32 id = _commission();
            assertTrue(id != previous);
            previous = id;
            vm.warp(block.timestamp + 6 hours);
        }
        assertEq(shop.nextTemplate(), 0);
        assertEq(shop.workCount(), 4);
        // Intake accepting bytes is not evidence of off-chain job completion/schema acceptance.
    }

    function testFork_balanceCooldownDailyCapAndBounty() public {
        uint256 price = _price();
        deal(address(imd), address(shop), price + price / 50 - 1);
        vm.expectRevert();
        _commission();
        _fund();
        uint256 midnight = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(midnight);
        _commission();
        vm.expectRevert(abi.encodeWithSelector(Workshop.TooSoon.selector, midnight + 6 hours));
        _commission();
        for (uint256 i = 1; i < 4; ++i) {
            vm.warp(midnight + i * 6 hours);
            _commission();
        }
        assertEq(shop.commissionsToday(), 4);
        vm.expectRevert(Workshop.DailyLimit.selector);
        _commission();
        assertEq(imd.balanceOf(keeper), (price / 50) * 4);
        vm.warp(midnight + 1 days);
        _commission();
        assertEq(shop.commissionsToday(), 1);
    }

    function testFork_callbacksOnlyIntakeAndUnder150k() public {
        _fund();
        bytes32 id = _commission();
        vm.expectRevert(Workshop.NotIntake.selector);
        shop.onResult(id, keccak256("result"), "ipfs://result");
        vm.expectRevert(Workshop.NotIntake.selector);
        shop.onFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
        vm.prank(LaunchConstants.INTAKE);
        (bool delivered,) = address(shop).call{gas: 149_999}(
            abi.encodeCall(Workshop.onResult, (id, keccak256("result"), "ipfs://result"))
        );
        assertTrue(delivered);
        vm.warp(block.timestamp + 6 hours);
        id = _commission();
        vm.prank(LaunchConstants.INTAKE);
        shop.onFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
        (,,,,,, Workshop.State state) = shop.works(1);
        assertEq(uint8(state), uint8(Workshop.State.Failed));
    }
}
