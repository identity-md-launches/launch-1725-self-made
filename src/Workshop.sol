// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {LaunchConstants} from "./LaunchConstants.sol";
import {WorkOrders} from "./WorkOrders.sol";

/// @notice Immutable, permissionless job commissioning. No owner, withdrawal, or upgrade path.
contract Workshop is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public constant IMD = IERC20(LaunchConstants.IMD);
    IIntake public constant INTAKE = IIntake(LaunchConstants.INTAKE);
    bytes32 public constant ACTION = LaunchConstants.ACTION;
    uint256 public constant INTERVAL = 6 hours;
    uint256 public constant MAX_PER_DAY = 4;
    uint256 public constant BOUNTY_BPS = 200;
    // URI is logged in full; its digest is stored to keep delivery cost independent of storage length.
    uint256 public constant MAX_URI_BYTES = 2048;

    enum State {
        Pending,
        Built,
        Failed
    }

    struct Work {
        bytes32 requestId;
        bytes32 resultHash;
        bytes32 uriHash;
        uint48 commissionedAt;
        uint48 completedAt;
        uint8 templateIndex;
        State state;
    }

    Work[] public works;
    mapping(bytes32 requestId => uint256 indexPlusOne) private _requestIndex;
    uint256 public lastCommissionAt;
    uint8 public nextTemplate;
    uint256 private _commissionDay;
    uint256 private _dailyCount;

    error TooSoon(uint256 eligibleAt);
    error DailyLimit();
    error InsufficientIMD(uint256 price, uint256 bounty, uint256 available);
    error NotIntake();
    error UnknownRequest();
    error AlreadyCompleted();
    error DuplicateRequest();
    error URITooLong();
    error InvalidFailureStatus();

    event Commissioned(
        bytes32 indexed requestId, uint8 indexed templateIndex, address indexed caller, uint256 price, uint256 bounty
    );
    event Built(bytes32 indexed requestId, uint8 indexed templateIndex, bytes32 resultHash, string uri);
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason);

    modifier onlyIntake() {
        if (msg.sender != address(INTAKE)) revert NotIntake();
        _;
    }

    function commission() external nonReentrant returns (bytes32 requestId) {
        uint256 count = commissionsToday();
        if (count >= MAX_PER_DAY) revert DailyLimit();
        if (works.length != 0 && block.timestamp < lastCommissionAt + INTERVAL) {
            revert TooSoon(lastCommissionAt + INTERVAL);
        }
        uint256 price = INTAKE.priceOf(ACTION, address(IMD));
        uint256 bounty = price / 50;
        uint256 balance = IMD.balanceOf(address(this));
        // Subtraction avoids overflow if an external price is close to uint256.max.
        if (balance < price || balance - price < bounty) revert InsufficientIMD(price, bounty, balance);

        uint8 index = nextTemplate;
        nextTemplate = (index + 1) % 4;
        lastCommissionAt = block.timestamp;
        _commissionDay = block.timestamp / 1 days;
        _dailyCount = count + 1;

        IMD.forceApprove(address(INTAKE), price);
        requestId = INTAKE.requestWithFailure(
            ACTION,
            WorkOrders.body(index),
            IIntake.Callback(address(this), this.onResult.selector),
            this.onFailure.selector,
            address(IMD),
            price
        );
        IMD.forceApprove(address(INTAKE), 0);
        if (_requestIndex[requestId] != 0) revert DuplicateRequest();
        works.push(Work(requestId, bytes32(0), bytes32(0), uint48(block.timestamp), 0, index, State.Pending));
        _requestIndex[requestId] = works.length;
        if (bounty != 0) IMD.safeTransfer(msg.sender, bounty);
        emit Commissioned(requestId, index, msg.sender, price, bounty);
    }

    /// @notice Only results for our own pending requests are accepted, once, even out of order.
    function onResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external onlyIntake nonReentrant {
        if (bytes(uri).length > MAX_URI_BYTES) revert URITooLong();
        Work storage work = _pending(requestId);
        work.state = State.Built;
        work.completedAt = uint48(block.timestamp);
        work.resultHash = resultHash;
        work.uriHash = keccak256(bytes(uri));
        emit Built(requestId, work.templateIndex, resultHash, uri);
    }

    /// @dev Failure metadata is informational and never authorizes payments or a new commission.
    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        onlyIntake
        nonReentrant
    {
        if (status != 1 && status != 2) revert InvalidFailureStatus();
        Work storage work = _pending(requestId);
        work.state = State.Failed;
        work.completedAt = uint48(block.timestamp);
        emit Failed(requestId, status, reason);
    }

    function commissionsToday() public view returns (uint256) {
        return _commissionDay == block.timestamp / 1 days ? _dailyCount : 0;
    }

    function nextCommissionAt() public view returns (uint256 eligibleAt) {
        if (works.length != 0) eligibleAt = lastCommissionAt + INTERVAL;
        if (commissionsToday() >= MAX_PER_DAY) {
            uint256 midnight = (block.timestamp / 1 days + 1) * 1 days;
            if (midnight > eligibleAt) eligibleAt = midnight;
        }
    }

    /// @notice False also when the external Intake price or IMD balance is unavailable.
    function canCommission() external view returns (bool) {
        if (block.timestamp < nextCommissionAt()) return false;
        try INTAKE.priceOf(ACTION, address(IMD)) returns (uint256 price) {
            try IMD.balanceOf(address(this)) returns (uint256 balance) {
                return balance >= price && balance - price >= price / 50;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function workCount() external view returns (uint256) {
        return works.length;
    }

    function templateBody(uint8 index) external pure returns (bytes memory) {
        return WorkOrders.body(index);
    }

    function _pending(bytes32 requestId) private view returns (Work storage work) {
        uint256 index = _requestIndex[requestId];
        if (index == 0) revert UnknownRequest();
        work = works[index - 1];
        if (work.state != State.Pending) revert AlreadyCompleted();
    }
}
