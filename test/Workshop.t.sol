// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookDeployer} from "./helpers/HookDeployer.sol";
import {Workshop} from "../src/Workshop.sol";
import {LaunchConstants} from "../src/LaunchConstants.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {WorkOrders} from "../src/WorkOrders.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

contract WorkshopTest is HookDeployer {
    Workshop internal shop;
    MockERC20 internal imd;
    MockIntake internal intake;
    address internal keeper;
    uint256 internal constant PRICE = 3 ether; // deliberately different from the live price

    event Built(bytes32 indexed requestId, uint8 indexed templateIndex, bytes32 resultHash, string uri);
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason);

    function setUp() public {
        vm.warp(10 days);
        vm.etch(LaunchConstants.IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        vm.etch(LaunchConstants.INTAKE, address(new MockIntake()).code);
        imd = MockERC20(LaunchConstants.IMD);
        intake = MockIntake(LaunchConstants.INTAKE);
        intake.configure(PRICE, false, false, false);
        // The Workshop under test is the one the hook deploys, read from hook.workshop().
        shop = workshopFromHook();
        keeper = makeAddr("permissionless keeper");
    }

    function fund(uint256 amount) internal {
        imd.mint(address(shop), amount);
    }

    function commission() internal returns (bytes32) {
        vm.prank(keeper);
        return shop.commission();
    }

    function test_dynamicPriceExactApprovalBountyAndSelectors() public {
        fund(PRICE + PRICE / 50);
        assertTrue(shop.canCommission());
        bytes32 id = commission();
        assertEq(id, bytes32(uint256(1)));
        assertEq(imd.balanceOf(address(shop)), 0);
        assertEq(imd.balanceOf(keeper), PRICE / 50);
        assertEq(imd.balanceOf(address(intake)), PRICE);
        assertEq(intake.seenAllowance(), PRICE);
        assertEq(imd.allowance(address(shop), address(intake)), 0);
        assertEq(intake.lastAction(), bytes32("job.open@job-1"));
        assertEq(intake.lastAsset(), address(imd));
        assertEq(intake.lastAmount(), PRICE);
        (address target, bytes4 selector) = intake.lastCallback();
        assertEq(target, address(shop));
        assertEq(selector, shop.onResult.selector);
        assertEq(intake.lastFailure(), shop.onFailure.selector);
        assertEq(shop.lastCommissionAt(), block.timestamp);
        assertEq(shop.commissionsToday(), 1);
    }

    function test_belowPricePlusBountyRevertsWithoutStateChanges() public {
        fund(PRICE + PRICE / 50 - 1);
        assertFalse(shop.canCommission());
        vm.expectRevert(
            abi.encodeWithSelector(Workshop.InsufficientIMD.selector, PRICE, PRICE / 50, PRICE + PRICE / 50 - 1)
        );
        commission();
        assertEq(shop.nextTemplate(), 0);
        assertEq(shop.lastCommissionAt(), 0);
        assertEq(shop.workCount(), 0);
        assertEq(imd.allowance(address(shop), address(intake)), 0);
    }

    function test_sixHourBoundary() public {
        fund(100 ether);
        commission();
        uint256 eligible = block.timestamp + 6 hours;
        vm.warp(eligible - 1);
        assertFalse(shop.canCommission());
        vm.expectRevert(abi.encodeWithSelector(Workshop.TooSoon.selector, eligible));
        commission();
        vm.warp(eligible);
        assertTrue(shop.canCommission());
        commission();
        assertEq(shop.workCount(), 2);
    }

    function test_dailyCapAndUTCRollover() public {
        fund(100 ether);
        for (uint256 i; i < 4; ++i) {
            vm.warp(10 days + i * 6 hours);
            commission();
        }
        assertEq(shop.commissionsToday(), 4);
        assertEq(shop.nextCommissionAt(), 11 days);
        vm.warp(11 days - 1);
        vm.expectRevert(Workshop.DailyLimit.selector);
        commission();
        vm.warp(11 days);
        assertEq(shop.commissionsToday(), 0);
        assertTrue(shop.canCommission());
        commission();
        assertEq(shop.commissionsToday(), 1);
        assertEq(shop.nextTemplate(), 1);
    }

    function test_midnightDoesNotResetCooldown() public {
        fund(100 ether);
        vm.warp(11 days - 1);
        commission();
        vm.warp(11 days);
        assertEq(shop.commissionsToday(), 0);
        assertFalse(shop.canCommission());
        vm.expectRevert(abi.encodeWithSelector(Workshop.TooSoon.selector, 11 days + 6 hours - 1));
        commission();
    }

    function test_rotatesExactTemplatesAndStoresCommissionIndex() public {
        fund(100 ether);
        for (uint256 i; i < 9; ++i) {
            bytes32 id = commission();
            assertEq(intake.lastBody(), shop.templateBody(uint8(i % 4)));
            assertLe(intake.lastBody().length, 16_384);
            (bytes32 stored,,,,, uint8 templateIndex, Workshop.State state) = shop.works(i);
            assertEq(stored, id);
            assertEq(templateIndex, i % 4);
            assertEq(uint8(state), uint8(Workshop.State.Pending));
            assertEq(shop.nextTemplate(), (i + 1) % 4);
            vm.warp(block.timestamp + 6 hours);
        }
        vm.expectRevert(WorkOrders.InvalidTemplate.selector);
        shop.templateBody(4);
    }

    function test_priceChangesBetweenCommissions() public {
        fund(100 ether);
        commission();
        vm.warp(block.timestamp + 6 hours);
        intake.configure(7 ether, false, false, false);
        commission();
        assertEq(imd.balanceOf(keeper), PRICE / 50 + 7 ether / 50);
        assertEq(intake.seenAllowance(), 7 ether);
    }

    function test_outOfOrderResultAuthenticatesAndStores() public {
        fund(100 ether);
        bytes32 a = commission();
        vm.warp(block.timestamp + 6 hours);
        bytes32 b = commission();
        string memory uri = "ipfs://bafy-selfmade/artifacts/video.mp4";
        bytes32 hash = keccak256("video contents");
        vm.expectEmit(true, true, false, true, address(shop));
        emit Built(b, 1, hash, uri);
        vm.prank(address(intake));
        shop.onResult(b, hash, uri);
        (, bytes32 resultHash, bytes32 uriHash,, uint48 completedAt, uint8 index, Workshop.State state) = shop.works(1);
        assertEq(resultHash, hash);
        assertEq(uriHash, keccak256(bytes(uri)));
        assertEq(completedAt, block.timestamp);
        assertEq(index, 1);
        assertEq(uint8(state), uint8(Workshop.State.Built));
        vm.prank(address(intake));
        shop.onResult(a, keccak256("meme"), "https://example.org/image.png");
        vm.expectRevert(Workshop.AlreadyCompleted.selector);
        vm.prank(address(intake));
        shop.onResult(b, hash, uri);
        vm.expectRevert(Workshop.AlreadyCompleted.selector);
        vm.prank(address(intake));
        shop.onFailure(b, 1, bytes32("body_invalid"), 0, 0, "");
    }

    function test_callbacksRejectWrongCallerAndUnknownRequests() public {
        fund(100 ether);
        bytes32 id = commission();
        vm.expectRevert(Workshop.NotIntake.selector);
        shop.onResult(id, bytes32(0), "uri");
        vm.expectRevert(Workshop.NotIntake.selector);
        shop.onFailure(id, 1, bytes32(0), 0, 0, "");
        vm.expectRevert(Workshop.UnknownRequest.selector);
        vm.prank(address(intake));
        shop.onResult(keccak256("foreign request"), bytes32(0), "uri");
        vm.expectRevert(Workshop.UnknownRequest.selector);
        vm.prank(address(intake));
        shop.onFailure(keccak256("foreign request"), 2, bytes32(0), 0, 0, "");
    }

    function test_failureAndReplayDoNotSpendOrResetClock() public {
        fund(100 ether);
        bytes32 id = commission();
        uint256 remaining = imd.balanceOf(address(shop));
        vm.expectEmit(true, false, false, true, address(shop));
        emit Failed(id, 2, bytes32("disagreed"));
        vm.prank(address(intake));
        shop.onFailure(id, 2, bytes32("disagreed"), 1, 3, "");
        assertEq(imd.balanceOf(address(shop)), remaining);
        assertEq(shop.lastCommissionAt(), block.timestamp);
        assertFalse(shop.canCommission());
        vm.expectRevert(Workshop.AlreadyCompleted.selector);
        vm.prank(address(intake));
        shop.onFailure(id, 2, bytes32("disagreed"), 1, 3, "");
        vm.expectRevert(Workshop.AlreadyCompleted.selector);
        vm.prank(address(intake));
        shop.onResult(id, bytes32(0), "late");
    }

    function test_resultWorstCaseGasUnder150k() public {
        fund(100 ether);
        bytes32 id = commission();
        bytes memory uri = new bytes(shop.MAX_URI_BYTES());
        for (uint256 i; i < uri.length; ++i) {
            uri[i] = bytes1(uint8(97));
        }
        // Cool slots so this is a separate-transaction delivery measurement.
        vm.cool(address(shop));
        vm.prank(address(intake));
        uint256 beforeGas = gasleft();
        shop.onResult(id, keccak256("artifact"), string(uri));
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("maximum URI callback gas", used);
        assertLt(used, 150_000);
    }

    function test_oversizedURIAndInvalidFailureStatusReject() public {
        fund(100 ether);
        bytes32 id = commission();
        string memory tooLong = string(new bytes(shop.MAX_URI_BYTES() + 1));
        vm.expectRevert(Workshop.URITooLong.selector);
        vm.prank(address(intake));
        shop.onResult(id, bytes32(0), tooLong);
        vm.expectRevert(Workshop.InvalidFailureStatus.selector);
        vm.prank(address(intake));
        shop.onFailure(id, 0, bytes32(0), 0, 0, "");
    }

    function test_reentrantCommissionCannotDoubleSpend() public {
        fund(100 ether);
        intake.configure(PRICE, false, true, false);
        commission();
        assertFalse(intake.reentrySucceeded());
        assertEq(shop.workCount(), 1);
        assertEq(imd.balanceOf(keeper), PRICE / 50);
    }

    function test_failedIntakeOrBountyRollsBackEverything() public {
        fund(100 ether);
        intake.configure(PRICE, true, false, false);
        assertFalse(shop.canCommission());
        vm.expectRevert(MockIntake.Refused.selector);
        commission();
        intake.configure(PRICE, false, false, false);
        imd.refuse(keeper);
        vm.expectRevert();
        commission();
        assertEq(shop.workCount(), 0);
        assertEq(shop.nextTemplate(), 0);
        assertEq(shop.commissionsToday(), 0);
        assertEq(imd.balanceOf(address(shop)), 100 ether);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(imd.allowance(address(shop), address(intake)), 0);
    }

    function test_requestFailureAfterApprovalIsAtomic() public {
        fund(100 ether);
        intake.setRejectRequest(true);
        vm.expectRevert(MockIntake.Refused.selector);
        commission();
        assertEq(shop.lastCommissionAt(), 0);
        assertEq(shop.nextTemplate(), 0);
        assertEq(shop.workCount(), 0);
        assertEq(shop.commissionsToday(), 0);
        assertEq(imd.allowance(address(shop), address(intake)), 0);
        assertEq(imd.balanceOf(address(shop)), 100 ether);
        assertEq(imd.balanceOf(keeper), 0);
        intake.setRejectRequest(false);
        commission();
        assertEq(shop.workCount(), 1);
    }

    function test_extremeExternalPriceDoesNotOverflowCanCommission() public {
        intake.configure(type(uint256).max, false, false, false);
        assertFalse(shop.canCommission());
        vm.expectRevert(
            abi.encodeWithSelector(Workshop.InsufficientIMD.selector, type(uint256).max, type(uint256).max / 50, 0)
        );
        commission();
    }

    function test_duplicateIntakeRequestIdRollsBackSecondPayment() public {
        fund(100 ether);
        commission();
        vm.warp(block.timestamp + 6 hours);
        intake.configure(PRICE, false, false, true);
        vm.expectRevert(Workshop.DuplicateRequest.selector);
        commission();
        assertEq(shop.workCount(), 1);
        assertEq(imd.balanceOf(address(intake)), PRICE);
    }

    function test_unansweredRequestsDoNotBlockFutureCommissions() public {
        fund(100 ether);
        commission();
        vm.warp(block.timestamp + 6 hours);
        commission();
        assertEq(shop.workCount(), 2);
    }

    function test_firstCommissionAtTimestampZeroStillEnforcesCooldown() public {
        vm.warp(0);
        fund(100 ether);
        commission();
        vm.expectRevert(abi.encodeWithSelector(Workshop.TooSoon.selector, 6 hours));
        commission();
    }

    function testFuzz_priceAndBountyConservation(uint128 price) public {
        intake.configure(price, false, false, false);
        uint256 bounty = uint256(price) / 50;
        fund(uint256(price) + bounty);
        commission();
        assertEq(imd.balanceOf(keeper), bounty);
        assertEq(imd.balanceOf(address(intake)), price);
        assertEq(imd.balanceOf(address(shop)), 0);
        assertEq(imd.allowance(address(shop), address(intake)), 0);
    }
}
