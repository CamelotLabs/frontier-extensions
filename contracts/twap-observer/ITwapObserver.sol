// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IHookObserver} from "frontier/interfaces/extensions/IHookObserver.sol";

/**
 * @title ITwapObserver
 * @notice History for the hook's truncated tick oracle: bound on a pool as an after-swap observer, it
 * stores the hook's `observe` reading at most once per `interval` in a ring of `cardinality` slots, so
 * that any contract can read a time-weighted average tick without a keeper.
 * @dev The binding config is empty (5 minutes, 16 slots) or `abi.encode(uint32 interval, uint16 cardinality)`
 * with `interval` in [1 minute, 1 day] and `cardinality` in [2, 255]. Subscribe with `CALL_AFTER_SWAP`.
 * Readings are taken on swaps and through the open `record`; nothing is stored while the pool is idle.
 * The cardinality is the number of observations the ring keeps. Anyone may grow it with `increaseCardinality`,
 * paying for the new slots; it never shrinks, and the interval never changes. A growth takes effect when the
 * ring next writes its last slot, so that the ring continues into the new slots in order.
 */
interface ITwapObserver is IHookObserver {
    /**
     * @notice One pool's binding and ring cursor, packed in one storage slot.
     * @param hook The hook that bound the pool; the only caller of its notifications. Zero when unbound.
     * @param interval Minimum seconds between two stored observations.
     * @param cardinality Number of slots in the pool's ring.
     * @param cardinalityNext Number of slots the ring grows to when it next writes its last slot.
     * @param newest Ring slot of the newest observation (meaningless while `count` is zero).
     * @param count Number of observations stored, at most `cardinality`.
     * @param lastTimestamp Timestamp of the newest observation (zero while `count` is zero).
     */
    struct PoolState {
        address hook;
        uint32 interval;
        uint8 cardinality;
        uint8 cardinalityNext;
        uint8 newest;
        uint8 count;
        uint32 lastTimestamp;
    }

    /**
     * @notice One stored reading of the hook's oracle.
     * @param timestamp The block timestamp of the reading.
     * @param tickCumulative The hook's truncated tick cumulative at `timestamp`.
     */
    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    /**
     * @notice A pool bound the observer.
     * @param poolId The V4 pool id.
     * @param hook The hook that bound it.
     * @param interval Minimum seconds between two stored observations.
     * @param cardinality Number of slots in the pool's ring.
     */
    event PoolBound(PoolId indexed poolId, address indexed hook, uint32 interval, uint8 cardinality);

    /**
     * @notice The ring of a pool was granted more slots, applied when it next writes its last slot.
     * @param poolId The V4 pool id.
     * @param cardinalityNextOld The pending cardinality before the call.
     * @param cardinalityNextNew The pending cardinality after the call.
     */
    event CardinalityIncreased(PoolId indexed poolId, uint8 cardinalityNextOld, uint8 cardinalityNextNew);

    /// @notice The binding config is neither empty nor `(uint32 interval, uint16 cardinality)` within bounds.
    error InvalidConfig();

    /// @notice The pool already bound the observer.
    error PoolAlreadyBound(PoolId poolId);

    /// @notice The pool never bound the observer.
    error PoolNotBound(PoolId poolId);

    /// @notice The pool's coin has not graduated: its oracle does not follow a market yet.
    error PoolNotGraduated(PoolId poolId);

    /// @notice `cardinalityNext` is not above the pool's pending cardinality, or above `MAX_CARDINALITY`.
    error InvalidCardinalityNext(PoolId poolId, uint16 cardinalityNext);

    /// @notice `consult` was asked for a zero span.
    error ZeroSecondsAgo();

    /// @notice No stored observation of the pool is at least `secondsAgo` old.
    error NotEnoughHistory(PoolId poolId, uint32 secondsAgo);

    /// @notice `index` is not below the pool's observation count.
    error ObservationOutOfRange(PoolId poolId, uint256 index);

    /// @notice The average tick computed from the hook's readings does not fit a tick.
    error AverageTickOutOfRange(int256 average);

    /// @notice The block timestamp no longer fits the 32 bits an observation stores.
    error TimestampOverflow();

    // slither-disable-start naming-convention
    // getters of the implementation's UPPER_CASE constants

    /**
     * @notice Interval used when a pool binds with an empty config.
     * @return The interval, in seconds.
     */
    function DEFAULT_INTERVAL() external view returns (uint32);

    /**
     * @notice Cardinality used when a pool binds with an empty config.
     * @return The number of slots.
     */
    function DEFAULT_CARDINALITY() external view returns (uint8);

    /**
     * @notice Shortest interval a pool may bind.
     * @return The interval, in seconds.
     */
    function MIN_INTERVAL() external view returns (uint32);

    /**
     * @notice Longest interval a pool may bind.
     * @return The interval, in seconds.
     */
    function MAX_INTERVAL() external view returns (uint32);

    /**
     * @notice Smallest cardinality a pool may bind.
     * @return The number of slots.
     */
    function MIN_CARDINALITY() external view returns (uint8);

    /**
     * @notice Largest cardinality a pool may bind or grow to.
     * @return The number of slots.
     */
    function MAX_CARDINALITY() external view returns (uint8);

    // slither-disable-end naming-convention

    /**
     * @notice Stores the hook's current reading for a bound, graduated pool if at least `interval` seconds
     * passed since its newest observation; does nothing otherwise. Open to anyone.
     * @param poolId The V4 pool id.
     * @return recorded Whether an observation was stored.
     */
    function record(PoolId poolId) external returns (bool recorded);

    /**
     * @notice Grows a bound pool's ring to `cardinalityNext` slots. Open to anyone; the caller pays for the
     * new slots, which are written with a placeholder now so that recordings into them later cost an
     * overwrite only. The growth takes effect when the ring next writes its current last slot.
     * @dev A placeholder is never returned: only the `count` positions holding recorded observations are read.
     * @param poolId The V4 pool id.
     * @param cardinalityNext The new number of slots, above the pending one and at most `MAX_CARDINALITY`.
     */
    function increaseCardinality(PoolId poolId, uint16 cardinalityNext) external;

    /**
     * @notice The time-weighted average truncated tick from the newest stored observation at least
     * `secondsAgo` old to now, rounded toward negative infinity.
     * @dev Exact for the span it reports, no interpolation: `span >= secondsAgo`, and `span` exceeds
     * `secondsAgo` by less than the gap between the chosen observation and the next one (or than the age of
     * the newest one when that is chosen). Check `span` against your own tolerance.
     * @param poolId The V4 pool id.
     * @param secondsAgo The minimum span to average over, in seconds.
     * @return averageTick The average tick over the span.
     * @return span The seconds actually covered.
     */
    function consult(PoolId poolId, uint32 secondsAgo) external view returns (int24 averageTick, uint32 span);

    /**
     * @notice A pool's binding and ring cursor (all zero when unbound).
     * @param poolId The V4 pool id.
     * @return The pool's state.
     */
    function poolState(PoolId poolId) external view returns (PoolState memory);

    /**
     * @notice A stored observation, by age: index 0 is the oldest, `count - 1` the newest.
     * @param poolId The V4 pool id.
     * @param index The position from the oldest observation.
     * @return The observation.
     */
    function observationAt(PoolId poolId, uint256 index) external view returns (Observation memory);

    /**
     * @notice The newest stored observation (all zero while none is stored).
     * @param poolId The V4 pool id.
     * @return The observation.
     */
    function latestObservation(PoolId poolId) external view returns (Observation memory);
}
