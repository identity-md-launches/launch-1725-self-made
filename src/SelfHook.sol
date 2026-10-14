// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LaunchConstants} from "./LaunchConstants.sol";
import {Workshop} from "./Workshop.sol";

/// @notice Fixed 2% fee on gross IMD: total IMD input on buys, pre-hook IMD output on sells.
/// @dev All fees belong to the Workshop this hook deploys in its constructor. No admin, mutable
/// configuration, or job calls during swaps.
contract SelfHook is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable token;
    /// @notice The Workshop created by this hook's constructor: the only recipient of hook fees.
    address public immutable workshop;
    bool private immutable _imdIs0;
    Currency public constant IMD = Currency.wrap(LaunchConstants.IMD);
    uint256 public constant FEE_BPS = 200;

    error NotPoolManager();
    error NotSelf();
    error InvalidAddress();
    error WrongPool();
    error QuotedIMD(int128 amount);

    event FeePaid(uint256 amount);
    event FeeDeferred(uint256 amount);
    event FeesRedeemed(uint256 amount);

    /// @dev There is no pre-deployed Workshop, so the hook creates the only one it will ever pay.
    /// `new Workshop()` is a plain CREATE with no arguments; it calls no existing contract.
    constructor(IPoolManager manager_, address token_) {
        if (address(manager_) == address(0) || token_ == address(0) || token_ == LaunchConstants.IMD) {
            revert InvalidAddress();
        }
        poolManager = manager_;
        token = token_;
        workshop = address(new Workshop());
        _imdIs0 = LaunchConstants.IMD < token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(_imdIs0 ? LaunchConstants.IMD : token),
            currency1: Currency.wrap(_imdIs0 ? token : LaunchConstants.IMD),
            fee: LaunchConstants.LP_FEE,
            tickSpacing: LaunchConstants.TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _checkPool(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 fee = 0;
        if (_imdSpecified(params)) {
            bool exactInput = params.amountSpecified < 0;
            // Reserve 2% of gross input, or gross up net requested output by 2/98.
            int256 budget = exactInput ? -(params.amountSpecified / 50) : params.amountSpecified / 49;
            int256 quoteAmount;
            if (!exactInput && params.amountSpecified > type(int256).max - budget) {
                quoteAmount = type(int256).max;
            } else {
                quoteAmount = params.amountSpecified + budget;
            }
            // A rollback quote lets a price-limited partial fill pay only for executed volume.
            // A direct self-initiated PM swap skips this hook (v4's noSelfCall), so no recursion.
            try this.quoteIMD(key, SwapParams(params.zeroForOne, quoteAmount, params.sqrtPriceLimitX96)) {}
            catch (bytes memory reason) {
                if (reason.length != 36 || bytes4(reason) != QuotedIMD.selector) {
                    assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
                }
                int256 raw;
                assembly ("memory-safe") { raw := mload(add(reason, 36)) }
                fee = exactInput ? uint256(-raw) / 49 : uint256(raw) / 50;
                if (fee > uint256(budget)) fee = uint256(budget);
            }
            _pay(fee);
        }
        // fee is at most 1/49 of a real int128 pool delta, hence safely fits int128.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        uint256 fee = 0;
        if (!_imdSpecified(params)) {
            int256 raw = _imdIs0 ? delta.amount0() : delta.amount1();
            fee = raw < 0 ? uint256(-raw) / 49 : uint256(raw) / 50;
            _pay(fee);
        }
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @dev Internal quote endpoint. ALWAYS reverts, rolling back swap state, deltas, and events.
    function quoteIMD(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert NotSelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert QuotedIMD(_imdIs0 ? delta.amount0() : delta.amount1());
    }

    /// @notice Anyone can forward deferred IMD claims to the immutable Workshop after settlement.
    function redeemFees() external returns (uint256) {
        return abi.decode(poolManager.unlock(""), (uint256));
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = poolManager.balanceOf(address(this), IMD.toId());
        uint256 available = IMD.balanceOf(address(poolManager));
        if (amount > available) amount = available;
        if (amount != 0) {
            poolManager.burn(address(this), IMD.toId(), amount);
            poolManager.take(IMD, workshop, amount);
            emit FeesRedeemed(amount);
        }
        return abi.encode(amount);
    }

    function _pay(uint256 fee) private {
        if (fee == 0) return;
        // The swapper settles AFTER callbacks. A fresh or temporarily depleted manager may
        // lack physical IMD now. Preserve the fee as an IMD claim instead of blocking the swap.
        try poolManager.take(IMD, workshop, fee) {
            emit FeePaid(fee);
        } catch {
            poolManager.mint(address(this), IMD.toId(), fee);
            emit FeeDeferred(fee);
        }
    }

    function _imdSpecified(SwapParams calldata params) private view returns (bool) {
        return (params.amountSpecified < 0 == params.zeroForOne) == _imdIs0;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (
            address(key.hooks) != address(this) || key.fee != LaunchConstants.LP_FEE
                || key.tickSpacing != LaunchConstants.TICK_SPACING
                || Currency.unwrap(key.currency0) != (_imdIs0 ? LaunchConstants.IMD : token)
                || Currency.unwrap(key.currency1) != (_imdIs0 ? token : LaunchConstants.IMD)
        ) revert WrongPool();
    }
}
