// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookGated} from "kit/HookGated.sol";
import {HookPayload} from "kit/HookPayload.sol";

import {ITwapObserver} from "contracts/twap-observer/ITwapObserver.sol";
import {TwapObserver} from "contracts/twap-observer/TwapObserver.sol";

/// @dev Runs against Frontier's real `FactoryHook` (from the kit's lib/factory-hook) on a local Uniswap v4
/// stack: the observer is bound at deploy and fed by real swaps and by `record`.
contract TwapObserverTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    uint24 internal constant BASE_FEE = 3000;
    uint256 internal constant START = 1_700_000_000;

    /// @dev `onAfterSwap` with nothing to record, the observer cold.
    uint256 internal constant NO_OP_GAS_CEILING = 5000;

    /// @dev `onAfterSwap` writing a fresh ring slot, the observer cold.
    uint256 internal constant RECORDING_GAS_CEILING = 32_000;

    /// @dev `onAfterSwap` writing a slot pre-written by a growth, the observer cold.
    uint256 internal constant PREWRITTEN_RECORDING_GAS_CEILING = 12_000;

    /// @dev `increaseCardinality` per added slot.
    uint256 internal constant GROWTH_GAS_PER_SLOT_CEILING = 23_000;

    /// @dev `consult` on a full 255-slot ring, the observer cold.
    uint256 internal constant CONSULT_255_GAS_CEILING = 38_000;

    /// @dev Reference model of a ring's cursor, mirrored step by step in the fuzz.
    struct RingModel {
        uint256 cardinality;
        uint256 cardinalityNext;
        uint256 newest;
        uint256 count;
    }

    TwapObserver internal observer;
    MockBCToken internal tCoin;
    PoolId internal pid;

    /// @dev Timestamps of every observation recorded on a pool, oldest first.
    mapping(PoolId poolId => uint256[] timestamps) internal _history;

    function setUp() public override {
        super.setUp();
        vm.warp(START);
        observer = new TwapObserver(address(factory));
        (tCoin, pid) = _deployBound("");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _cfg(uint32 interval, uint16 cardinality) internal pure returns (bytes memory) {
        return abi.encode(interval, cardinality);
    }

    function _noStaking() internal pure returns (IBCTokenFactory.StakingConfig memory) {
        return IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)});
    }

    function _payloadWith(bytes memory config) internal view returns (IFactoryHook.HookConfigV2 memory) {
        return HookPayload.withFee(BASE_FEE).addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, config);
    }

    /// @dev A graduated coin binding the observer with `config`.
    function _deployBound(bytes memory config) internal returns (MockBCToken deployed, PoolId poolId) {
        return _deployGraduated(_payloadWith(config), false);
    }

    /// @dev Expects the deploy of a fresh coin binding the observer with `config` to revert with `err`.
    function _expectRefused(bytes memory config, bytes memory err) internal {
        MockBCToken token = _newCoin("Refused", "BAD");
        vm.expectRevert(err);
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(_payloadWith(config)));
    }

    function _buy(MockBCToken token, uint256 ethIn) internal {
        _swapEthForCoin(address(token), users.buyerTwo, ethIn);
    }

    function _sell(MockBCToken token, uint256 coinIn) internal {
        _swapCoinForEth(address(token), users.buyerOne, coinIn);
    }

    function _cumulative(PoolId poolId) internal view returns (int56 cumulative) {
        (cumulative,) = hook.observe(poolId);
    }

    function _tick(PoolId poolId) internal view returns (int24 tick) {
        (, tick) = hook.observe(poolId);
    }

    function _count(PoolId poolId) internal view returns (uint256) {
        return observer.poolState(poolId).count;
    }

    function _warp(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
    }

    function _floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if (a % b != 0 && (a < 0) != (b < 0)) --q;
    }

    function _notEnoughHistory(PoolId poolId, uint32 secondsAgo) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ITwapObserver.NotEnoughHistory.selector, poolId, secondsAgo);
    }

    /// @dev Records on `poolId` (which must be due), logs the timestamp, then warps one 60 s interval.
    function _rec(PoolId poolId) internal {
        assertTrue(observer.record(poolId), "recorded");
        _history[poolId].push(block.timestamp);
        _warp(60);
    }

    /// @dev The kept observations are exactly the last `count` recorded, in order, and none is a placeholder.
    function _assertKeptInOrder(PoolId poolId) internal view {
        uint256[] storage history = _history[poolId];
        ITwapObserver.PoolState memory s = observer.poolState(poolId);
        assertLe(s.count, history.length, "count");
        for (uint256 i; i < s.count; ++i) {
            uint256 timestamp = observer.observationAt(poolId, i).timestamp;
            assertEq(timestamp, history[history.length - s.count + i], "observation in order");
            assertTrue(timestamp != 1, "never a placeholder");
        }
        if (s.count != 0) {
            assertEq(observer.latestObservation(poolId).timestamp, history[history.length - 1], "latest");
        }
    }

    /// @dev `consult` reaches every kept observation at its exact age, and nothing older.
    function _assertConsultReachesEveryObservation(PoolId poolId) internal {
        ITwapObserver.PoolState memory s = observer.poolState(poolId);
        for (uint256 i; i < s.count; ++i) {
            uint32 age = uint32(block.timestamp - observer.observationAt(poolId, i).timestamp);
            if (age == 0) continue;
            (, uint32 span) = observer.consult(poolId, age);
            assertEq(span, age, "consult picks the observation of that age");
        }
        uint32 beyond = uint32(block.timestamp - observer.observationAt(poolId, 0).timestamp + 1);
        vm.expectRevert(_notEnoughHistory(poolId, beyond));
        observer.consult(poolId, beyond);
    }

    function _expectGrowthRefused(PoolId poolId, uint16 cardinalityNext) internal {
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.InvalidCardinalityNext.selector, poolId, cardinalityNext));
        observer.increaseCardinality(poolId, cardinalityNext);
    }

    /// @dev Marks the account and its storage cold (the `cool` cheatcode, absent from this forge-std's `Vm`).
    function _cool(address target) internal {
        (bool ok,) = address(vm).call(abi.encodeWithSignature("cool(address)", target));
        assertTrue(ok, "cool cheatcode");
    }

    // ---------------------------------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------------------------------

    function test_register_emptyConfigBindsTheDefaults() public view {
        ITwapObserver.PoolState memory s = observer.poolState(pid);
        assertEq(s.hook, address(hook), "hook");
        assertEq(s.interval, 5 minutes, "interval");
        assertEq(s.cardinality, 16, "cardinality");
        assertEq(s.cardinalityNext, 16, "nothing pending");
        assertEq(s.count, 0, "nothing stored at graduation");
        assertEq(s.lastTimestamp, 0, "no timestamp");
        assertEq(observer.hookOf(pid), address(hook), "pinned hook");
        assertEq(observer.DEFAULT_INTERVAL(), 5 minutes, "default interval");
        assertEq(observer.DEFAULT_CARDINALITY(), 16, "default cardinality");
    }

    function test_register_bindsAConfigAndEmits() public {
        MockBCToken token = _newCoin("Configured", "CFG");
        PoolId poolId = _poolId(address(token));
        vm.expectEmit(true, true, false, true, address(observer));
        emit ITwapObserver.PoolBound(poolId, address(hook), 90, 7);
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(_payloadWith(_cfg(90, 7))));

        ITwapObserver.PoolState memory s = observer.poolState(poolId);
        assertEq(s.hook, address(hook), "hook");
        assertEq(s.interval, 90, "interval");
        assertEq(s.cardinality, 7, "cardinality");
        assertEq(s.cardinalityNext, 7, "cardinality next");
    }

    function test_register_acceptsTheBounds() public {
        (, PoolId low) = _deployBound(_cfg(1 minutes, 2));
        assertEq(observer.poolState(low).interval, 60, "min interval");
        assertEq(observer.poolState(low).cardinality, 2, "min cardinality");
        (, PoolId high) = _deployBound(_cfg(1 days, 255));
        assertEq(observer.poolState(high).interval, 86_400, "max interval");
        assertEq(observer.poolState(high).cardinality, 255, "max cardinality");
        assertEq(observer.MAX_CARDINALITY(), 255, "max constant");
    }

    function test_RevertWhen_configIsOutOfBoundsOrMalformed() public {
        bytes memory err = abi.encodeWithSelector(ITwapObserver.InvalidConfig.selector);
        _expectRefused(_cfg(59, 16), err);
        _expectRefused(_cfg(1 days + 1, 16), err);
        _expectRefused(_cfg(0, 16), err);
        _expectRefused(_cfg(300, 1), err);
        _expectRefused(_cfg(300, 0), err);
        _expectRefused(_cfg(300, 256), err);
        _expectRefused(abi.encode(uint256(type(uint32).max) + 300, uint16(16)), err);
        _expectRefused(abi.encode(uint32(300), uint256(type(uint16).max) + 17), err);
        _expectRefused(abi.encode(uint32(300)), err);
        _expectRefused(abi.encode(uint32(300), uint16(16), uint256(0)), err);
        _expectRefused(hex"01", err);
    }

    function test_RevertWhen_boundTwiceInOneDeploy() public {
        MockBCToken token = _newCoin("Twice", "BAD");
        IFactoryHook.HookConfigV2 memory config =
            _payloadWith("").addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, "");
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.PoolAlreadyBound.selector, _poolId(address(token))));
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(config));
    }

    function test_RevertWhen_boundAgainByTheHook() public {
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.PoolAlreadyBound.selector, pid));
        observer.onRegisterObserver(pid, _cfg(60, 2));
    }

    function test_RevertWhen_registeredByAnyoneButTheHook() public {
        PoolId fresh = PoolId.wrap(keccak256("a pool id computed before its coin exists"));
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotCurrentHook.selector, address(this)));
        observer.onRegisterObserver(fresh, "");
    }

    function test_RevertWhen_notificationsNotFromPoolHook() public {
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, address(this)));
        observer.onAfterSwap(pid, toBalanceDelta(-1, 1), 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, address(this)));
        observer.onFeeChange(pid, 0, 0);

        PoolId unbound = PoolId.wrap(keccak256("unbound"));
        vm.startPrank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, address(hook)));
        observer.onAfterSwap(unbound, toBalanceDelta(-1, 1), 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, address(hook)));
        observer.onFeeChange(unbound, 0, 0);
        vm.stopPrank();
    }

    function test_onFeeChange_storesNothing() public {
        vm.prank(address(hook));
        observer.onFeeChange(pid, 3000, 5000);
        assertEq(_count(pid), 0, "nothing stored");
    }

    // ---------------------------------------------------------------------------------------------
    // Recording
    // ---------------------------------------------------------------------------------------------

    function test_swap_recordsTheFirstObservation() public {
        _buy(tCoin, 0.1 ether);
        ITwapObserver.PoolState memory s = observer.poolState(pid);
        assertEq(s.count, 1, "one observation");
        assertEq(s.lastTimestamp, block.timestamp, "last timestamp");
        ITwapObserver.Observation memory o = observer.latestObservation(pid);
        assertEq(o.timestamp, block.timestamp, "timestamp");
        assertEq(o.tickCumulative, _cumulative(pid), "cumulative");
    }

    function test_swap_storesTheReadingTakenRightAfterTheSwap() public {
        observer.record(pid);
        _warp(400);
        (int56 beforeSwap, int24 tickBefore) = hook.observe(pid);
        _buy(tCoin, 1 ether);
        (int56 afterSwap, int24 tickAfter) = hook.observe(pid);

        assertTrue(tickAfter != tickBefore, "the swap moved the oracle tick");
        assertEq(afterSwap, beforeSwap, "the swap's own tick has not accrued yet");
        ITwapObserver.Observation memory o = observer.latestObservation(pid);
        assertEq(o.timestamp, block.timestamp, "stored in the swap");
        assertEq(o.tickCumulative, afterSwap, "observer reading equals the reading after the swap");
    }

    function test_swap_doesNotRecordBeforeTheInterval() public {
        _buy(tCoin, 0.1 ether);
        _buy(tCoin, 0.1 ether);
        assertEq(_count(pid), 1, "same block");
        _warp(5 minutes - 1);
        _sell(tCoin, 1_000_000 ether);
        assertEq(_count(pid), 1, "one second short");
        _warp(1);
        _buy(tCoin, 0.1 ether);
        assertEq(_count(pid), 2, "due");
        assertEq(observer.latestObservation(pid).timestamp, START + 5 minutes, "timestamp");
    }

    function test_ring_wrapsAndOverwritesTheOldest() public {
        (, PoolId p) = _deployBound(_cfg(60, 3));
        for (uint256 i; i < 5; ++i) {
            assertTrue(observer.record(p), "recorded");
            _warp(60);
        }
        ITwapObserver.PoolState memory s = observer.poolState(p);
        assertEq(s.count, 3, "full");
        assertEq(s.newest, 1, "slots 0, 1, 2, 0, 1");
        assertEq(s.lastTimestamp, START + 240, "last timestamp");
        assertEq(observer.observationAt(p, 0).timestamp, START + 120, "oldest kept");
        assertEq(observer.observationAt(p, 1).timestamp, START + 180, "middle");
        assertEq(observer.observationAt(p, 2).timestamp, START + 240, "newest");
        assertEq(observer.latestObservation(p).timestamp, START + 240, "latest");
    }

    function test_record_byAStrangerRespectsTheInterval() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        assertTrue(observer.record(pid), "first");
        assertFalse(observer.record(pid), "same block");
        _warp(5 minutes - 1);
        assertFalse(observer.record(pid), "too early");
        _warp(1);
        assertTrue(observer.record(pid), "due");
        vm.stopPrank();
        assertEq(_count(pid), 2, "two observations");
        assertEq(observer.latestObservation(pid).tickCumulative, _cumulative(pid), "cumulative");
    }

    function test_RevertWhen_recordOnAnUnboundPool() public {
        PoolId unbound = PoolId.wrap(keccak256("unbound"));
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.PoolNotBound.selector, unbound));
        observer.record(unbound);
    }

    function test_RevertWhen_recordBeforeGraduation() public {
        MockBCToken curve = _deployCoin("Curve", "CRV", 50, _noStaking(), HookPayload.encode(_payloadWith("")));
        PoolId poolId = _poolId(address(curve));
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.PoolNotGraduated.selector, poolId));
        observer.record(poolId);
    }

    function test_pools_stayIndependent() public {
        (MockBCToken other, PoolId otherId) = _deployBound(_cfg(60, 2));
        _buy(tCoin, 0.1 ether);
        assertEq(_count(pid), 1, "swapped pool");
        assertEq(_count(otherId), 0, "other pool untouched");

        _warp(60);
        _buy(other, 0.1 ether);
        _buy(tCoin, 0.1 ether);
        assertEq(_count(otherId), 1, "other pool");
        assertEq(_count(pid), 1, "its own interval");
        assertEq(observer.latestObservation(otherId).tickCumulative, _cumulative(otherId), "own cumulative");
        assertEq(observer.poolState(pid).interval, 5 minutes, "own interval");
        assertEq(observer.poolState(otherId).interval, 60, "other interval");
    }

    // ---------------------------------------------------------------------------------------------
    // Consult
    // ---------------------------------------------------------------------------------------------

    function test_consult_flatPriceEqualsTheTick() public {
        observer.record(pid);
        _warp(30 minutes);
        (int24 average, uint32 span) = observer.consult(pid, 30 minutes);
        assertEq(span, 30 minutes, "span");
        assertEq(average, _tick(pid), "the tick that never moved");
    }

    function test_consult_timeWeightsTheSwaps() public {
        observer.record(pid);
        int56 c0 = _cumulative(pid);
        int24 a = _tick(pid);
        _warp(10 minutes);
        _buy(tCoin, 0.5 ether);
        int24 b = _tick(pid);
        assertTrue(a != b, "price moved");
        _warp(20 minutes);
        _sell(tCoin, 5_000_000 ether);
        int24 c = _tick(pid);
        _warp(5 minutes);

        (int24 average, uint32 span) = observer.consult(pid, 35 minutes);
        int256 sum = int256(a) * 600 + int256(b) * 1200 + int256(c) * 300;
        assertEq(span, 35 minutes, "span");
        assertEq(int256(_cumulative(pid)) - c0, sum, "cumulative accrued tick by tick");
        assertEq(int256(average), _floorDiv(sum, 2100), "hand computation");
    }

    function test_consult_largeSwapRightBeforeTheReadBarelyMovesIt() public {
        observer.record(pid);
        int24 a = _tick(pid);
        _warp(30 minutes);
        _buy(tCoin, 3 ether);
        int24 b = _tick(pid);
        assertGt(int256(a) - int256(b), 1000, "large move");

        (int24 sameBlock,) = observer.consult(pid, 30 minutes);
        assertEq(sameBlock, a, "the swap has not accrued in its own block");

        _warp(1);
        (int24 average, uint32 span) = observer.consult(pid, 30 minutes);
        assertEq(span, 30 minutes + 1, "span");
        assertEq(int256(average), _floorDiv(int256(a) * 1800 + int256(b), 1801), "hand computation");
        assertLe(int256(a) - int256(average), (int256(a) - int256(b)) / 1801 + 1, "barely moved");
    }

    function test_consult_picksTheNewestObservationAtLeastSecondsAgoOld() public {
        (, PoolId p) = _deployBound(_cfg(60, 8));
        observer.record(p);
        _warp(300);
        observer.record(p);
        _warp(300);
        observer.record(p);
        _warp(100);

        uint32 span;
        (, span) = observer.consult(p, 1);
        assertEq(span, 100, "newest");
        (, span) = observer.consult(p, 100);
        assertEq(span, 100, "exactly the newest's age");
        (, span) = observer.consult(p, 101);
        assertEq(span, 400, "one second older");
        (, span) = observer.consult(p, 400);
        assertEq(span, 400, "exactly the middle's age");
        (, span) = observer.consult(p, 401);
        assertEq(span, 700, "the oldest");
        (, span) = observer.consult(p, 700);
        assertEq(span, 700, "exactly the oldest's age");
        vm.expectRevert(_notEnoughHistory(p, 701));
        observer.consult(p, 701);
    }

    function test_RevertWhen_consultBeforeEnoughHistory() public {
        vm.expectRevert(_notEnoughHistory(pid, 60));
        observer.consult(pid, 60);

        observer.record(pid);
        _warp(1000);
        vm.expectRevert(_notEnoughHistory(pid, 30 minutes));
        observer.consult(pid, 30 minutes);
        vm.expectRevert(_notEnoughHistory(pid, type(uint32).max));
        observer.consult(pid, type(uint32).max);
    }

    function test_RevertWhen_consultAfterTheRingForgot() public {
        (, PoolId p) = _deployBound(_cfg(60, 2));
        observer.record(p);
        _warp(60);
        observer.record(p);
        _warp(60);
        observer.record(p);

        vm.expectRevert(_notEnoughHistory(p, 120));
        observer.consult(p, 120);
        (, uint32 span) = observer.consult(p, 60);
        assertEq(span, 60, "the oldest kept");
    }

    function test_RevertWhen_consultZeroSecondsAgo() public {
        observer.record(pid);
        vm.expectRevert(ITwapObserver.ZeroSecondsAgo.selector);
        observer.consult(pid, 0);
    }

    function test_RevertWhen_consultAnUnboundPool() public {
        PoolId unbound = PoolId.wrap(keccak256("unbound"));
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.PoolNotBound.selector, unbound));
        observer.consult(unbound, 60);
    }

    function test_consult_roundsTowardNegativeInfinity() public {
        bytes memory observeCall = abi.encodeCall(IFactoryHook.observe, (pid));
        vm.mockCall(address(hook), observeCall, abi.encode(int56(1000), int24(0)));
        observer.record(pid);
        _warp(7);

        vm.mockCall(address(hook), observeCall, abi.encode(int56(990), int24(0)));
        (int24 average,) = observer.consult(pid, 7);
        assertEq(average, -2, "-10 / 7 rounds down to -2");

        vm.mockCall(address(hook), observeCall, abi.encode(int56(986), int24(0)));
        (average,) = observer.consult(pid, 7);
        assertEq(average, -2, "-14 / 7 is exact");

        vm.mockCall(address(hook), observeCall, abi.encode(int56(1010), int24(0)));
        (average,) = observer.consult(pid, 7);
        assertEq(average, 1, "10 / 7 rounds down to 1");
        vm.clearMockedCalls();
    }

    function test_RevertWhen_consultAverageDoesNotFitATick() public {
        bytes memory observeCall = abi.encodeCall(IFactoryHook.observe, (pid));
        vm.mockCall(address(hook), observeCall, abi.encode(int56(0), int24(0)));
        observer.record(pid);
        _warp(1);

        int56 tooHigh = int56(type(int24).max) + 1;
        vm.mockCall(address(hook), observeCall, abi.encode(tooHigh, int24(0)));
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.AverageTickOutOfRange.selector, int256(tooHigh)));
        observer.consult(pid, 1);

        int56 tooLow = int56(type(int24).min) - 1;
        vm.mockCall(address(hook), observeCall, abi.encode(tooLow, int24(0)));
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.AverageTickOutOfRange.selector, int256(tooLow)));
        observer.consult(pid, 1);
        vm.clearMockedCalls();
    }

    function test_RevertWhen_recordPastTheLastTimestampAnObservationHolds() public {
        vm.warp(uint256(type(uint32).max) + 1);
        vm.expectRevert(ITwapObserver.TimestampOverflow.selector);
        observer.record(pid);
    }

    function testFuzz_consult_binarySearchMatchesALinearScan(
        uint16 cardinality,
        uint16 records,
        uint256 seed,
        uint32 secondsAgo
    ) public {
        cardinality = uint16(bound(cardinality, 2, 64));
        records = uint16(bound(records, 1, 150));
        (MockBCToken token, PoolId p) = _deployBound(_cfg(60, cardinality));
        RingModel memory m = RingModel({cardinality: cardinality, cardinalityNext: cardinality, newest: 0, count: 0});
        for (uint256 i; i < records; ++i) {
            uint256 roll = uint256(keccak256(abi.encode(seed, i, "action")));
            if (roll % 7 == 0 && m.cardinalityNext < 255) {
                m.cardinalityNext = bound(
                    roll >> 8, m.cardinalityNext + 1, m.cardinalityNext + 40 > 255 ? 255 : m.cardinalityNext + 40
                );
                observer.increaseCardinality(p, uint16(m.cardinalityNext));
            }
            if (roll % 4 == 0) _buy(token, 0.01 ether);
            else observer.record(p);
            _history[p].push(block.timestamp);
            if (m.count != 0 && m.newest == m.cardinality - 1 && m.cardinalityNext > m.cardinality) {
                m.cardinality = m.cardinalityNext;
            }
            m.newest = m.count == 0 ? 0 : (m.newest + 1) % m.cardinality;
            if (m.count < m.cardinality) ++m.count;
            _warp(60 + uint256(keccak256(abi.encode(seed, i))) % 240);
        }
        ITwapObserver.PoolState memory s = observer.poolState(p);
        assertEq(s.count, m.count, "count");
        assertEq(s.cardinality, m.cardinality, "cardinality");
        assertEq(s.cardinalityNext, m.cardinalityNext, "cardinality next");
        assertEq(s.newest, m.newest, "newest");
        _assertKeptInOrder(p);
        secondsAgo = uint32(bound(secondsAgo, 1, block.timestamp - START + 300));

        uint256 target = block.timestamp - secondsAgo;
        ITwapObserver.Observation memory chosen;
        for (uint256 i = s.count; i > 0; --i) {
            ITwapObserver.Observation memory o = observer.observationAt(p, i - 1);
            if (o.timestamp <= target) {
                chosen = o;
                break;
            }
        }
        if (chosen.timestamp == 0) {
            vm.expectRevert(_notEnoughHistory(p, secondsAgo));
            observer.consult(p, secondsAgo);
            return;
        }
        (int24 average, uint32 span) = observer.consult(p, secondsAgo);
        assertEq(span, block.timestamp - chosen.timestamp, "same observation as the linear scan");
        assertGe(span, secondsAgo, "at least secondsAgo");
        assertEq(
            int256(average),
            _floorDiv(int256(_cumulative(p)) - chosen.tickCumulative, int256(uint256(span))),
            "average over the span"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Growth
    // ---------------------------------------------------------------------------------------------

    function test_grow_byAStranger() public {
        vm.expectEmit(true, false, false, true, address(observer));
        emit ITwapObserver.CardinalityIncreased(pid, 16, 20);
        vm.prank(makeAddr("stranger"));
        observer.increaseCardinality(pid, 20);

        ITwapObserver.PoolState memory s = observer.poolState(pid);
        assertEq(s.cardinality, 16, "applied later");
        assertEq(s.cardinalityNext, 20, "pending");
        assertEq(s.count, 0, "nothing recorded");
    }

    function test_RevertWhen_growthIsNotAnIncreaseOrAboveTheMaximum() public {
        _expectGrowthRefused(pid, 16);
        _expectGrowthRefused(pid, 15);
        _expectGrowthRefused(pid, 0);
        _expectGrowthRefused(pid, 256);
        _expectGrowthRefused(pid, type(uint16).max);

        observer.increaseCardinality(pid, 20);
        _expectGrowthRefused(pid, 20);
        _expectGrowthRefused(pid, 18);
        observer.increaseCardinality(pid, 255);
        _expectGrowthRefused(pid, 255);
        _expectGrowthRefused(pid, 256);
    }

    function test_RevertWhen_growingAnUnboundPool() public {
        PoolId unbound = PoolId.wrap(keccak256("unbound"));
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.PoolNotBound.selector, unbound));
        observer.increaseCardinality(unbound, 20);
    }

    function test_grow_beforeAnyObservation() public {
        (, PoolId p) = _deployBound(_cfg(60, 2));
        observer.increaseCardinality(p, 4);
        _rec(p);
        _rec(p);
        assertEq(observer.poolState(p).cardinality, 2, "the last slot was just written");
        _rec(p);
        assertEq(observer.poolState(p).cardinality, 4, "applied on the next write");
        _assertKeptInOrder(p);
        _rec(p);
        _rec(p);
        _rec(p);
        assertEq(observer.poolState(p).count, 4, "full at the new size");
        _assertKeptInOrder(p);
        _assertConsultReachesEveryObservation(p);
    }

    function test_grow_whileTheRingIsPartlyFilled() public {
        (, PoolId p) = _deployBound(_cfg(60, 4));
        _rec(p);
        _rec(p);
        observer.increaseCardinality(p, 6);
        for (uint256 i; i < 8; ++i) {
            _rec(p);
            _assertKeptInOrder(p);
        }
        ITwapObserver.PoolState memory s = observer.poolState(p);
        assertEq(s.cardinality, 6, "grown");
        assertEq(s.count, 6, "full at the new size");
        _assertConsultReachesEveryObservation(p);
    }

    function test_grow_whileFullAndWrapped_appliesAtTheEndOfTheLap() public {
        (, PoolId p) = _deployBound(_cfg(60, 4));
        for (uint256 i; i < 6; ++i) {
            _rec(p);
        }
        assertEq(observer.poolState(p).newest, 1, "wrapped: slots 0, 1, 2, 3, 0, 1");
        observer.increaseCardinality(p, 7);
        _assertKeptInOrder(p);
        _assertConsultReachesEveryObservation(p);

        _rec(p);
        assertEq(observer.poolState(p).cardinality, 4, "mid-lap: not applied");
        assertEq(observer.poolState(p).count, 4, "still four kept");
        _assertKeptInOrder(p);
        _assertConsultReachesEveryObservation(p);

        _rec(p);
        assertEq(observer.poolState(p).newest, 3, "last slot written");
        assertEq(observer.poolState(p).cardinality, 4, "not applied yet");
        _assertKeptInOrder(p);
        _assertConsultReachesEveryObservation(p);

        _rec(p);
        ITwapObserver.PoolState memory s = observer.poolState(p);
        assertEq(s.cardinality, 7, "applied at the end of the lap");
        assertEq(s.newest, 4, "continues into the new slots");
        assertEq(s.count, 5, "nothing overwritten");
        _assertKeptInOrder(p);
        _assertConsultReachesEveryObservation(p);

        for (uint256 i; i < 4; ++i) {
            _rec(p);
            _assertKeptInOrder(p);
        }
        assertEq(observer.poolState(p).count, 7, "full at the new size");
        _assertConsultReachesEveryObservation(p);
    }

    function test_grow_severalInARowAndWhilePending() public {
        (, PoolId p) = _deployBound(_cfg(60, 3));
        observer.increaseCardinality(p, 4);
        observer.increaseCardinality(p, 6);
        _rec(p);
        _rec(p);
        _rec(p);
        assertEq(observer.poolState(p).cardinality, 3, "pending");
        _rec(p);
        assertEq(observer.poolState(p).cardinality, 6, "the latest request applies at once");
        observer.increaseCardinality(p, 8);
        assertEq(observer.poolState(p).cardinality, 6, "requested while another lap runs");
        for (uint256 i; i < 10; ++i) {
            _rec(p);
            _assertKeptInOrder(p);
        }
        ITwapObserver.PoolState memory s = observer.poolState(p);
        assertEq(s.cardinality, 8, "second growth applied");
        assertEq(s.count, 8, "full");
        _assertConsultReachesEveryObservation(p);
    }

    function test_grow_consultIsUnchangedByAGrowth() public {
        (MockBCToken token, PoolId p) = _deployBound(_cfg(60, 4));
        for (uint256 i; i < 6; ++i) {
            _buy(token, 0.05 ether);
            _history[p].push(block.timestamp);
            _warp(70);
        }
        (int24 averageBefore, uint32 spanBefore) = observer.consult(p, 150);
        observer.increaseCardinality(p, 10);
        (int24 averageAfter, uint32 spanAfter) = observer.consult(p, 150);
        assertEq(averageAfter, averageBefore, "average");
        assertEq(spanAfter, spanBefore, "span");
        _assertKeptInOrder(p);
    }

    function test_grow_keepsMoreHistory() public {
        (, PoolId small) = _deployBound(_cfg(60, 2));
        (, PoolId grown) = _deployBound(_cfg(60, 2));
        observer.increaseCardinality(grown, 4);
        uint256 first = block.timestamp;
        for (uint256 i; i < 4; ++i) {
            observer.record(small);
            observer.record(grown);
            _warp(60);
        }
        uint32 age = uint32(block.timestamp - first);
        (, uint32 span) = observer.consult(grown, age);
        assertEq(span, age, "the first observation is still reachable");
        assertEq(observer.observationAt(grown, 0).timestamp, first, "oldest kept");
        vm.expectRevert(_notEnoughHistory(small, age));
        observer.consult(small, age);
    }

    function test_grow_placeholdersAreNeverRead() public {
        (, PoolId p) = _deployBound(_cfg(60, 2));
        observer.increaseCardinality(p, 255);

        assertEq(observer.latestObservation(p).timestamp, 0, "empty ring");
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.ObservationOutOfRange.selector, p, 0));
        observer.observationAt(p, 0);
        vm.expectRevert(_notEnoughHistory(p, 1));
        observer.consult(p, 1);

        _rec(p);
        _rec(p);
        _assertKeptInOrder(p);
        _rec(p);
        assertEq(observer.poolState(p).cardinality, 255, "applied");
        // the slot just written held a placeholder (timestamp 1); every other pre-written slot still does
        _assertKeptInOrder(p);
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.ObservationOutOfRange.selector, p, 3));
        observer.observationAt(p, 3);
        // a placeholder at timestamp 1 would satisfy any target; consult still stops at the oldest recording
        _assertConsultReachesEveryObservation(p);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function test_views_emptyRing() public {
        ITwapObserver.Observation memory o = observer.latestObservation(pid);
        assertEq(o.timestamp, 0, "no timestamp");
        assertEq(o.tickCumulative, 0, "no cumulative");
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.ObservationOutOfRange.selector, pid, 0));
        observer.observationAt(pid, 0);
    }

    function test_RevertWhen_observationIndexIsNotBelowTheCount() public {
        observer.record(pid);
        assertEq(observer.observationAt(pid, 0).timestamp, START, "index 0");
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.ObservationOutOfRange.selector, pid, 1));
        observer.observationAt(pid, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------------------------------

    function test_gas_onAfterSwapNoOpPath() public {
        observer.record(pid);
        _warp(5 minutes - 1);
        _cool(address(observer));

        vm.prank(address(hook));
        uint256 before = gasleft();
        observer.onAfterSwap(pid, toBalanceDelta(-1, 1), 3000, 0, "");
        uint256 used = before - gasleft();

        emit log_named_uint("onAfterSwap, nothing due (cold observer)", used);
        assertEq(_count(pid), 1, "nothing recorded");
        assertLt(used, NO_OP_GAS_CEILING, "no-op path");
    }

    function test_gas_onAfterSwapRecordingPath() public {
        observer.record(pid);
        _warp(5 minutes);
        _cool(address(observer));

        vm.prank(address(hook));
        uint256 before = gasleft();
        observer.onAfterSwap(pid, toBalanceDelta(-1, 1), 3000, 0, "");
        uint256 used = before - gasleft();

        emit log_named_uint("onAfterSwap, recording in a fresh slot (cold observer)", used);
        assertEq(_count(pid), 2, "recorded in a fresh slot");
        assertLt(used, RECORDING_GAS_CEILING, "recording path");
    }

    function test_gas_recordAndConsultOnAFullRing() public {
        for (uint256 i; i < 20; ++i) {
            observer.record(pid);
            _warp(5 minutes);
        }
        _cool(address(observer));
        uint256 before = gasleft();
        observer.record(pid);
        uint256 recordGas = before - gasleft();

        _warp(1);
        _cool(address(observer));
        before = gasleft();
        (, uint32 span) = observer.consult(pid, 31 minutes);
        uint256 consultGas = before - gasleft();

        emit log_named_uint("record, overwriting a slot of a full ring (cold observer)", recordGas);
        emit log_named_uint("consult, binary search over 16 slots (cold observer)", consultGas);
        assertEq(span, 35 minutes + 1, "span");
        assertLt(recordGas, RECORDING_GAS_CEILING, "record");
    }

    function test_gas_increaseCardinalityPerSlot() public {
        _cool(address(observer));
        uint256 before = gasleft();
        observer.increaseCardinality(pid, 48);
        uint256 perSlot = (before - gasleft()) / 32;

        emit log_named_uint("increaseCardinality, per added slot (cold observer, 32 slots)", perSlot);
        assertLt(perSlot, GROWTH_GAS_PER_SLOT_CEILING, "per slot");
    }

    function test_gas_onAfterSwapRecordingIntoAPrewrittenSlot() public {
        for (uint256 i; i < 16; ++i) {
            observer.record(pid);
            _warp(5 minutes);
        }
        observer.increaseCardinality(pid, 17);
        _cool(address(observer));

        vm.prank(address(hook));
        uint256 before = gasleft();
        observer.onAfterSwap(pid, toBalanceDelta(-1, 1), 3000, 0, "");
        uint256 used = before - gasleft();

        emit log_named_uint("onAfterSwap, recording into a pre-written slot (cold observer)", used);
        ITwapObserver.PoolState memory s = observer.poolState(pid);
        assertEq(s.newest, 16, "wrote the pre-written slot");
        assertEq(s.count, 17, "count");
        assertLt(used, PREWRITTEN_RECORDING_GAS_CEILING, "overwrite price, not the fresh-slot price");
    }

    function test_gas_consultOnA255SlotRing() public {
        (, PoolId p) = _deployBound(_cfg(60, 255));
        for (uint256 i; i < 260; ++i) {
            observer.record(p);
            _warp(60);
        }
        assertEq(observer.poolState(p).count, 255, "full");
        _cool(address(observer));
        uint256 before = gasleft();
        (, uint32 span) = observer.consult(p, 100 minutes);
        uint256 used = before - gasleft();

        emit log_named_uint("consult, binary search over 255 slots (cold observer)", used);
        assertEq(span, 100 minutes, "span");
        assertLt(used, CONSULT_255_GAS_CEILING, "consult");
    }
}
