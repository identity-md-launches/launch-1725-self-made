// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookDeployer} from "./HookDeployer.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SelfToken} from "../../src/SelfToken.sol";
import {SelfHook} from "../../src/SelfHook.sol";
import {Workshop} from "../../src/Workshop.sol";
import {LaunchConstants} from "../../src/LaunchConstants.sol";
import {PoolDriver} from "./PoolDriver.sol";

abstract contract HookFixture is HookDeployer {
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
        // Mine only token ordering (no synthetic production addresses).
        for (uint256 salt;; ++salt) {
            address predicted =
                vm.computeCreate2Address(bytes32(salt), keccak256(type(SelfToken).creationCode), address(this));
            if ((LaunchConstants.IMD < predicted) == imdIs0) {
                self = new SelfToken{salt: bytes32(salt)}();
                break;
            }
        }
        hook = deployHook(IPoolManager(address(manager)), address(self));
        // The hook creates its own Workshop; tests read it from the hook rather than deploying one.
        shop = Workshop(hook.workshop());
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
