// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    address public refusedRecipient;

    constructor(string memory n, string memory s, uint256 supply) ERC20(n, s) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function refuse(address to) external {
        refusedRecipient = to;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == refusedRecipient) return false;
        return super.transfer(to, amount);
    }
}
