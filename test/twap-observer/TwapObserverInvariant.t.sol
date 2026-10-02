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

/// @dev Random buys, sells, time jumps and `record` calls on one bound pool.
contract TwapHandler is Test {
    TwapObserver internal immutable OBSERVER;
    PoolSwapTest internal immutable ROUTER;
    PoolId internal immutable POOL_ID;
    PoolKey internal key;

    uint256 public swaps;

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
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 minutes));
    }

    function record() external {
        OBSERVER.record(POOL_ID);
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
        assertLe(s.count, CARDINALITY, "count within the ring");
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
