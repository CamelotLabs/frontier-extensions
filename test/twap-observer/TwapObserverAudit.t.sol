// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {GreedyObserver} from "frontier-test/ExtensionMocks.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {ITwapObserver} from "contracts/twap-observer/ITwapObserver.sol";
import {TwapObserver} from "contracts/twap-observer/TwapObserver.sol";

/// @dev Stands in for a later hook generation that kept the `IExtensionHost` surface but not `observe`.
contract HookWithoutObserve {
    address internal immutable COIN;

    constructor(address coin) {
        COIN = coin;
    }

    function hook() external view returns (address) {
        return address(this);
    }

    function poolCoin(PoolId) external view returns (address) {
        return COIN;
    }

    function bind(TwapObserver observer, PoolId poolId) external {
        observer.onRegisterObserver(poolId, "");
    }
}

/// @dev Audit probes: each test settles one question raised during the review.
contract TwapObserverAuditTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    uint256 internal constant START = 1_700_000_000;

    TwapObserver internal observer;

    function setUp() public override {
        super.setUp();
        vm.warp(START);
        observer = new TwapObserver(address(factory));
    }

    function _bound(bytes memory config) internal returns (MockBCToken token, PoolId poolId) {
        return _deployGraduated(
            HookPayload.withFee(3000).addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, config), false
        );
    }

    /// A stranger recording at every interval keeps the reach at (cardinality - 1) * interval:
    /// the `cardinality * interval` the README promises is refused right after each record.
    function test_audit_guaranteedReachIsCardinalityMinusOneIntervals() public {
        (, PoolId pid) = _bound("");
        uint32 interval = observer.DEFAULT_INTERVAL();
        uint16 cardinality = observer.DEFAULT_CARDINALITY();

        address stranger = makeAddr("stranger");
        for (uint256 i; i < 40; ++i) {
            vm.prank(stranger);
            assertTrue(observer.record(pid), "recorded");
            if (i >= cardinality) {
                uint32 promised = uint32(cardinality) * interval;
                vm.expectRevert(abi.encodeWithSelector(ITwapObserver.NotEnoughHistory.selector, pid, promised));
                observer.consult(pid, promised);
                (, uint32 span) = observer.consult(pid, promised - interval);
                assertEq(span, promised - interval, "the reach that holds");
            }
            vm.warp(block.timestamp + interval);
        }
    }

    /// Whether the window in which `cardinality * interval` is refused closes on its own.
    function test_audit_reachGapLastsUntilTheNextIntervalElapses() public {
        (, PoolId pid) = _bound(abi.encode(uint32(60), uint16(4)));
        for (uint256 i; i < 8; ++i) {
            observer.record(pid);
            vm.warp(block.timestamp + 60);
        }
        // newest is 60 s old, oldest 240 s old: 240 is served
        (, uint32 span) = observer.consult(pid, 240);
        assertEq(span, 240, "served while the newest ages");
        observer.record(pid);
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.NotEnoughHistory.selector, pid, uint32(240)));
        observer.consult(pid, 240);
        vm.warp(block.timestamp + 59);
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.NotEnoughHistory.selector, pid, uint32(240)));
        observer.consult(pid, 240);
    }

    /// A greedy observer listed first burns the shared budget: swaps stop feeding the ring.
    function test_audit_greedyObserverListedFirstStarvesTheRing() public {
        GreedyObserver greedy = new GreedyObserver();
        IFactoryHook.HookConfigV2 memory config = HookPayload.withFee(3000)
            .addObserver(address(greedy), HookPayload.CALL_AFTER_SWAP, "")
            .addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, "");
        (MockBCToken token, PoolId pid) = _deployGraduated(config, false);

        _swapEthForCoin(address(token), users.buyerTwo, 0.1 ether);
        vm.warp(block.timestamp + 1 hours);
        _swapEthForCoin(address(token), users.buyerTwo, 0.1 ether);
        assertEq(observer.poolState(pid).count, 0, "swaps recorded nothing");

        assertTrue(observer.record(pid), "the open path still records");
    }

    /// No gas cap lets a swap complete while its due observation is dropped.
    function test_audit_swapperCannotDropADueObservationByGasLimiting() public {
        (MockBCToken token, PoolId pid) = _bound("");
        observer.record(pid);
        vm.warp(block.timestamp + 5 minutes);

        uint256 firstSuccess;
        bool dropped;
        for (uint256 cap = 150_000; cap <= 420_000; cap += 250) {
            uint256 snap = vm.snapshot();
            bool ok = _swapWithGasCap(address(token), users.buyerTwo, 0.01 ether, cap);
            uint256 count = observer.poolState(pid).count;
            vm.revertTo(snap);
            if (ok) {
                if (firstSuccess == 0) firstSuccess = cap;
                if (count != 2) dropped = true;
            }
        }
        emit log_named_uint("min successful gas cap", firstSuccess);
        assertGt(firstSuccess, 0, "some cap succeeds");
        assertFalse(dropped, "no cap completes the swap without the observation");
    }

    /// A hook without `observe` binds without complaint, then can never record nor be consulted.
    function test_audit_hookWithoutObserveBindsThenStaysDead() public {
        MockBCToken token = _newCoin("Later", "GEN");
        token.graduate();
        HookWithoutObserve later = new HookWithoutObserve(address(token));
        PoolId pid = PoolId.wrap(keccak256("a pool of the later generation"));

        vm.mockCall(address(factory), abi.encodeWithSignature("liquidityManager()"), abi.encode(address(later)));
        later.bind(observer, pid);
        vm.clearMockedCalls();

        assertEq(observer.poolState(pid).hook, address(later), "bound");
        vm.expectRevert();
        observer.record(pid);
    }

    /// The time a curve coin spends before graduation never enters an average.
    function test_audit_preGraduationTimeStaysOutOfTheAverage() public {
        MockBCToken token = _deployCoin(
            "Curve",
            "CRV",
            50,
            _noStaking(),
            HookPayload.encode(
                HookPayload.withFee(3000).addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, "")
            )
        );
        PoolId pid = _poolId(address(token));
        vm.warp(block.timestamp + 3 days);
        _graduate(token);
        assertEq(observer.poolState(pid).count, 0, "nothing stored before the first swap");

        _swapEthForCoin(address(token), users.buyerTwo, 0.5 ether);
        (, int24 tickAfter) = hook.observe(pid);
        vm.warp(block.timestamp + 10 minutes);
        (int24 average, uint32 span) = observer.consult(pid, 10 minutes);
        assertEq(span, 10 minutes, "from the first swap");
        assertEq(average, tickAfter, "only the post-graduation tick");
        vm.expectRevert(abi.encodeWithSelector(ITwapObserver.NotEnoughHistory.selector, pid, uint32(10 minutes + 1)));
        observer.consult(pid, 10 minutes + 1);
    }

    /// Long random runs of records, growths and time jumps: the ring always holds the last recordings in
    /// order, a recording drops the oldest only when the ring is full, and a growth applies within one lap.
    /// forge-config: default.fuzz.runs = 32
    /// forge-config: ci.fuzz.runs = 32
    function testFuzz_audit_growthNeverLosesNorReordersARecording(uint256 seed, uint8 startCardinality) public {
        startCardinality = uint8(bound(startCardinality, 2, 40));
        (, PoolId pid) = _bound(abi.encode(uint32(60), uint16(startCardinality)));

        uint256[] memory history = new uint256[](700);
        for (uint256 step; step < 700; ++step) {
            // each step's scratch memory is released, the history array sits below the pointer
            bytes32 freeMemory;
            assembly ("memory-safe") {
                freeMemory := mload(0x40)
            }
            _growthStep(pid, seed, step, history);
            assembly ("memory-safe") {
                mstore(0x40, freeMemory)
            }
        }
    }

    uint256 internal recorded;
    uint256 internal recordsSincePending;

    function _growthStep(PoolId pid, uint256 seed, uint256 step, uint256[] memory history) internal {
        {
            uint256 roll = uint256(keccak256(abi.encode(seed, step)));
            ITwapObserver.PoolState memory before = observer.poolState(pid);

            if (roll % 11 == 0 && before.cardinalityNext < 255) {
                uint256 next = before.cardinalityNext + 1 + (roll >> 8) % 9;
                observer.increaseCardinality(pid, uint16(next > 255 ? 255 : next));
                ITwapObserver.PoolState memory grown = observer.poolState(pid);
                assertEq(grown.cardinality, before.cardinality, "a growth never applies in its own call");
                assertEq(grown.count, before.count, "a growth stores nothing");
                assertEq(grown.newest, before.newest, "a growth moves no cursor");
                return;
            }

            vm.warp(block.timestamp + 60 + (roll >> 16) % 90);
            assertTrue(observer.record(pid), "recorded");
            history[recorded++] = block.timestamp;

            ITwapObserver.PoolState memory s = observer.poolState(pid);
            assertEq(s.count, before.count < s.cardinality ? before.count + 1 : before.count, "drops only when full");
            assertGe(s.cardinality, before.cardinality, "cardinality never decreases");
            assertLe(s.cardinality, s.cardinalityNext, "cardinality <= cardinalityNext");

            if (before.cardinalityNext > before.cardinality) {
                if (s.cardinality == before.cardinality) ++recordsSincePending;
                else recordsSincePending = 0;
                assertLe(recordsSincePending, before.cardinality, "a growth applies within one lap");
            }

            for (uint256 i; i < s.count; ++i) {
                assertEq(
                    observer.observationAt(pid, i).timestamp, history[recorded - s.count + i], "the last recordings"
                );
            }
            assertEq(observer.latestObservation(pid).timestamp, block.timestamp, "latest");
        }
    }

    /// The dearest `consult` on a full ring, the observer cold, at the default and at the largest cardinality.
    function test_audit_consultGasWorstCaseAnyoneCanImpose() public {
        (, PoolId small) = _bound("");
        (, PoolId large) = _bound("");
        observer.increaseCardinality(large, 255);
        for (uint256 i; i < 600; ++i) {
            observer.record(small);
            observer.record(large);
            vm.warp(block.timestamp + 5 minutes);
        }
        assertEq(observer.poolState(large).count, 255, "full at 255");

        uint256 worstSmall = _worstConsultGas(small, 16);
        uint256 worstLarge = _worstConsultGas(large, 255);
        emit log_named_uint("worst consult, 16 slots (cold)", worstSmall);
        emit log_named_uint("worst consult, 255 slots (cold)", worstLarge);
        assertGt(worstLarge, worstSmall, "a grown ring costs every reader more");
    }

    function _worstConsultGas(PoolId pid, uint256 count) internal returns (uint256 worst) {
        for (uint256 i; i < count; ++i) {
            uint32 age = uint32(block.timestamp - observer.observationAt(pid, i).timestamp);
            (bool cooled,) = address(vm).call(abi.encodeWithSignature("cool(address)", address(observer)));
            assertTrue(cooled, "cool cheatcode");
            uint256 gasBefore = gasleft();
            observer.consult(pid, age);
            uint256 used = gasBefore - gasleft();
            if (used > worst) worst = used;
        }
    }

    function _noStaking() internal pure returns (IBCTokenFactory.StakingConfig memory) {
        return IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)});
    }
}
