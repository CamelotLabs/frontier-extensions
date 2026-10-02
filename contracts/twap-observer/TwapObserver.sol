// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IBCToken} from "frontier/interfaces/IBCToken.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IExtensionHost} from "frontier/interfaces/extensions/IExtensionHost.sol";
// referenced by @inheritdoc
// aderyn-ignore-next-line(unused-import)
import {IHookObserver} from "frontier/interfaces/extensions/IHookObserver.sol";

import {HookGated} from "kit/HookGated.sol";

import {ITwapObserver} from "./ITwapObserver.sol";

// slither-disable-start timestamp
// timestamps are the data this contract stores and compares, not a source of randomness or a deadline
/**
 * @title TwapObserver
 * @notice Official history extension for the hook's truncated tick oracle: one singleton bound per pool as an
 * after-swap observer, storing the hook's `observe` reading at most once per `interval` in a per-pool ring, and
 * answering time-weighted average ticks from it.
 * @dev A pool's binding and cursor share one slot with the hook address, so the hook check and the no-op
 * path of `onAfterSwap` cost one storage read. One observation fills one slot.
 * INVARIANT: `count <= cardinality <= MAX_CARDINALITY`, and `count` never decreases.
 * INVARIANT: stored timestamps increase strictly from the oldest observation to the newest, at least
 * `interval` apart; `lastTimestamp` is the newest one's.
 * INVARIANT: `consult(poolId, secondsAgo)` returns `span >= secondsAgo` or reverts.
 */
contract TwapObserver is ITwapObserver, HookGated {
    /// @inheritdoc ITwapObserver
    uint32 public constant DEFAULT_INTERVAL = 5 minutes;

    /// @inheritdoc ITwapObserver
    uint16 public constant DEFAULT_CARDINALITY = 16;

    /// @inheritdoc ITwapObserver
    uint32 public constant MIN_INTERVAL = 1 minutes;

    /// @inheritdoc ITwapObserver
    uint32 public constant MAX_INTERVAL = 1 days;

    /// @inheritdoc ITwapObserver
    uint16 public constant MIN_CARDINALITY = 2;

    /// @inheritdoc ITwapObserver
    uint16 public constant MAX_CARDINALITY = 64;

    /// @dev Length of an `abi.encode(uint32, uint16)` config.
    uint256 private constant CONFIG_BYTES = 64;

    /// @dev Per-pool binding and ring cursor; `hook == address(0)` marks an unbound pool.
    mapping(PoolId poolId => PoolState state) internal _pools;

    /// @dev Per-pool ring of observations; only the first `cardinality` slots are used.
    mapping(PoolId poolId => Observation[MAX_CARDINALITY] ring) internal _rings;

    /// @param factory The Frontier `BCTokenFactory`.
    constructor(address factory) HookGated(factory) {}

    /// @inheritdoc IHookObserver
    function onRegisterObserver(PoolId poolId, bytes calldata config) external {
        address hook = address(_registerPool(poolId));
        if (_pools[poolId].hook != address(0)) revert PoolAlreadyBound(poolId);

        uint32 interval = DEFAULT_INTERVAL;
        uint16 cardinality = DEFAULT_CARDINALITY;
        if (config.length != 0) {
            if (config.length != CONFIG_BYTES) revert InvalidConfig();
            (uint256 rawInterval, uint256 rawCardinality) = abi.decode(config, (uint256, uint256));
            if (rawInterval < MIN_INTERVAL || rawInterval > MAX_INTERVAL) revert InvalidConfig();
            if (rawCardinality < MIN_CARDINALITY || rawCardinality > MAX_CARDINALITY) revert InvalidConfig();
            // both fit: bounded above by MAX_INTERVAL and MAX_CARDINALITY
            interval = uint32(rawInterval);
            cardinality = uint16(rawCardinality);
        }

        _pools[poolId] = PoolState({
            hook: hook, interval: interval, cardinality: cardinality, newest: 0, count: 0, lastTimestamp: 0
        });
        emit PoolBound(poolId, hook, interval, cardinality);
    }

    /// @inheritdoc IHookObserver
    /// @dev Runs on graduated pools only (the hook blocks swaps before), so no graduation check here.
    // recording emits no event by design: it runs on every due swap, readers use the views
    // aderyn-ignore-next-line(state-change-without-event)
    function onAfterSwap(PoolId poolId, BalanceDelta, uint24, uint256, bytes calldata) external {
        PoolState memory state = _pools[poolId];
        if (msg.sender != state.hook) revert NotPoolHook(msg.sender);
        if (!_due(state)) return;
        _record(poolId, state);
    }

    /// @inheritdoc IHookObserver
    function onFeeChange(PoolId poolId, uint24, uint24) external view {
        if (msg.sender != _pools[poolId].hook) revert NotPoolHook(msg.sender);
    }

    /// @inheritdoc ITwapObserver
    // recording emits no event by design: it runs on every due swap, readers use the views
    // aderyn-ignore-next-line(state-change-without-event)
    function record(PoolId poolId) external returns (bool recorded) {
        PoolState memory state = _pools[poolId];
        if (state.hook == address(0)) revert PoolNotBound(poolId);
        if (!_due(state)) return false;
        if (!IBCToken(IExtensionHost(state.hook).poolCoin(poolId)).isLPd()) revert PoolNotGraduated(poolId);
        _record(poolId, state);
        return true;
    }

    /// @inheritdoc ITwapObserver
    function consult(PoolId poolId, uint32 secondsAgo) external view returns (int24 averageTick, uint32 span) {
        PoolState memory state = _pools[poolId];
        if (state.hook == address(0)) revert PoolNotBound(poolId);
        if (secondsAgo == 0) revert ZeroSecondsAgo();
        // count is an observation counter, not a balance
        // slither-disable-next-line incorrect-equality
        if (state.count == 0 || secondsAgo > block.timestamp) revert NotEnoughHistory(poolId, secondsAgo);

        Observation memory past = _search(poolId, state, block.timestamp - secondsAgo, secondsAgo);
        // only the cumulative is needed, the current tick is not
        // slither-disable-next-line unused-return
        (int56 cumulativeNow,) = IFactoryHook(state.hook).observe(poolId);

        // both are uint32 timestamps and past.timestamp <= block.timestamp
        span = uint32(block.timestamp - past.timestamp);
        int256 delta = int256(cumulativeNow) - int256(past.tickCumulative);
        int256 average = delta / int256(uint256(span));
        // the remainder decides the rounding toward negative infinity, not randomness
        // slither-disable-next-line weak-prng
        if (delta < 0 && delta % int256(uint256(span)) != 0) --average;
        averageTick = SafeCast.toInt24(average);
    }

    /// @inheritdoc ITwapObserver
    function poolState(PoolId poolId) external view returns (PoolState memory) {
        return _pools[poolId];
    }

    /// @inheritdoc ITwapObserver
    function observationAt(PoolId poolId, uint256 index) external view returns (Observation memory) {
        PoolState memory state = _pools[poolId];
        if (index >= state.count) revert ObservationOutOfRange(poolId, index);
        return _rings[poolId][_slot(state, index)];
    }

    /// @inheritdoc ITwapObserver
    function latestObservation(PoolId poolId) external view returns (Observation memory observation) {
        PoolState memory state = _pools[poolId];
        if (state.count != 0) observation = _rings[poolId][state.newest];
    }

    /// @notice Stores the hook's current reading in the slot after the newest one, overwriting the oldest
    /// once the ring is full.
    function _record(PoolId poolId, PoolState memory state) internal {
        // only the cumulative is stored, the current tick is not
        // slither-disable-next-line unused-return
        (int56 tickCumulative,) = IFactoryHook(state.hook).observe(poolId);
        uint32 timestamp = SafeCast.toUint32(block.timestamp);

        // ring index arithmetic on an observation counter, neither randomness nor a balance
        // slither-disable-next-line weak-prng,incorrect-equality
        uint8 slot = state.count == 0 ? 0 : uint8((uint256(state.newest) + 1) % state.cardinality);
        _rings[poolId][slot] = Observation({timestamp: timestamp, tickCumulative: tickCumulative});

        state.newest = slot;
        if (state.count < state.cardinality) ++state.count;
        state.lastTimestamp = timestamp;
        _pools[poolId] = state;
    }

    /// @notice Whether the pool has no observation yet or its newest is at least `interval` old.
    function _due(PoolState memory state) internal view returns (bool) {
        // count is an observation counter, not a balance
        // slither-disable-next-line incorrect-equality
        return state.count == 0 || block.timestamp >= uint256(state.lastTimestamp) + state.interval;
    }

    /// @notice The newest observation with `timestamp <= target`, by binary search over the ring ordered
    /// from the oldest observation; reverts `NotEnoughHistory` when the oldest is younger than `target`.
    /// @dev Requires `state.count != 0`.
    function _search(PoolId poolId, PoolState memory state, uint256 target, uint32 secondsAgo)
        internal
        view
        returns (Observation memory)
    {
        Observation[MAX_CARDINALITY] storage ring = _rings[poolId];
        if (state.lastTimestamp <= target) return ring[state.newest];

        Observation memory oldest = ring[_slot(state, 0)];
        if (oldest.timestamp > target) revert NotEnoughHistory(poolId, secondsAgo);

        // in ring order, position `lo` is at or before `target` and position `hi` after it
        // starts at zero, the oldest position
        // slither-disable-next-line uninitialized-local
        uint256 lo;
        uint256 hi = state.count - 1;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (ring[_slot(state, mid)].timestamp <= target) lo = mid;
            else hi = mid;
        }
        return lo == 0 ? oldest : ring[_slot(state, lo)];
    }

    /// @notice The ring slot of the observation at `index` positions after the oldest.
    function _slot(PoolState memory state, uint256 index) internal pure returns (uint256) {
        // newest + 1 - count is the oldest's slot, shifted by one cardinality to stay non-negative
        // ring index arithmetic, not randomness
        // slither-disable-next-line weak-prng
        return (uint256(state.newest) + state.cardinality + 1 - state.count + index) % state.cardinality;
    }
}
// slither-disable-end timestamp
