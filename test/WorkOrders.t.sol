// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Workshop} from "../src/Workshop.sol";

/// @notice Independent commitments to the four exact request bodies supplied in the task.
contract WorkOrdersTest is Test {
    function test_templateBytesMatchBrief() public {
        Workshop shop = new Workshop();
        bytes32[4] memory expected = [
            bytes32(0xa2622e93172ba74af20aa3ce3f5ce3fd2670943cf4c3abab0d8abf140ca23c58),
            bytes32(0x7a3661359634339d29d78766ae9378311865699ee4d61d48c79093c66e9cfb50),
            bytes32(0x6be0ddee9f43db6bad4fc703df83223b7a2529d803d786736df2441b14245caf),
            bytes32(0x81935a94e41e0865ea1448dd95b0e24c1864c6eb9b84984b82ab917cfcae39fb)
        ];
        for (uint8 i; i < 4; ++i) {
            bytes memory body = shop.templateBody(i);
            assertEq(keccak256(body), expected[i]);
            assertLe(body.length, 16_384);
        }
    }
}
