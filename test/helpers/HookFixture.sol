// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SelfToken} from "../../src/SelfToken.sol";
import {SelfHook} from "../../src/SelfHook.sol";
import {Workshop} from "../../src/Workshop.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LaunchConstants} from "../../src/LaunchConstants.sol";
import {PoolDriver} from "./PoolDriver.sol";

abstract contract HookFixture is Test {
    PoolManager internal manager;
    SelfToken internal self;
    SelfHook internal hook;
    Workshop internal shop;
    PoolDriver internal driver;
    PoolKey internal key;
    uint160 internal constant ONE = 79228162514264337593543950336;
    uint256 internal constant FUNDS = 100_000_000 ether;

    function deploySystem(bool imdIs0) internal {
        manager = new PoolManager(address(this));
        shop = new Workshop();
        // Mine only token ordering (no synthetic production addresses).
        for (uint256 salt;; ++salt) {
            address predicted =
                vm.computeCreate2Address(bytes32(salt), keccak256(type(SelfToken).creationCode), address(this));
            if ((LaunchConstants.IMD < predicted) == imdIs0) {
                self = new SelfToken{salt: bytes32(salt)}();
                break;
            }
        }
        bytes32 initHash =
            keccak256(abi.encodePacked(type(SelfHook).creationCode, abi.encode(manager, address(self), address(shop))));
        for (uint256 salt; salt < 300_000; ++salt) {
            address predicted = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (HookFlags.matches(predicted, HookFlags.SELF)) {
                hook = new SelfHook{salt: bytes32(salt)}(IPoolManager(address(manager)), address(self), address(shop));
                break;
            }
        }
        require(address(hook) != address(0), "salt not found");
        driver = new PoolDriver(manager);
        key = hook.poolKey();
        manager.initialize(key, ONE);
        self.transfer(address(driver), FUNDS);
        deal(LaunchConstants.IMD, address(driver), FUNDS);
    }

    function seed() internal {
        driver.modify(key, ModifyLiquidityParams(-120_000, 120_000, 1_000_000 ether, bytes32(0)));
    }
}
