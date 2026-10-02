// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {ITwapObserver} from "contracts/twap-observer/ITwapObserver.sol";
import {TwapObserver} from "contracts/twap-observer/TwapObserver.sol";

/// @dev Random buys, sells, time jumps, `record` calls and ring growths on one bound pool. Logs the timestamp of
/// every observation recorded and flags any decrease of the cardinalities.
contract TwapHandler is Test {
    TwapObserver internal immutable OBSERVER;
    PoolSwapTest internal immutable ROUTER;
    PoolId internal immutable POOL_ID;
    PoolKey internal key;

    uint256 public swaps;
    uint256 public growths;
    bool public cardinalityDecreased;
    uint256[] internal _recorded;
    uint256 internal _lastCardinality;
    uint256 internal _lastCardinalityNext;

    constructor(TwapObserver observer, PoolSwapTest router, PoolKey memory poolKey, PoolId poolId) {
        OBSERVER = observer;
        ROUTER = router;
        POOL_ID = poolId;
        key = poolKey;
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(router), type(uint256).max);
    }

    function buy(uint256 ethIn) external {
        ethIn = bound(ethIn, 1e12, 0.5 ether);
        ROUTER.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        ++swaps;
        _track();
    }

    function sell(uint256 coinIn) external {
        coinIn = bound(coinIn, 1 ether, 10_000_000 ether);
        ROUTER.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        ++swaps;
        _track();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 minutes));
    }

    function record() external {
        OBSERVER.record(POOL_ID);
        _track();
    }

    function grow(uint256 by) external {
        uint256 next = OBSERVER.poolState(POOL_ID).cardinalityNext;
        if (next == OBSERVER.MAX_CARDINALITY()) return;
        next += bound(by, 1, 3);
        if (next > OBSERVER.MAX_CARDINALITY()) next = OBSERVER.MAX_CARDINALITY();
        OBSERVER.increaseCardinality(POOL_ID, uint16(next));
        ++growths;
        _track();
    }

    function recordedCount() external view returns (uint256) {
        return _recorded.length;
    }

    function recordedAt(uint256 index) external view returns (uint256) {
        return _recorded[index];
    }

    function _track() internal {
        ITwapObserver.PoolState memory s = OBSERVER.poolState(POOL_ID);
        if (s.count != 0 && (_recorded.length == 0 || _recorded[_recorded.length - 1] != s.lastTimestamp)) {
            _recorded.push(s.lastTimestamp);
        }
        if (s.cardinality < _lastCardinality || s.cardinalityNext < _lastCardinalityNext) cardinalityDecreased = true;
        _lastCardinality = s.cardinality;
        _lastCardinalityNext = s.cardinalityNext;
    }

    receive() external payable {}
}

contract TwapObserverInvariantTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    uint256 internal constant START = 1_700_000_000;
    uint32 internal constant INTERVAL = 60;
    uint16 internal constant CARDINALITY = 4;

    TwapObserver internal observer;
    TwapHandler internal handler;
    PoolId internal pid;

    function setUp() public override {
        super.setUp();
        vm.warp(START);
        observer = new TwapObserver(address(factory));
        MockBCToken token;
        (token, pid) = _deployGraduated(
            HookPayload.withFee(3000)
                .addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, abi.encode(INTERVAL, CARDINALITY)),
            false
        );
        handler = new TwapHandler(observer, swapRouter, _poolKey(address(token)), pid);
        vm.deal(address(handler), 1000 ether);
        vm.prank(users.buyerOne);
        token.transfer(address(handler), 400_000_000 ether);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 40
    function invariant_timestampsStrictlyIncreaseAlongTheRing() public view {
        ITwapObserver.PoolState memory s = observer.poolState(pid);
        assertLe(s.count, s.cardinality, "count within the ring");
        uint256 previous;
        for (uint256 i; i < s.count; ++i) {
            ITwapObserver.Observation memory o = observer.observationAt(pid, i);
            if (i != 0) assertGe(o.timestamp, previous + INTERVAL, "strictly increasing, an interval apart");
            assertLe(o.timestamp, block.timestamp, "not in the future");
            previous = o.timestamp;
        }
        if (s.count != 0) assertEq(s.lastTimestamp, previous, "last timestamp is the newest");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 40
    function invariant_keptObservationsAreTheLastRecordedInOrder() public view {
        ITwapObserver.PoolState memory s = observer.poolState(pid);
        uint256 recorded = handler.recordedCount();
        assertLe(s.count, recorded, "count");
        for (uint256 i; i < s.count; ++i) {
            uint256 timestamp = observer.observationAt(pid, i).timestamp;
            assertEq(timestamp, handler.recordedAt(recorded - s.count + i), "the last recorded, in order");
            assertTrue(timestamp != 1, "never a placeholder");
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 40
    function invariant_cardinalitiesAreOrderedAndNeverDecrease() public view {
        ITwapObserver.PoolState memory s = observer.poolState(pid);
        assertLe(s.count, s.cardinality, "count <= cardinality");
        assertLe(s.cardinality, s.cardinalityNext, "cardinality <= cardinalityNext");
        assertLe(s.cardinalityNext, observer.MAX_CARDINALITY(), "cardinalityNext <= MAX_CARDINALITY");
        assertFalse(handler.cardinalityDecreased(), "never decreases");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 40
    function invariant_consultNeverReturnsASpanBelowSecondsAgo() public view {
        uint32[6] memory ages = [uint32(1), 59, 60, 61, 150, 600];
        for (uint256 i; i < ages.length; ++i) {
            try observer.consult(pid, ages[i]) returns (int24, uint32 span) {
                assertGe(span, ages[i], "span below secondsAgo");
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), ITwapObserver.NotEnoughHistory.selector, "only a lack of history");
            }
        }
    }
}
