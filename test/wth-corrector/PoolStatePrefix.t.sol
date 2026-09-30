// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

/// @dev Exposes the raw `PoolState` prefix read so it can be checked against the typed decode.
contract WthCorrectorHarness is WthCorrector {
    constructor(address factory, IPoolManager poolManager, address weth)
        WthCorrector(factory, poolManager, weth, 0, 0, 0, 0, 0)
    {}

    function referenceTick(address hook, PoolId poolId) external view returns (int24) {
        return _referenceTick(hook, poolId);
    }
}

/// @dev The raw `getPoolState` prefix read must agree with the typed decode on the real v1.1 hook,
/// on a pool the corrector is not bound to, through swaps and time.
contract PoolStatePrefixTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;
    using StateLibrary for IPoolManager;

    WthCorrectorHarness internal harness;
    MockBCToken internal token;
    PoolId internal pid;

    function setUp() public override {
        super.setUp();
        harness = new WthCorrectorHarness(address(factory), poolManager, address(weth));
        (token, pid) = _deployGraduated(HookPayload.withFee(HookPayload.DEFAULT_FIXED_FEE), false);
    }

    function test_referenceTick_matchesTypedDecode_afterGraduation() public view {
        _assertMatches(SEED_TICK);
    }

    function test_referenceTick_matchesTypedDecode_throughSwaps() public {
        int24 preTick = _tick();
        _swapEthForCoin(address(token), users.buyerOne, 0.5 ether);
        _assertMatches(preTick);

        vm.warp(block.timestamp + 1 hours);
        preTick = _tick();
        _swapCoinForEth(address(token), users.buyerOne, 1_000_000 ether);
        _assertMatches(preTick);

        preTick = _tick();
        _swapEthForCoin(address(token), users.buyerTwo, 3 ether);
        _assertMatches(preTick);
    }

    function testFuzz_referenceTick_matchesTypedDecode(uint256 ethIn, uint32 elapsed) public {
        ethIn = bound(ethIn, 1, 5 ether);
        vm.warp(block.timestamp + bound(elapsed, 0, 1 days));
        int24 preTick = _tick();
        _swapEthForCoin(address(token), users.buyerOne, ethIn);
        _assertMatches(preTick);
    }

    function test_referenceTick_matchesTypedDecode_onAnUnregisteredPool() public view {
        PoolId unknown = PoolId.wrap(keccak256("never registered"));
        assertEq(harness.referenceTick(address(hook), unknown), hook.getPoolState(unknown).referenceTick);
    }

    function test_RevertWhen_prefixIsTooShort() public {
        vm.mockCall(address(hook), abi.encodeCall(IFactoryHook.getPoolState, (pid)), abi.encode(uint256(32)));
        vm.expectRevert(IWthCorrector.PoolStateUnavailable.selector);
        harness.referenceTick(address(hook), pid);
        vm.clearMockedCalls();
    }

    /// @dev `referenceTick` is the pre-swap tick of the last swap (the opening tick before any).
    function _assertMatches(int24 expected) internal view {
        int24 typed = hook.getPoolState(pid).referenceTick;
        assertEq(harness.referenceTick(address(hook), pid), typed, "raw prefix read");
        assertEq(typed, expected, "pre-swap tick");
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(pid);
    }
}
