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

    TwapObserver internal observer;
    MockBCToken internal tCoin;
    PoolId internal pid;

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
    }

    function test_register_acceptsTheBounds() public {
        (, PoolId low) = _deployBound(_cfg(1 minutes, 2));
        assertEq(observer.poolState(low).interval, 60, "min interval");
        assertEq(observer.poolState(low).cardinality, 2, "min cardinality");
        (, PoolId high) = _deployBound(_cfg(1 days, 64));
        assertEq(observer.poolState(high).interval, 86_400, "max interval");
        assertEq(observer.poolState(high).cardinality, 64, "max cardinality");
    }

    function test_RevertWhen_configIsOutOfBoundsOrMalformed() public {
        bytes memory err = abi.encodeWithSelector(ITwapObserver.InvalidConfig.selector);
        _expectRefused(_cfg(59, 16), err);
        _expectRefused(_cfg(1 days + 1, 16), err);
        _expectRefused(_cfg(0, 16), err);
        _expectRefused(_cfg(300, 1), err);
        _expectRefused(_cfg(300, 0), err);
        _expectRefused(_cfg(300, 65), err);
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

    function testFuzz_consult_binarySearchMatchesALinearScan(
        uint16 cardinality,
        uint16 records,
        uint256 seed,
        uint32 secondsAgo
    ) public {
        cardinality = uint16(bound(cardinality, 2, 64));
        records = uint16(bound(records, 1, 150));
        (MockBCToken token, PoolId p) = _deployBound(_cfg(60, cardinality));
        for (uint256 i; i < records; ++i) {
            if (uint256(keccak256(abi.encode(seed, i, "swap"))) % 4 == 0) _buy(token, 0.01 ether);
            else observer.record(p);
            _warp(60 + uint256(keccak256(abi.encode(seed, i))) % 240);
        }
        ITwapObserver.PoolState memory s = observer.poolState(p);
        assertEq(s.count, records < cardinality ? records : cardinality, "count");
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
}
