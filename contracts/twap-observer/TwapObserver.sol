// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
 * path of `onAfterSwap` cost one storage read. One observation fills one slot. `increaseCardinality` pre-writes
 * the new slots with a placeholder (timestamp 1); a growth applies when the ring writes its last slot, at which
 * point ring order and slot order coincide, so the ring continues into the new slots without reordering.
 * INVARIANT: `count <= cardinality <= cardinalityNext <= MAX_CARDINALITY`; none of the three ever decreases.
 * INVARIANT: only the `count` positions from the oldest observation are read, and each holds a recording,
 * never a placeholder.
 * INVARIANT: stored timestamps increase strictly from the oldest observation to the newest, at least
 * `interval` apart; `lastTimestamp` is the newest one's.
 * INVARIANT: `consult(poolId, secondsAgo)` returns `span >= secondsAgo` or reverts.
 */
contract TwapObserver is ITwapObserver, HookGated {
    /// @inheritdoc ITwapObserver
    uint32 public constant DEFAULT_INTERVAL = 5 minutes;

    /// @inheritdoc ITwapObserver
    uint8 public constant DEFAULT_CARDINALITY = 16;

    /// @inheritdoc ITwapObserver
    uint32 public constant MIN_INTERVAL = 1 minutes;

    /// @inheritdoc ITwapObserver
    uint32 public constant MAX_INTERVAL = 1 days;

    /// @inheritdoc ITwapObserver
    uint8 public constant MIN_CARDINALITY = 2;

    /// @inheritdoc ITwapObserver
    uint8 public constant MAX_CARDINALITY = 255;

    /// @dev Length of an `abi.encode(uint32, uint16)` config.
    uint256 private constant CONFIG_BYTES = 64;

    /// @dev Timestamp written in the slots a growth reserves, so that later recordings overwrite a non-zero slot.
    uint32 private constant PLACEHOLDER_TIMESTAMP = 1;

    /// @dev Per-pool binding and ring cursor; `hook == address(0)` marks an unbound pool.
    mapping(PoolId poolId => PoolState state) internal _pools;

    /// @dev Per-pool ring of observations; only the first `cardinalityNext` slots are ever written.
    mapping(PoolId poolId => Observation[MAX_CARDINALITY] ring) internal _rings;

    /// @param factory The Frontier `BCTokenFactory`.
    constructor(address factory) HookGated(factory) {}

    /// @inheritdoc IHookObserver
    function onRegisterObserver(PoolId poolId, bytes calldata config) external {
        address hook = address(_registerPool(poolId));
        if (_pools[poolId].hook != address(0)) revert PoolAlreadyBound(poolId);

        uint32 interval = DEFAULT_INTERVAL;
        uint8 cardinality = DEFAULT_CARDINALITY;
        if (config.length != 0) {
            if (config.length != CONFIG_BYTES) revert InvalidConfig();
            (uint256 rawInterval, uint256 rawCardinality) = abi.decode(config, (uint256, uint256));
            if (rawInterval < MIN_INTERVAL || rawInterval > MAX_INTERVAL) revert InvalidConfig();
            if (rawCardinality < MIN_CARDINALITY || rawCardinality > MAX_CARDINALITY) revert InvalidConfig();
            // both fit: bounded above by MAX_INTERVAL and MAX_CARDINALITY
            interval = uint32(rawInterval);
            cardinality = uint8(rawCardinality);
        }

        _pools[poolId] = PoolState({
            hook: hook,
            interval: interval,
            cardinality: cardinality,
            cardinalityNext: cardinality,
            newest: 0,
            count: 0,
            lastTimestamp: 0
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
    function increaseCardinality(PoolId poolId, uint16 cardinalityNext) external {
        PoolState storage state = _pools[poolId];
        if (state.hook == address(0)) revert PoolNotBound(poolId);
        uint8 previous = state.cardinalityNext;
        if (cardinalityNext <= previous || cardinalityNext > MAX_CARDINALITY) {
            revert InvalidCardinalityNext(poolId, cardinalityNext);
        }

        // slots at or above the pending cardinality have never held a recording
        Observation[MAX_CARDINALITY] storage ring = _rings[poolId];
        // writing the new slots is the purpose of the call, paid by its caller
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = previous; i < cardinalityNext; ++i) {
            ring[i] = Observation({timestamp: PLACEHOLDER_TIMESTAMP, tickCumulative: 0});
        }
        // fits: bounded above by MAX_CARDINALITY
        state.cardinalityNext = uint8(cardinalityNext);
        emit CardinalityIncreased(poolId, previous, uint8(cardinalityNext));
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
        if (average < type(int24).min || average > type(int24).max) revert AverageTickOutOfRange(average);
        // checked just above
        // aderyn-ignore-next-line(unsafe-casting)
        averageTick = int24(average);
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
    /// once the ring is full; a pending growth applies when the newest sits in the last slot.
    function _record(PoolId poolId, PoolState memory state) internal {
        // only the cumulative is stored, the current tick is not
        // slither-disable-next-line unused-return
        (int56 tickCumulative,) = IFactoryHook(state.hook).observe(poolId);
        if (block.timestamp > type(uint32).max) revert TimestampOverflow();
        // checked just above
        uint32 timestamp = uint32(block.timestamp);

        // starts at zero, the first slot
        // slither-disable-next-line uninitialized-local
        uint256 slot;
        if (state.count != 0) {
            // a ring cursor compared to the last slot, not a balance
            // slither-disable-next-line incorrect-equality
            if (state.newest == state.cardinality - 1 && state.cardinalityNext > state.cardinality) {
                state.cardinality = state.cardinalityNext;
            }
            // ring index arithmetic in 256 bits, not randomness; the result is below cardinality, so fits uint8
            // slither-disable-next-line weak-prng
            slot = (uint256(state.newest) + 1) % state.cardinality;
        }
        _rings[poolId][slot] = Observation({timestamp: timestamp, tickCumulative: tickCumulative});

        // slot < cardinality <= MAX_CARDINALITY
        // aderyn-ignore-next-line(unsafe-casting)
        state.newest = uint8(slot);
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
