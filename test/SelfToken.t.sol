// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SelfToken} from "../src/SelfToken.sol";

contract SelfTokenTest is Test {
    SelfToken token;

    function setUp() public {
        token = new SelfToken();
    }

    function test_fixedPolicySupplyAndIdentity() public view {
        assertEq(token.name(), "Self Made");
        assertEq(token.symbol(), "SELF");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferConservesSupply(uint128 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, token.totalSupply());
        address recipient = makeAddr("recipient");
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromHonorsAllowanceAndHasNoTax() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, 7 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 7 ether);
        assertEq(token.balanceOf(recipient), 7 ether);
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert();
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
    }

    function test_noAdminOrMintFunctionsEvenForDeployer() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)",
            "withdraw(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), 10 ether));
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function test_noRuntimeEscapeHatch() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xff && op != 0xf2);
        }
    }
}
