// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyReserves} from "@uniswap/v4-core/src/libraries/CurrencyReserves.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCToken} from "frontier/interfaces/IBCToken.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";
import {IExtensionHost} from "frontier/interfaces/extensions/IExtensionHost.sol";
import {IFeeCalculator} from "frontier/interfaces/extensions/IFeeCalculator.sol";
import {IHookObserver} from "frontier/interfaces/extensions/IHookObserver.sol";

import {HookGated} from "kit/HookGated.sol";

import {IWthArbitrageExecutor} from "./IWthArbitrageExecutor.sol";
import {IWthCorrector} from "./IWthCorrector.sol";

/**
 * @title WthCorrector
 * @notice Official correction extension: one singleton bound on a pool as its last fee calculator
 * and as an after-swap observer. After a user swap it calls the partner executor inside the same
 * unlock, prices the executor's in-band legs at the protocol floor, and splits the payment it
 * receives in WETH or native ETH between the pool's LPs and the coin's fee recipient.
 * @dev The band and the user's direction live in transient storage for the duration of the
 * executor call; a self-lock makes the nested notifications of the executor's own legs return at
 * once. The PoolManager delta snapshot taken around the call must be unchanged on return, else the
 * whole correction reverts and the hook swallows it.
 */
contract WthCorrector is IWthCorrector, HookGated {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice Role bit of the fee-calculator binding.
    uint8 public constant ROLE_CALCULATOR = 1;

    /// @notice Role bit of the observer binding.
    uint8 public constant ROLE_OBSERVER = 2;

    /// @notice Basis-point denominator.
    uint16 private constant MAX_BPS = 10_000;

    /// @notice The `creatorBps` named in the profit split handed to the executor; the split's three shares sum to it.
    uint16 public constant CREATOR_BPS = 8000;

    /// @notice Lowest LP share a pool may bind, in bps.
    uint16 public constant MIN_LP_SHARE_BPS = 2500;

    /// @notice Minimum `getPoolState` returndata: the offset word plus the `PoolState` head words 0-3.
    uint256 private constant POOL_STATE_PREFIX_BYTES = 5 * 32;

    /// @notice Gas kept back from the executor call for the snapshot check and the payout.
    uint256 public constant TAIL_RESERVE = 120_000;

    /// @dev Transient self-lock, set for the whole correction; `receive` accepts ETH only while it is set.
    bytes32 private constant LOCK_TSLOT = keccak256("WthCorrector.lock");

    /// @dev Transient pool id of the open correction window (zero = closed).
    bytes32 private constant WINDOW_TSLOT = keccak256("WthCorrector.window");

    /// @dev Transient lower sqrt price of the band.
    bytes32 private constant LOWER_TSLOT = keccak256("WthCorrector.lower");

    /// @dev Transient upper sqrt price of the band.
    bytes32 private constant UPPER_TSLOT = keccak256("WthCorrector.upper");

    /// @dev Transient direction of the user's swap (1 = zeroForOne).
    bytes32 private constant DIRECTION_TSLOT = keccak256("WthCorrector.direction");

    /// @notice The Uniswap V4 pool manager.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The canonical WETH, the payout asset.
    address public immutable WETH;

    /// @notice Gas left below which `onAfterSwap` returns without calling the executor.
    uint256 public immutable MIN_CORRECTION_GAS;

    /// @notice Payment below which a correction reverts, in wei.
    uint256 public immutable MIN_PAYMENT_WEI;

    /// @notice The partner executor; the zero address pauses corrections.
    address public executor;

    /// @dev Per-pool bindings; `roles == 0` marks an unbound pool.
    mapping(PoolId poolId => PoolBinding binding) internal _bindings;

    /**
     * @param factory The Frontier `BCTokenFactory`; its owner sets the executor.
     * @param poolManager The Uniswap V4 pool manager.
     * @param weth The canonical WETH.
     * @param minCorrectionGas Gas left below which a correction is skipped.
     * @param minPaymentWei Payment below which a correction reverts.
     */
    constructor(
        address factory,
        IPoolManager poolManager,
        address weth,
        uint256 minCorrectionGas,
        uint256 minPaymentWei
    ) HookGated(factory) {
        if (factory == address(0) || address(poolManager) == address(0) || weth == address(0)) {
            revert InvalidZeroAddress();
        }
        POOL_MANAGER = poolManager;
        WETH = weth;
        MIN_CORRECTION_GAS = minCorrectionGas;
        MIN_PAYMENT_WEI = minPaymentWei;
    }

    /// @notice Accepts native ETH (the executor's payment, WETH unwrapping) only during a correction.
    receive() external payable {
        if (_tload(LOCK_TSLOT) == 0) revert EthNotAccepted();
    }

    /// @inheritdoc IWthCorrector
    function setExecutor(address newExecutor) external {
        if (msg.sender != IBCTokenFactory(BC_TOKEN_FACTORY).owner()) revert OnlyFactoryOwner();
        emit ExecutorSet(executor, newExecutor);
        executor = newExecutor;
    }

    /// @inheritdoc IWthCorrector
    function recoverERC20(address token, address to, uint256 amount) external {
        if (msg.sender != IBCTokenFactory(BC_TOKEN_FACTORY).owner()) revert OnlyFactoryOwner();
        if (token == address(0) || to == address(0)) revert InvalidZeroAddress();
        if (_tload(LOCK_TSLOT) != 0) revert CorrectionInProgress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRecovered(token, to, amount);
    }

    /// @inheritdoc IFeeCalculator
    function onRegisterCalculator(PoolId poolId, bytes calldata config) external {
        _bind(poolId, config, ROLE_CALCULATOR);
    }

    /// @inheritdoc IHookObserver
    function onRegisterObserver(PoolId poolId, bytes calldata config) external {
        _bind(poolId, config, ROLE_OBSERVER);
    }

    /// @inheritdoc IFeeCalculator
    function quoteFee(PoolId poolId, uint24 previousFee, uint24, uint88, int24, SwapParams calldata params)
        external
        view
        returns (uint24)
    {
        if (_tload(WINDOW_TSLOT) != uint256(PoolId.unwrap(poolId)) || executor == address(0)) {
            return previousFee;
        }
        if (params.amountSpecified >= 0 || params.zeroForOne == (_tload(DIRECTION_TSLOT) != 0)) return previousFee;
        uint256 limit = params.sqrtPriceLimitX96;
        if (limit <= _tload(LOWER_TSLOT) || limit >= _tload(UPPER_TSLOT)) return previousFee;
        return 0;
    }

    /// @inheritdoc IHookObserver
    function onAfterSwap(PoolId poolId, BalanceDelta delta, uint24, uint256, bytes calldata) external {
        _checkPoolHook(poolId);
        address target = executor;
        if (target == address(0) || _tload(LOCK_TSLOT) != 0 || gasleft() < MIN_CORRECTION_GAS) return;
        _tstore(LOCK_TSLOT, 1);

        PoolBinding memory binding = _bindings[poolId];
        _openWindow(poolId, delta.amount0() < 0);
        (uint256 received, uint256 nativeReceived) = _correct(target, binding);
        if (received < MIN_PAYMENT_WEI) revert PaymentTooLow(received);
        if (received != 0) _payout(poolId, binding, received, nativeReceived);

        _tstore(LOCK_TSLOT, 0);
    }

    /// @inheritdoc IHookObserver
    function onFeeChange(PoolId poolId, uint24, uint24) external view {
        _checkPoolHook(poolId);
    }

    /// @inheritdoc IWthCorrector
    function currentBand(PoolId poolId) external view returns (uint160 lower, uint160 upper) {
        if (_tload(WINDOW_TSLOT) != uint256(PoolId.unwrap(poolId))) return (0, 0);
        lower = uint160(_tload(LOWER_TSLOT));
        upper = uint160(_tload(UPPER_TSLOT));
    }

    /// @inheritdoc IWthCorrector
    function bindingOf(PoolId poolId) external view returns (PoolBinding memory) {
        return _bindings[poolId];
    }

    /// @notice Binds one role on a pool: hook-gated, write-once per role, the pool key rebuilt from the
    /// config's tick spacing must hash to `poolId`, the hook's `PoolState` prefix must name the coin,
    /// and both roles must carry the same config.
    function _bind(PoolId poolId, bytes calldata config, uint8 role) internal {
        address hook = hookOf[poolId];
        if (hook == address(0)) hook = address(_registerPool(poolId));
        else _checkPoolHook(poolId);

        PoolBinding storage binding = _bindings[poolId];
        if (binding.roles & role != 0) revert RoleAlreadyBound();
        if (config.length != 64) revert InvalidPoolConfig();
        (int24 tickSpacing, uint16 lpShareBps) = abi.decode(config, (int24, uint16));
        if (lpShareBps < MIN_LP_SHARE_BPS || lpShareBps > MAX_BPS) revert InvalidShares();
        if (binding.roles != 0 && binding.lpShareBps != lpShareBps) revert InvalidPoolConfig();
        address coin = IExtensionHost(hook).poolCoin(poolId);
        if (coin == address(0) || PoolId.unwrap(_poolKey(coin, tickSpacing, hook).toId()) != PoolId.unwrap(poolId)) {
            revert InvalidPoolConfig();
        }
        (uint256 coinWord, uint256 registeredWord,) = _poolStatePrefix(hook, poolId);
        if (coinWord != uint256(uint160(coin)) || registeredWord != 1) revert PoolStateUnavailable();

        binding.coin = coin;
        binding.tickSpacing = tickSpacing;
        binding.lpShareBps = lpShareBps;
        binding.roles |= role;
    }

    /// @notice Calls the executor with the window open, then checks the delta snapshot and counts the
    /// payment received (WETH and native ETH together, and the native part alone).
    function _correct(address target, PoolBinding memory binding)
        internal
        returns (uint256 received, uint256 nativeReceived)
    {
        bytes32 digest = _deltaDigest(msg.sender, binding.coin);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        bool ok = _callExecutor(target, binding);
        _tstore(WINDOW_TSLOT, 0);
        if (!ok) revert ExecutorCallFailed();
        if (_deltaDigest(msg.sender, binding.coin) != digest) revert DeltaSnapshotChanged();

        nativeReceived = address(this).balance - ethBefore;
        received = IERC20(WETH).balanceOf(address(this)) - wethBefore + nativeReceived;
    }

    /// @notice Calls the executor, keeping `TAIL_RESERVE` back; the returndata is never copied into memory.
    function _callExecutor(address target, PoolBinding memory binding) internal returns (bool ok) {
        bytes memory data = abi.encodeCall(
            IWthArbitrageExecutor.executeArbitrage,
            (
                _poolKey(binding.coin, binding.tickSpacing, msg.sender),
                address(0),
                IWthArbitrageExecutor.ProfitSplit({
                    creator: address(this), traderBps: 0, creatorBps: CREATOR_BPS, triggerPoolBps: 0
                })
            )
        );
        uint256 reserve = TAIL_RESERVE;
        assembly ("memory-safe") {
            let left := gas()
            let budget := mul(gt(left, reserve), sub(left, reserve))
            ok := call(budget, target, 0, add(data, 32), mload(data), 0, 0)
        }
    }

    /// @notice Opens the correction window: the band between the post-swap price and the pre-swap
    /// tick moved one tick toward it, and the user's direction. An inverted band is stored as zeros.
    function _openWindow(PoolId poolId, bool zeroForOne) internal {
        (uint160 post,,,) = POOL_MANAGER.getSlot0(poolId);
        int24 edgeTick = _referenceTick(msg.sender, poolId);
        edgeTick = zeroForOne ? edgeTick - 1 : edgeTick + 1;

        uint160 lower;
        uint160 upper;
        if (edgeTick >= TickMath.MIN_TICK && edgeTick <= TickMath.MAX_TICK) {
            uint160 edge = TickMath.getSqrtPriceAtTick(edgeTick);
            (lower, upper) = zeroForOne ? (post, edge) : (edge, post);
            if (lower >= upper) (lower, upper) = (0, 0);
        }

        _tstore(WINDOW_TSLOT, uint256(PoolId.unwrap(poolId)));
        _tstore(LOWER_TSLOT, lower);
        _tstore(UPPER_TSLOT, upper);
        _tstore(DIRECTION_TSLOT, zeroForOne ? 1 : 0);
    }

    /// @notice Reads the hook's pre-swap reference tick off the `PoolState` prefix (head word 3).
    function _referenceTick(address hook, PoolId poolId) internal view returns (int24 tick) {
        (,, int256 word) = _poolStatePrefix(hook, poolId);
        tick = int24(word);
    }

    /// @notice Reads the `PoolState` head words 0 (`coin`), 1 (`registered`) and 3 (`referenceTick`) raw.
    /// @dev Raw staticcall with a bounded copy: the typed decode would copy the pool's extension arrays.
    function _poolStatePrefix(address hook, PoolId poolId)
        internal
        view
        returns (uint256 coinWord, uint256 registeredWord, int256 tickWord)
    {
        bytes memory data = abi.encodeCall(IFactoryHook.getPoolState, (poolId));
        uint256 size = POOL_STATE_PREFIX_BYTES;
        bool ok;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(gas(), hook, add(data, 32), mload(data), out, size)
            ok := and(ok, iszero(lt(returndatasize(), size)))
            coinWord := mload(add(out, 0x20))
            registeredWord := mload(add(out, 0x40))
            tickWord := mload(add(out, 0x80))
        }
        if (!ok) revert PoolStateUnavailable();
    }

    /// @notice Digest of the PoolManager transient state a correction must leave untouched: the nonzero
    /// delta count, the hook's and this contract's deltas on both currencies, and the synced currency.
    function _deltaDigest(address hook, address coin) internal view returns (bytes32) {
        bytes32[] memory slots = new bytes32[](6);
        slots[0] = NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT;
        slots[1] = _deltaSlot(hook, address(0));
        slots[2] = _deltaSlot(hook, coin);
        slots[3] = _deltaSlot(address(this), address(0));
        slots[4] = _deltaSlot(address(this), coin);
        slots[5] = CurrencyReserves.CURRENCY_SLOT;
        return keccak256(abi.encode(POOL_MANAGER.exttload(slots)));
    }

    /// @notice The PoolManager transient slot holding `target`'s delta on `currency` (`address(0)` for ETH).
    function _deltaSlot(address target, address currency) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, currency));
    }

    /// @notice Splits a payment: the pool's LP share donated to the pool in native ETH, the rest to the
    /// coin's fee recipient in WETH.
    /// @dev The LP share falls to the fee recipient when the pool has no in-range liquidity, since
    /// `donate` reverts there.
    function _payout(PoolId poolId, PoolBinding memory binding, uint256 received, uint256 nativeHeld) internal {
        address recipient = IBCToken(binding.coin).getFeeRecipient();

        uint256 lpAmount = received * binding.lpShareBps / MAX_BPS;
        if (lpAmount != 0 && POOL_MANAGER.getLiquidity(poolId) == 0) lpAmount = 0;

        if (lpAmount != 0) {
            if (nativeHeld < lpAmount) {
                IWETH(WETH).withdraw(lpAmount - nativeHeld);
                nativeHeld = lpAmount;
            }
            nativeHeld -= lpAmount;
            POOL_MANAGER.sync(CurrencyLibrary.ADDRESS_ZERO);
            POOL_MANAGER.settle{value: lpAmount}();
            POOL_MANAGER.donate(_poolKey(binding.coin, binding.tickSpacing, msg.sender), lpAmount, 0, "");
        }
        if (nativeHeld != 0) IWETH(WETH).deposit{value: nativeHeld}();

        uint256 recipientAmount = received - lpAmount;
        _pay(recipient, recipientAmount);
        emit CorrectionSettled(poolId, received, lpAmount, recipientAmount);
    }

    /// @notice Transfers WETH.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!IWETH(WETH).transfer(to, amount)) revert TransferFailed();
    }

    /// @notice The hooked native-ETH/coin pool key.
    function _poolKey(address coin, int24 tickSpacing, address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(coin),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }

    /// @notice Reverts unless the caller is the hook `poolId` was registered by.
    function _checkPoolHook(PoolId poolId) private view {
        if (msg.sender != hookOf[poolId]) revert NotPoolHook(msg.sender);
    }

    /// @notice Reads a transient slot.
    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @notice Writes a transient slot.
    function _tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
