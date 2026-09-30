// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";

import {HookGated} from "kit/HookGated.sol";
import {HookPayload} from "kit/HookPayload.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

import {WthExecutorMock} from "./WthExecutorMock.sol";

/// @dev Runs against Frontier's real `FactoryHook` (from the kit's lib/factory-hook) on a local Uniswap v4
/// stack: the corrector is bound in both roles at deploy, fed by real swaps, its executor a scripted mock
/// arbitraging against a plain v4 pool in the same manager.
contract WthCorrectorTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;
    using StateLibrary for IPoolManager;

    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant FLOOR_FEE = 300;
    uint16 internal constant PROTOCOL_BPS = 2000;
    uint16 internal constant LP_BPS = 3000;
    uint16 internal constant CREATOR_BPS = 8000;
    uint256 internal constant MIN_GAS = 250_000;
    uint256 internal constant PAYMENT = 1e15;
    uint256 internal constant USER_BUY = 0.3 ether;

    WthCorrector internal corrector;
    WthExecutorMock internal executor;
    PoolModifyLiquidityTest internal lpRouter;
    MockBCToken internal wCoin;
    PoolId internal pid;
    PoolKey internal key;
    PoolKey internal plainKey;
    address internal recipient;

    function setUp() public override {
        super.setUp();
        corrector = new WthCorrector(
            address(factory), poolManager, address(weth), PROTOCOL_BPS, LP_BPS, CREATOR_BPS, MIN_GAS, 0
        );
        (wCoin, pid) = _deployBound(address(corrector), _spacing(TICK_SPACING), _spacing(TICK_SPACING));
        key = _poolKey(address(wCoin));
        recipient = wCoin.getFeeRecipient();

        executor = new WthExecutorMock(poolManager, IWETH(address(weth)), address(corrector));
        vm.prank(users.owner);
        corrector.setExecutor(address(executor));
        vm.deal(address(executor), 100 ether);

        uint256 held = wCoin.balanceOf(users.buyerOne);
        vm.startPrank(users.buyerOne);
        wCoin.transfer(address(executor), held / 4);
        wCoin.transfer(users.buyerTwo, held / 8);
        wCoin.transfer(address(this), held / 2);
        vm.stopPrank();

        _seedPlainPool(held / 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _spacing(int24 tickSpacing) internal pure returns (bytes memory) {
        return abi.encode(tickSpacing);
    }

    function _noStaking() internal pure returns (IBCTokenFactory.StakingConfig memory) {
        return IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)});
    }

    /// @dev A graduated coin binding `target` as its only calculator and as an after-swap observer.
    function _deployBound(address target, bytes memory calcConfig, bytes memory obsConfig)
        internal
        returns (MockBCToken deployed, PoolId poolId)
    {
        return _deployGraduated(
            HookPayload.withFee(BASE_FEE).addCalculator(target, calcConfig)
                .addObserver(target, HookPayload.CALL_AFTER_SWAP, obsConfig),
            false
        );
    }

    /// @dev A plain (hookless) v4 pool on the same pair, opened at the Frontier pool's price with
    /// a full-range position sized on `coinAmount` and 2 ETH.
    function _seedPlainPool(uint256 coinAmount) internal {
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(pid);
        plainKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(wCoin)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(plainKey, sqrtPrice);

        int24 low = TickMath.MIN_TICK / TICK_SPACING * TICK_SPACING;
        int24 high = TickMath.MAX_TICK / TICK_SPACING * TICK_SPACING;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(low), TickMath.getSqrtPriceAtTick(high), 2 ether, coinAmount
        );
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        wCoin.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 2 ether}(
            plainKey,
            ModifyLiquidityParams({
                tickLower: low, tickUpper: high, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
        executor.setPlainKey(plainKey);
    }

    function _userBuy(uint256 ethIn) internal returns (uint256 coinOut) {
        return _swapEthForCoin(address(wCoin), users.buyerTwo, ethIn);
    }

    function _userSell(uint256 coinIn) internal returns (uint256 ethOut) {
        return _swapCoinForEth(address(wCoin), users.buyerTwo, coinIn);
    }

    /// @dev The coin a buy of `ethIn` would return right now, measured in a discarded snapshot
    /// with corrections paused.
    function _probeBuy(uint256 ethIn) internal returns (uint256 coinOut) {
        uint256 snap = vm.snapshot();
        vm.prank(users.owner);
        corrector.setExecutor(address(0));
        coinOut = _userBuy(ethIn);
        vm.revertTo(snap);
    }

    function _leg(bool frontier, bool zeroForOne, int256 amount, WthExecutorMock.LimitMode mode, uint160 value)
        internal
        pure
        returns (WthExecutorMock.Leg memory)
    {
        return WthExecutorMock.Leg({
            frontier: frontier, zeroForOne: zeroForOne, amountSpecified: amount, limitMode: mode, limitValue: value
        });
    }

    function _setLeg(WthExecutorMock.Leg memory leg) internal {
        WthExecutorMock.Leg[] memory legs = new WthExecutorMock.Leg[](1);
        legs[0] = leg;
        executor.setLegs(legs);
    }

    /// @dev An opposite, exact-input coin leg on the Frontier pool with its limit `mode`/`value`.
    function _setSellLeg(uint256 coinIn, WthExecutorMock.LimitMode mode, uint160 value) internal {
        _setLeg(_leg(true, false, -int256(coinIn), mode, value));
    }

    function _rec(uint256 index) internal view returns (uint256) {
        return executor.rec(index);
    }

    /// @dev Balances a paused run of the same buy would leave, measured in a discarded snapshot.
    function _baseline(uint256 ethIn)
        internal
        returns (uint256 treasuryWeth, uint256 recipientWeth, uint256 managerEth)
    {
        uint256 snap = vm.snapshot();
        vm.prank(users.owner);
        corrector.setExecutor(address(0));
        _userBuy(ethIn);
        treasuryWeth = weth.balanceOf(users.treasury);
        recipientWeth = weth.balanceOf(recipient);
        managerEth = address(poolManager).balance;
        vm.revertTo(snap);
    }

    function _countLogs(address emitter, bytes32 topic) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) ++n;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Interface and construction
    // ---------------------------------------------------------------------------------------------

    function test_selector_matchesThePartnerExecutor() public pure {
        assertEq(IWthArbitrageExecutor.executeArbitrage.selector, bytes4(0xd4641322), "selector");
    }

    function test_constructor_rejectsBadSharesAndZeroAddresses() public {
        vm.expectRevert(IWthCorrector.InvalidShares.selector);
        new WthCorrector(address(factory), poolManager, address(weth), 6000, 4001, 0, 0, 0);
        vm.expectRevert(IWthCorrector.InvalidShares.selector);
        new WthCorrector(address(factory), poolManager, address(weth), 0, 0, 10_001, 0, 0);
        vm.expectRevert(IWthCorrector.InvalidZeroAddress.selector);
        new WthCorrector(address(0), poolManager, address(weth), 0, 0, 0, 0, 0);
        vm.expectRevert(IWthCorrector.InvalidZeroAddress.selector);
        new WthCorrector(address(factory), IPoolManager(address(0)), address(weth), 0, 0, 0, 0, 0);
        vm.expectRevert(IWthCorrector.InvalidZeroAddress.selector);
        new WthCorrector(address(factory), poolManager, address(0), 0, 0, 0, 0, 0);
    }

    function testFuzz_constructor_acceptsSharesUpToTheWhole(uint16 protocolBps, uint16 lpBps, uint16 creatorBps)
        public
    {
        protocolBps = uint16(bound(protocolBps, 0, 10_000));
        lpBps = uint16(bound(lpBps, 0, 10_000 - protocolBps));
        creatorBps = uint16(bound(creatorBps, 0, 10_000));
        WthCorrector c =
            new WthCorrector(address(factory), poolManager, address(weth), protocolBps, lpBps, creatorBps, 1, 2);
        assertEq(c.PROTOCOL_SHARE_BPS(), protocolBps, "protocol share");
        assertEq(c.LP_SHARE_BPS(), lpBps, "lp share");
        assertEq(c.CREATOR_BPS(), creatorBps, "creator bps");
        assertEq(c.MIN_CORRECTION_GAS(), 1, "min gas");
        assertEq(c.MIN_PAYMENT_WEI(), 2, "min payment");
    }

    // ---------------------------------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------------------------------

    function test_register_bindsBothRolesAndPinsTheHook() public view {
        IWthCorrector.PoolBinding memory b = corrector.bindingOf(pid);
        assertEq(b.coin, address(wCoin), "coin");
        assertEq(b.tickSpacing, TICK_SPACING, "tick spacing");
        assertEq(b.roles, corrector.ROLE_CALCULATOR() | corrector.ROLE_OBSERVER(), "both roles");
        assertEq(corrector.hookOf(pid), address(hook), "pinned hook");
    }

    function test_register_observerAlonePinsTheHook() public {
        (, PoolId other) = _deployGraduated(
            HookPayload.withFee(BASE_FEE)
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, _spacing(TICK_SPACING)),
            false
        );
        assertEq(corrector.bindingOf(other).roles, corrector.ROLE_OBSERVER(), "observer only");
        assertEq(corrector.hookOf(other), address(hook), "pinned hook");
    }

    function test_RevertWhen_registeredByAnyoneButTheHook() public {
        PoolId fresh = PoolId.wrap(keccak256("a pool id computed before its coin exists"));
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotCurrentHook.selector, address(this)));
        corrector.onRegisterCalculator(fresh, _spacing(TICK_SPACING));
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotCurrentHook.selector, address(this)));
        corrector.onRegisterObserver(fresh, _spacing(TICK_SPACING));
    }

    function test_RevertWhen_secondRoleRegisteredByAnotherHook() public {
        (, PoolId other) = _deployGraduated(
            HookPayload.withFee(BASE_FEE)
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, _spacing(TICK_SPACING)),
            false
        );
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, address(this)));
        corrector.onRegisterCalculator(other, _spacing(TICK_SPACING));
    }

    function test_register_writeOncePerRole() public {
        vm.startPrank(address(hook));
        vm.expectRevert(IWthCorrector.RoleAlreadyBound.selector);
        corrector.onRegisterCalculator(pid, _spacing(TICK_SPACING));
        vm.expectRevert(IWthCorrector.RoleAlreadyBound.selector);
        corrector.onRegisterObserver(pid, _spacing(TICK_SPACING));
        vm.stopPrank();
    }

    function test_RevertWhen_registeredForAnUnknownPool() public {
        vm.prank(address(hook));
        vm.expectRevert(IWthCorrector.InvalidPoolConfig.selector);
        corrector.onRegisterCalculator(PoolId.wrap(keccak256("unknown")), _spacing(TICK_SPACING));
    }

    function test_RevertWhen_tickSpacingDoesNotMatchThePool() public {
        IFactoryHook.HookConfigV2 memory config =
            HookPayload.withFee(BASE_FEE).addCalculator(address(corrector), _spacing(TICK_SPACING * 2));
        MockBCToken token = _newCoin("Wrong Spacing", "BAD");

        vm.expectRevert(IWthCorrector.InvalidPoolConfig.selector);
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(config));
    }

    function test_RevertWhen_configIsMalformed() public {
        IFactoryHook.HookConfigV2 memory config = HookPayload.withFee(BASE_FEE).addCalculator(address(corrector), "");
        MockBCToken token = _newCoin("Empty Config", "BAD");

        vm.expectRevert(IWthCorrector.InvalidPoolConfig.selector);
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(config));
    }

    function test_RevertWhen_poolStatePrefixDoesNotNameTheCoin() public {
        IFactoryHook.HookConfigV2 memory config =
            HookPayload.withFee(BASE_FEE).addCalculator(address(corrector), _spacing(TICK_SPACING));
        MockBCToken token = _newCoin("Foreign State", "BAD");
        PoolId poolId = _poolId(address(token));

        vm.mockCall(
            address(hook),
            abi.encodeCall(IFactoryHook.getPoolState, (poolId)),
            abi.encode(uint256(32), uint256(uint160(address(0xBEEF))), uint256(1), uint256(0), int256(0))
        );
        vm.expectRevert(IWthCorrector.PoolStateUnavailable.selector);
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(config));

        vm.mockCall(
            address(hook),
            abi.encodeCall(IFactoryHook.getPoolState, (poolId)),
            abi.encode(uint256(32), uint256(uint160(address(token))), uint256(0), uint256(0), int256(0))
        );
        vm.expectRevert(IWthCorrector.PoolStateUnavailable.selector);
        _registerCoin(token, 50, _noStaking(), HookPayload.encode(config));
        vm.clearMockedCalls();
    }

    // ---------------------------------------------------------------------------------------------
    // Executor pointer and gates
    // ---------------------------------------------------------------------------------------------

    function test_setExecutor_onlyFactoryOwner() public {
        vm.expectRevert(IWthCorrector.OnlyFactoryOwner.selector);
        corrector.setExecutor(address(1));

        vm.expectEmit(true, true, false, true, address(corrector));
        emit IWthCorrector.ExecutorSet(address(executor), address(1));
        vm.prank(users.owner);
        corrector.setExecutor(address(1));
        assertEq(corrector.executor(), address(1), "executor");
    }

    function test_pause_zeroExecutorSkipsTheCall() public {
        vm.prank(users.owner);
        corrector.setExecutor(address(0));
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 0, "not called");
        assertEq(hook.getCurrentFee(pid), BASE_FEE, "user fee unchanged");
    }

    function test_minCorrectionGas_skipsTheCall() public {
        WthCorrector greedy = new WthCorrector(
            address(factory), poolManager, address(weth), PROTOCOL_BPS, LP_BPS, CREATOR_BPS, 1_000_000, 0
        );
        (MockBCToken other,) = _deployBound(address(greedy), _spacing(TICK_SPACING), _spacing(TICK_SPACING));
        vm.prank(users.owner);
        greedy.setExecutor(address(executor));
        _swapEthForCoin(address(other), users.buyerTwo, USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 0, "not called under the gas gate");
    }

    function test_RevertWhen_notificationsNotFromPoolHook() public {
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, address(this)));
        corrector.onAfterSwap(pid, toBalanceDelta(-1, 1), 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(HookGated.NotPoolHook.selector, address(this)));
        corrector.onFeeChange(pid, 0, 0);
    }

    function test_receive_rejectsEthOutsideACorrection() public {
        (bool ok,) = address(corrector).call{value: 1}("");
        assertFalse(ok, "eth refused");
    }

    function test_call_carriesThePoolKeyAndTheSplit() public {
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 1, "called once");
        assertEq(_rec(executor.REC_CALLER()), uint160(address(corrector)), "caller is the corrector");
        assertEq(_rec(executor.REC_REBATE()), 0, "no rebate recipient");
        assertEq(_rec(executor.REC_SPLIT_CREATOR()), uint160(address(corrector)), "creator is the corrector");
        assertEq(_rec(executor.REC_SPLIT_TRADER_BPS()), 0, "trader bps");
        assertEq(_rec(executor.REC_SPLIT_CREATOR_BPS()), CREATOR_BPS, "creator bps");
        assertEq(_rec(executor.REC_SPLIT_TRIGGER_BPS()), 0, "trigger pool bps");
        assertEq(_rec(executor.REC_POOL_ID()), uint256(PoolId.unwrap(pid)), "pool id");
    }

    // ---------------------------------------------------------------------------------------------
    // The band
    // ---------------------------------------------------------------------------------------------

    function test_band_isZeroOutsideAWindow() public {
        (uint160 lower, uint160 upper) = corrector.currentBand(pid);
        assertEq(lower, 0, "no lower");
        assertEq(upper, 0, "no upper");
        _userBuy(USER_BUY);
        (lower, upper) = corrector.currentBand(pid);
        assertEq(lower, 0, "closed lower");
        assertEq(upper, 0, "closed upper");
    }

    function test_band_buy_spansPostPriceToPreTickMinusOne() public {
        (, int24 preTick,,) = poolManager.getSlot0(pid);
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_LOWER()), _rec(executor.REC_POST_PRICE()), "lower is the post-swap price");
        assertEq(_rec(executor.REC_UPPER()), TickMath.getSqrtPriceAtTick(preTick - 1), "upper is pre tick minus one");
        assertLt(_rec(executor.REC_LOWER()), _rec(executor.REC_UPPER()), "band not empty");
    }

    function test_band_sell_spansPreTickPlusOneToPostPrice() public {
        (, int24 preTick,,) = poolManager.getSlot0(pid);
        _userSell(wCoin.balanceOf(users.buyerTwo) / 2);
        assertEq(_rec(executor.REC_LOWER()), TickMath.getSqrtPriceAtTick(preTick + 1), "lower is pre tick plus one");
        assertEq(_rec(executor.REC_UPPER()), _rec(executor.REC_POST_PRICE()), "upper is the post-swap price");
        assertLt(_rec(executor.REC_LOWER()), _rec(executor.REC_UPPER()), "band not empty");
    }

    function test_band_emptyWhenTheSwapStaysInsideItsTick() public {
        _userBuy(1);
        assertEq(_rec(executor.REC_CALLS()), 1, "executor still called");
        assertEq(_rec(executor.REC_LOWER()), 0, "no lower");
        assertEq(_rec(executor.REC_UPPER()), 0, "no upper");
    }

    // ---------------------------------------------------------------------------------------------
    // Fees on the legs
    // ---------------------------------------------------------------------------------------------

    function test_leg_inBand_paysTheFloor() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut / 4, WthExecutorMock.LimitMode.BandUpperMinus, 1);
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 1, "called once, nested notification ignored");
        assertEq(_rec(executor.REC_FEE()), FLOOR_FEE, "in-band leg at the floor");
        assertEq(hook.getCurrentFee(pid), FLOOR_FEE, "last applied fee is the leg's");
    }

    function test_leg_justAboveThePostPrice_paysTheFloor() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut / 4, WthExecutorMock.LimitMode.BandLowerPlus, 1);
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_FEE()), FLOOR_FEE, "strictly inside, at the lower edge");
    }

    function test_leg_atTheUpperEdge_paysTheNormalFee() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut / 4, WthExecutorMock.LimitMode.BandUpperMinus, 0);
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 1, "called");
        assertEq(_rec(executor.REC_FEE()), BASE_FEE, "limit on the edge is outside");
    }

    function test_leg_beyondTheBand_paysTheNormalFee() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut / 4, WthExecutorMock.LimitMode.Explicit, TickMath.MAX_SQRT_PRICE - 1);
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_FEE()), BASE_FEE, "no limit, normal fee");
    }

    function test_leg_sameDirection_paysTheNormalFee() public {
        _setLeg(_leg(true, true, -0.01 ether, WthExecutorMock.LimitMode.Explicit, TickMath.MIN_SQRT_PRICE + 1));
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 1, "called");
        assertEq(_rec(executor.REC_FEE()), BASE_FEE, "same direction, normal fee");
    }

    function test_leg_exactOutput_paysTheNormalFee() public {
        _setLeg(_leg(true, false, 1e13, WthExecutorMock.LimitMode.BandUpperMinus, 1));
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 1, "called");
        assertEq(_rec(executor.REC_FEE()), BASE_FEE, "exact output, normal fee");
    }

    function test_leg_sell_inBandBuyBackPaysTheFloor() public {
        _setLeg(_leg(true, true, -0.02 ether, WthExecutorMock.LimitMode.BandLowerPlus, 1));
        _userSell(wCoin.balanceOf(users.buyerTwo) / 2);
        assertEq(_rec(executor.REC_CALLS()), 1, "called");
        assertEq(_rec(executor.REC_FEE()), FLOOR_FEE, "opposite in-band leg at the floor");
    }

    function test_quoteFee_isIdentityOutsideAWindow() public {
        _userBuy(USER_BUY);
        assertEq(hook.getCurrentFee(pid), BASE_FEE, "the user's own swap pays the base fee");
    }

    // ---------------------------------------------------------------------------------------------
    // LP neutrality
    // ---------------------------------------------------------------------------------------------

    function test_lpNeutrality_inBandLegLeavesFeeGrowthUntouched() public {
        (uint160 preSqrtPrice,,,) = poolManager.getSlot0(pid);
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut * 2, WthExecutorMock.LimitMode.BandUpperMinus, 1);
        _userBuy(USER_BUY);

        assertEq(_rec(executor.REC_FEE()), FLOOR_FEE, "at the floor");
        assertEq(_rec(executor.REC_FG0_AFTER()), _rec(executor.REC_FG0_BEFORE()), "no ETH-side LP fee");
        assertEq(_rec(executor.REC_FG1_AFTER()), _rec(executor.REC_FG1_BEFORE()), "no coin-side LP fee");

        (uint160 sqrtPrice,,,) = poolManager.getSlot0(pid);
        uint160 upper = uint160(_rec(executor.REC_UPPER()));
        assertEq(sqrtPrice, upper - 1, "the leg filled up to the band edge");
        assertLt(sqrtPrice, preSqrtPrice, "never past the pre-swap price");
    }

    function test_outOfBandLeg_paysTheLps() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut / 4, WthExecutorMock.LimitMode.BandUpperMinus, 0);
        _userBuy(USER_BUY);
        assertGt(_rec(executor.REC_FG1_AFTER()), _rec(executor.REC_FG1_BEFORE()), "coin-side LP fee accrued");
    }

    // ---------------------------------------------------------------------------------------------
    // Unwinding
    // ---------------------------------------------------------------------------------------------

    function test_openDelta_revertsTheCorrectionAndKeepsTheSwap() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut / 4, WthExecutorMock.LimitMode.BandUpperMinus, 1);
        executor.setPay(WthExecutorMock.PayMode.Native, PAYMENT);
        executor.setLeaveOpen(true);

        vm.expectCall(address(executor), abi.encodeWithSelector(IWthArbitrageExecutor.executeArbitrage.selector));
        uint256 got = _userBuy(USER_BUY);
        assertGt(got, 0, "the user swap completed");
        assertEq(_rec(executor.REC_CALLS()), 0, "the executor's frame was rolled back");
        assertEq(hook.getCurrentFee(pid), BASE_FEE, "the leg was unwound");
        assertEq(weth.balanceOf(address(corrector)), 0, "no payment kept");
        assertEq(address(corrector).balance, 0, "no eth kept");
    }

    function test_executorRevert_revertsTheCorrectionAndKeepsTheSwap() public {
        executor.setShouldRevert(true);
        vm.expectCall(address(executor), abi.encodeWithSelector(IWthArbitrageExecutor.executeArbitrage.selector));
        uint256 got = _userBuy(USER_BUY);
        assertGt(got, 0, "the user swap completed");
        assertEq(hook.getCurrentFee(pid), BASE_FEE, "user fee");
    }

    // ---------------------------------------------------------------------------------------------
    // Payment and payout
    // ---------------------------------------------------------------------------------------------

    function _assertSplit(uint256 treasuryWeth, uint256 recipientWeth, uint256 managerEth, uint256 lpAmount)
        internal
        view
    {
        uint256 protocolAmount = PAYMENT * PROTOCOL_BPS / 10_000;
        assertEq(weth.balanceOf(users.treasury) - treasuryWeth, protocolAmount, "treasury share");
        assertEq(weth.balanceOf(recipient) - recipientWeth, PAYMENT - protocolAmount - lpAmount, "recipient share");
        assertEq(address(poolManager).balance - managerEth, lpAmount, "lp share donated");
        assertEq(weth.balanceOf(address(corrector)), 0, "nothing kept in weth");
        assertEq(address(corrector).balance, 0, "nothing kept in eth");
    }

    function test_payment_inWeth_isSplit() public {
        (uint256 t, uint256 r, uint256 m) = _baseline(USER_BUY);
        executor.setPay(WthExecutorMock.PayMode.Weth, PAYMENT);
        uint256 lpAmount = PAYMENT * LP_BPS / 10_000;

        vm.expectEmit(true, true, false, true, address(poolManager));
        emit IPoolManager.Donate(pid, address(corrector), lpAmount, 0);
        vm.expectEmit(true, false, false, true, address(corrector));
        emit IWthCorrector.CorrectionSettled(
            pid,
            PAYMENT,
            PAYMENT * PROTOCOL_BPS / 10_000,
            lpAmount,
            PAYMENT - PAYMENT * PROTOCOL_BPS / 10_000 - lpAmount
        );
        _userBuy(USER_BUY);
        _assertSplit(t, r, m, lpAmount);
    }

    function test_payment_inNativeEth_isSplit() public {
        (uint256 t, uint256 r, uint256 m) = _baseline(USER_BUY);
        executor.setPay(WthExecutorMock.PayMode.Native, PAYMENT);
        uint256 lpAmount = PAYMENT * LP_BPS / 10_000;

        vm.expectEmit(true, true, false, true, address(poolManager));
        emit IPoolManager.Donate(pid, address(corrector), lpAmount, 0);
        _userBuy(USER_BUY);
        _assertSplit(t, r, m, lpAmount);
    }

    function test_payment_none_settlesNothing() public {
        vm.recordLogs();
        _userBuy(USER_BUY);
        assertEq(_rec(executor.REC_CALLS()), 1, "called");
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 0, "no settlement");
    }

    function test_payout_zeroLiquidity_paysTheLpShareToTheRecipient() public {
        (uint256 t, uint256 r, uint256 m) = _baseline(USER_BUY);
        executor.setPay(WthExecutorMock.PayMode.Weth, PAYMENT);
        bytes32 liquiditySlot = bytes32(
            uint256(keccak256(abi.encodePacked(PoolId.unwrap(pid), StateLibrary.POOLS_SLOT)))
                + StateLibrary.LIQUIDITY_OFFSET
        );
        vm.mockCall(
            address(poolManager), abi.encodeWithSignature("extsload(bytes32)", liquiditySlot), abi.encode(bytes32(0))
        );

        vm.expectEmit(true, false, false, true, address(corrector));
        emit IWthCorrector.CorrectionSettled(
            pid, PAYMENT, PAYMENT * PROTOCOL_BPS / 10_000, 0, PAYMENT - PAYMENT * PROTOCOL_BPS / 10_000
        );
        _userBuy(USER_BUY);
        vm.clearMockedCalls();
        _assertSplit(t, r, m, 0);
    }

    function test_payout_failedTransfer_revertsTheCorrection() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        _setSellLeg(coinOut / 4, WthExecutorMock.LimitMode.BandUpperMinus, 1);
        executor.setPay(WthExecutorMock.PayMode.Weth, PAYMENT);
        vm.mockCallRevert(
            address(weth), abi.encodeCall(IWETH.transfer, (users.treasury, PAYMENT * PROTOCOL_BPS / 10_000)), ""
        );
        (uint256 treasuryPaused,,) = _baseline(USER_BUY);

        vm.recordLogs();
        assertGt(_userBuy(USER_BUY), 0, "the user swap completed");
        vm.clearMockedCalls();
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 0, "nothing settled");
        assertEq(hook.getCurrentFee(pid), BASE_FEE, "the leg was unwound");
        assertEq(weth.balanceOf(users.treasury), treasuryPaused, "only the swap fee reached the treasury");
        assertEq(weth.balanceOf(address(corrector)) + address(corrector).balance, 0, "nothing kept");
    }

    function testFuzz_payout_sharesSumToThePayment(uint256 payment) public {
        payment = bound(payment, 1, 1 ether);
        (uint256 t, uint256 r, uint256 m) = _baseline(USER_BUY);
        executor.setPay(WthExecutorMock.PayMode.Native, payment);
        _userBuy(USER_BUY);
        uint256 protocolAmount = payment * PROTOCOL_BPS / 10_000;
        uint256 lpAmount = payment * LP_BPS / 10_000;
        assertEq(weth.balanceOf(users.treasury) - t, protocolAmount, "treasury");
        assertEq(address(poolManager).balance - m, lpAmount, "donated");
        assertEq(weth.balanceOf(recipient) - r, payment - protocolAmount - lpAmount, "recipient");
        assertEq(weth.balanceOf(address(corrector)) + address(corrector).balance, 0, "nothing kept");
    }

    function test_payout_zeroTreasury_paysTheProtocolShareToTheRecipient() public {
        factory.setTreasury(address(0));
        (, uint256 r, uint256 m) = _baseline(USER_BUY);
        executor.setPay(WthExecutorMock.PayMode.Weth, PAYMENT);
        uint256 lpAmount = PAYMENT * LP_BPS / 10_000;

        _userBuy(USER_BUY);
        assertEq(weth.balanceOf(recipient) - r, PAYMENT - lpAmount, "protocol share falls to the recipient");
        assertEq(address(poolManager).balance - m, lpAmount, "lp share donated");
        assertEq(weth.balanceOf(address(0)), 0, "nothing burnt");
    }

    // ---------------------------------------------------------------------------------------------
    // Minimum payment
    // ---------------------------------------------------------------------------------------------

    uint256 internal constant MIN_PAYMENT = 1e12;

    /// @dev A corrector with a nonzero minimum payment, bound on a fresh coin, with its own executor.
    function _deployStrict() internal returns (WthCorrector strict, WthExecutorMock strictExecutor, MockBCToken c) {
        strict = new WthCorrector(
            address(factory), poolManager, address(weth), PROTOCOL_BPS, LP_BPS, CREATOR_BPS, MIN_GAS, MIN_PAYMENT
        );
        (c,) = _deployBound(address(strict), _spacing(TICK_SPACING), _spacing(TICK_SPACING));
        strictExecutor = new WthExecutorMock(poolManager, IWETH(address(weth)), address(strict));
        vm.prank(users.owner);
        strict.setExecutor(address(strictExecutor));
        vm.deal(address(strictExecutor), 100 ether);
        uint256 held = c.balanceOf(users.buyerOne);
        vm.prank(users.buyerOne);
        c.transfer(address(strictExecutor), held / 4);
    }

    function _strictLeg(WthExecutorMock strictExecutor, MockBCToken c) internal {
        WthExecutorMock.Leg[] memory legs = new WthExecutorMock.Leg[](1);
        legs[0] = _leg(
            true,
            false,
            -int256(c.balanceOf(address(strictExecutor)) / 100),
            WthExecutorMock.LimitMode.BandUpperMinus,
            1
        );
        strictExecutor.setLegs(legs);
    }

    function test_minPayment_unpaidCorrectionUnwindsTheLegs() public {
        (WthCorrector strict, WthExecutorMock strictExecutor, MockBCToken c) = _deployStrict();
        PoolId poolId = _poolId(address(c));
        _strictLeg(strictExecutor, c);

        vm.recordLogs();
        vm.expectCall(address(strictExecutor), abi.encodeWithSelector(IWthArbitrageExecutor.executeArbitrage.selector));
        uint256 got = _swapEthForCoin(address(c), users.buyerTwo, USER_BUY);
        assertGt(got, 0, "the user swap completed");
        assertEq(strictExecutor.rec(strictExecutor.REC_CALLS()), 0, "the executor's frame was rolled back");
        assertEq(hook.getCurrentFee(poolId), BASE_FEE, "the leg was unwound");
        assertEq(_countLogs(address(strict), IWthCorrector.CorrectionSettled.selector), 0, "nothing settled");
        assertEq(weth.balanceOf(address(strict)) + address(strict).balance, 0, "nothing kept");
    }

    function test_minPayment_paymentBelowTheMinimumUnwindsTheLegs() public {
        (WthCorrector strict, WthExecutorMock strictExecutor, MockBCToken c) = _deployStrict();
        _strictLeg(strictExecutor, c);
        strictExecutor.setPay(WthExecutorMock.PayMode.Native, MIN_PAYMENT - 1);

        vm.recordLogs();
        _swapEthForCoin(address(c), users.buyerTwo, USER_BUY);
        assertEq(hook.getCurrentFee(_poolId(address(c))), BASE_FEE, "the leg was unwound");
        assertEq(_countLogs(address(strict), IWthCorrector.CorrectionSettled.selector), 0, "nothing settled");
        assertEq(address(strictExecutor).balance, 100 ether, "the payment came back with the revert");
    }

    function test_minPayment_paymentAtTheMinimumSettles() public {
        (WthCorrector strict, WthExecutorMock strictExecutor, MockBCToken c) = _deployStrict();
        _strictLeg(strictExecutor, c);
        strictExecutor.setPay(WthExecutorMock.PayMode.Weth, MIN_PAYMENT);

        vm.expectEmit(true, false, false, false, address(strict));
        emit IWthCorrector.CorrectionSettled(_poolId(address(c)), MIN_PAYMENT, 0, 0, 0);
        _swapEthForCoin(address(c), users.buyerTwo, USER_BUY);
        assertEq(strictExecutor.rec(strictExecutor.REC_FEE()), FLOOR_FEE, "in-band leg at the floor");
        assertEq(hook.getCurrentFee(_poolId(address(c))), FLOOR_FEE, "the leg stands");
    }

    // ---------------------------------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------------------------------

    function test_gas_fullCorrectionFitsTheObserverBudget() public {
        uint256 coinOut = _probeBuy(USER_BUY);
        WthExecutorMock.Leg[] memory legs = new WthExecutorMock.Leg[](2);
        legs[0] = _leg(true, false, -int256(coinOut / 2), WthExecutorMock.LimitMode.BandUpperMinus, 1);
        legs[1] =
            _leg(false, true, int256(coinOut / 2), WthExecutorMock.LimitMode.Explicit, TickMath.MIN_SQRT_PRICE + 1);
        executor.setLegs(legs);
        executor.setPay(WthExecutorMock.PayMode.Native, PAYMENT);

        uint256 snap = vm.snapshot();
        vm.prank(users.owner);
        corrector.setExecutor(address(0));
        uint256 gasPaused = gasleft();
        _userBuy(USER_BUY);
        gasPaused -= gasleft();
        vm.revertTo(snap);

        uint256 gasCorrected = gasleft();
        _userBuy(USER_BUY);
        gasCorrected -= gasleft();

        assertEq(_rec(executor.REC_CALLS()), 1, "corrected");
        assertEq(_rec(executor.REC_FEE()), FLOOR_FEE, "in-band leg at the floor");
        uint256 correction = gasCorrected - gasPaused;
        uint256 executorGas = _rec(executor.REC_GAS());
        uint256 frontierLeg = _rec(executor.REC_LEG_GAS());
        uint256 plainLeg = _rec(executor.REC_LEG_GAS() + 1);

        emit log_named_uint("correction total (notify + corrector + executor)", correction);
        emit log_named_uint("executor call (mock, both legs + settle + payment)", executorGas);
        emit log_named_uint("  leg through FactoryHook (in-band, floor fee)", frontierLeg);
        emit log_named_uint("  leg on the plain pool", plainLeg);
        emit log_named_uint("corrector overhead (band, snapshot, payout, donate)", correction - executorGas);

        assertLt(correction, hook.OBSERVER_GAS_BUDGET(), "fits the observer budget");
    }
}
