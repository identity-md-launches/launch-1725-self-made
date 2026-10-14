// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Workshop} from "../../src/Workshop.sol";

contract MockIntake is IIntake {
    uint256 public price;
    uint256 public nonce;
    bool public reject;
    bool public rejectRequest;
    bool public reenter;
    bool public duplicate;
    bool public reentrySucceeded;
    uint256 public seenAllowance;
    bytes32 public lastAction;
    bytes public lastBody;
    address public lastAsset;
    Callback public lastCallback;
    bytes4 public lastFailure;
    uint256 public lastAmount;
    error Refused();

    function configure(uint256 p, bool rejects, bool reenters, bool duplicates) external {
        price = p;
        reject = rejects;
        reenter = reenters;
        duplicate = duplicates;
    }

    function setRejectRequest(bool value) external {
        rejectRequest = value;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        if (reject) revert Refused();
        return price;
    }

    function request(bytes32, bytes calldata, Callback calldata, address, uint256) external payable returns (bytes32) {
        revert("failure callback required");
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        if (reject) revert Refused();
        if (rejectRequest) revert Refused();
        require(amount == price, "wrong price");
        seenAllowance = IERC20(asset).allowance(msg.sender, address(this));
        require(seenAllowance == amount, "approval must equal price");
        lastAction = action;
        lastBody = body;
        lastAsset = asset;
        lastCallback = callback;
        lastFailure = failure;
        lastAmount = amount;
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "payment failed");
        if (reenter) (reentrySucceeded,) = msg.sender.call(abi.encodeCall(Workshop.commission, ()));
        id = duplicate ? bytes32(uint256(1)) : bytes32(++nonce);
    }
}
