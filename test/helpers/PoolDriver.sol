// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only pre-funded pool driver; never part of the launch deployment.
contract PoolDriver is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params))), (BalanceDelta));
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (bool trading, PoolKey memory key, bytes memory params) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (trading) delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        else (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        require(manager.currencyDelta(address(this), key.currency0) == delta.amount0(), "delta0 mismatch");
        require(manager.currencyDelta(address(this), key.currency1) == delta.amount1(), "delta1 mismatch");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            require(
                IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount))),
                "transfer failed"
            );
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint128(amount));
        }
    }
}
