// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

import {HostileExecutorMock} from "./HostileExecutorMock.sol";

/// @dev The corrector against a hostile or buggy executor, on the real v1.1 hook: every misbehaviour
/// is contained to the correction, the user's swap completes and no leg keeps the floor unpaid.
contract WthCorrectorHostileTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;
    using StateLibrary for IPoolManager;

    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant FLOOR_FEE = 300;
    uint16 internal constant LP_BPS = 3000;
    uint256 internal constant MIN_GAS = 250_000;
    uint256 internal constant MIN_PAYMENT = 1e12;
    uint256 internal constant USER_BUY = 0.3 ether;

    WthCorrector internal corrector;
    HostileExecutorMock internal executor;
    MockBCToken internal wCoin;
    PoolId internal pid;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        corrector = new WthCorrector(address(factory), poolManager, address(weth), MIN_GAS, MIN_PAYMENT);
        (wCoin, pid) = _deployGraduated(
            HookPayload.withFee(BASE_FEE).addCalculator(address(corrector), abi.encode(TICK_SPACING, LP_BPS))
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, abi.encode(TICK_SPACING, LP_BPS)),
            false
        );
        key = _poolKey(address(wCoin));

        executor = new HostileExecutorMock(poolManager, IWETH(address(weth)), address(corrector));
        vm.prank(users.owner);
        corrector.setExecutor(address(executor));
        vm.deal(address(executor), 100 ether);
        uint256 held = wCoin.balanceOf(users.buyerOne);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(executor), held / 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Stale sync
    // ---------------------------------------------------------------------------------------------

    function test_staleSync_isCaughtByTheSnapshot() public {
        executor.set(HostileExecutorMock.Mode.StaleSync, MIN_PAYMENT);
        vm.recordLogs();
        _swapCoinForEth(address(wCoin), users.buyerOne, 1_000_000 ether);
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 0, "correction reverted");
        assertEq(executor.calls(), 0, "executor frame rolled back");
    }

    function test_staleSync_leavesTheUserBuyIntact() public {
        executor.set(HostileExecutorMock.Mode.StaleSync, MIN_PAYMENT);
        assertGt(_swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY), 0, "the buy settles in native ETH");
        assertEq(hook.getCurrentFee(pid), BASE_FEE, "user fee");
    }

    // ---------------------------------------------------------------------------------------------
    // Unpaid legs
    // ---------------------------------------------------------------------------------------------

    function test_unpaidBackrun_isUnwound() public {
        uint256 frontRun = 0.2 ether;
        executor.set(HostileExecutorMock.Mode.Idle, 0);
        uint256 coinsBefore = wCoin.balanceOf(address(executor));
        executor.buy(key, frontRun);
        uint256 bought = wCoin.balanceOf(address(executor)) - coinsBefore;

        executor.setSellAmount(bought);
        executor.set(HostileExecutorMock.Mode.InBandSell, 0);
        vm.recordLogs();
        uint256 got = _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);

        assertGt(got, 0, "the user swap completed");
        assertEq(executor.calls(), 0, "every unpaid frame rolled back");
        assertEq(executor.legFee(), 0, "the in-band leg was rolled back");
        assertEq(wCoin.balanceOf(address(executor)), coinsBefore + bought, "the executor still holds its coins");
        assertEq(hook.getCurrentFee(pid), BASE_FEE, "the pool never applied the floor");
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 0, "nothing settled");
    }

    function test_paidBackrun_standsAtTheFloor() public {
        uint256 frontRun = 0.2 ether;
        executor.set(HostileExecutorMock.Mode.Idle, 0);
        uint256 coinsBefore = wCoin.balanceOf(address(executor));
        executor.buy(key, frontRun);
        executor.setSellAmount(wCoin.balanceOf(address(executor)) - coinsBefore);
        executor.set(HostileExecutorMock.Mode.InBandSell, MIN_PAYMENT);

        vm.recordLogs();
        _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        assertEq(executor.legFee(), FLOOR_FEE, "paid leg at the floor");
        assertEq(executor.fg1After(), executor.fg1Before(), "no LP fee on the leg");
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 1, "settled");
    }

    // ---------------------------------------------------------------------------------------------
    // LP share and in-range liquidity
    // ---------------------------------------------------------------------------------------------

    /// @dev The LP share follows the pool's in-range liquidity at payout, executor positions included.
    function test_lpShare_followsInRangeLiquidity() public {
        uint256 payment = 0.01 ether;
        uint256 lpAmount = payment * LP_BPS / 10_000;
        executor.set(HostileExecutorMock.Mode.Jit, payment);
        executor.setJitMultiplier(100);

        vm.recordLogs();
        _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 1, "paid and split");
        assertGt(executor.jitLiquidity(), 0, "position added inside the correction");

        executor.set(HostileExecutorMock.Mode.Idle, 0);
        executor.removeLiquidity(key);
        uint256 collected = uint256(uint128(executor.jitFees0()));
        assertGt(collected * 100, lpAmount * 95, "the position collects its share of the donation");
    }

    // ---------------------------------------------------------------------------------------------
    // Payment token and recovery
    // ---------------------------------------------------------------------------------------------

    function test_coinOnlyPayment_isBelowTheMinimum() public {
        executor.set(HostileExecutorMock.Mode.PayCoin, 0);
        executor.setCoinAmount(1000 ether);
        uint256 coinsBefore = wCoin.balanceOf(address(executor));
        vm.recordLogs();
        uint256 got = _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        assertGt(got, 0, "the user swap completed");
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 0, "correction reverted");
        assertEq(wCoin.balanceOf(address(corrector)), 0, "the coin came back with the revert");
        assertEq(wCoin.balanceOf(address(executor)), coinsBefore, "executor coins");
    }

    function test_wethPaymentWithStrayCoin_settlesAndIsRecoverable() public {
        executor.set(HostileExecutorMock.Mode.PayCoin, 1e15);
        executor.setCoinAmount(1000 ether);
        vm.recordLogs();
        _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 1, "settled on the WETH");
        assertEq(wCoin.balanceOf(address(corrector)), 1000 ether, "the coin stays");
        assertEq(weth.balanceOf(address(corrector)), 0, "the WETH was split");

        vm.expectEmit(true, true, false, true, address(corrector));
        emit IWthCorrector.TokensRecovered(address(wCoin), users.treasury, 1000 ether);
        vm.prank(users.owner);
        corrector.recoverERC20(address(wCoin), users.treasury, 1000 ether);
        assertEq(wCoin.balanceOf(users.treasury), 1000 ether, "recovered");
        assertEq(wCoin.balanceOf(address(corrector)), 0, "nothing left");
    }

    function test_recoverERC20_recoversStrayWeth() public {
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(corrector), 1 ether);
        vm.prank(users.owner);
        corrector.recoverERC20(address(weth), users.treasury, 1 ether);
        assertEq(weth.balanceOf(users.treasury), 1 ether, "recovered");
    }

    function test_RevertWhen_recoverERC20NotFromTheFactoryOwner() public {
        vm.expectRevert(IWthCorrector.OnlyFactoryOwner.selector);
        corrector.recoverERC20(address(wCoin), address(this), 1);
    }

    function test_RevertWhen_recoverERC20WithZeroAddresses() public {
        vm.startPrank(users.owner);
        vm.expectRevert(IWthCorrector.InvalidZeroAddress.selector);
        corrector.recoverERC20(address(0), users.treasury, 1);
        vm.expectRevert(IWthCorrector.InvalidZeroAddress.selector);
        corrector.recoverERC20(address(wCoin), address(0), 1);
        vm.stopPrank();
    }

    function test_recoverERC20_revertsDuringACorrection() public {
        vm.prank(address(executor));
        wCoin.transfer(address(corrector), 1000 ether);
        factory.setOwner(address(executor));

        executor.set(HostileExecutorMock.Mode.RecoverDuring, 1e15);
        executor.setCoinAmount(1000 ether);
        vm.recordLogs();
        _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 0, "correction reverted");
        assertEq(wCoin.balanceOf(address(corrector)), 1000 ether, "still held");

        vm.prank(address(executor));
        corrector.recoverERC20(address(wCoin), users.treasury, 1000 ether);
        assertEq(wCoin.balanceOf(users.treasury), 1000 ether, "recoverable outside a correction");
    }

    // ---------------------------------------------------------------------------------------------
    // Gas reserve
    // ---------------------------------------------------------------------------------------------

    function test_tailReserve_isKeptBackFromTheExecutor() public {
        executor.set(HostileExecutorMock.Mode.Idle, MIN_PAYMENT);
        _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        assertGt(executor.gasAtEntry(), 0, "called");
        assertLt(executor.gasAtEntry(), hook.OBSERVER_GAS_BUDGET() - corrector.TAIL_RESERVE(), "reserve kept back");
    }

    function test_greedyPayingExecutor_stillSettles() public {
        executor.set(HostileExecutorMock.Mode.BurnGasThenPay, 1e15);
        executor.setKeepGas(60_000);
        vm.recordLogs();
        _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        assertEq(
            _countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 1, "payout ran on the reserve"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Hook environment
    // ---------------------------------------------------------------------------------------------

    /// @dev The hook charges the non-LP fee of an exact-input swap on `amountSpecified`, not on the
    /// amount its price limit lets fill.
    function test_env_hookFeeIsChargedOnAmountSpecifiedNotOnTheFill() public {
        executor.set(HostileExecutorMock.Mode.Idle, 0);
        uint256 balance = wCoin.balanceOf(address(executor));
        (, int24 tick,,) = poolManager.getSlot0(pid);
        address recipient = wCoin.getFeeRecipient();
        uint256 feeBefore = wCoin.balanceOf(users.treasury) + wCoin.balanceOf(recipient);

        executor.sell(key, balance, TickMath.getSqrtPriceAtTick(tick + 60));

        uint256 feeTaken = wCoin.balanceOf(users.treasury) + wCoin.balanceOf(recipient) - feeBefore;
        uint256 filled = executor.coinSold() - feeTaken;
        assertEq(feeTaken, balance * 900 / 1e6, "non-LP fee on the whole specified amount");
        assertLt(filled * 100, balance, "under 1% of it was swapped");
    }

    function test_windowIsPerPool() public {
        (, PoolId otherPid) = _deployGraduated(
            HookPayload.withFee(BASE_FEE).addCalculator(address(corrector), abi.encode(TICK_SPACING, LP_BPS))
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, abi.encode(TICK_SPACING, LP_BPS)),
            false
        );
        executor.set(HostileExecutorMock.Mode.Idle, MIN_PAYMENT);
        _swapEthForCoin(address(wCoin), users.buyerTwo, USER_BUY);
        (uint160 lower, uint160 upper) = corrector.currentBand(otherPid);
        assertEq(lower + upper, 0, "closed on the other pool");
        (lower, upper) = corrector.currentBand(pid);
        assertEq(lower + upper, 0, "closed after the correction");
        assertEq(hook.getCurrentFee(otherPid), BASE_FEE, "other pool untouched");
    }

    function _countLogs(address emitter, bytes32 topic) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) ++n;
        }
    }
}
