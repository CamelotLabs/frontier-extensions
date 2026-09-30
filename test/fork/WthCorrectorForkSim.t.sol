// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCToken} from "frontier/interfaces/IBCToken.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IBondingCurve} from "frontier/interfaces/IBondingCurve.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

interface ILiquidityManagerView {
    function hook() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function getPoolKey(address coin) external view returns (PoolKey memory);
}

/// @notice Arbitrage executor for the simulation: closes the gap between the Frontier pool and one
/// hookless pool of the same pair. The Frontier leg is exact-input, opposite to the user's swap,
/// sized from the pool's active liquidity and limited inside the corrector's band; the other leg
/// balances the coin. Unprofitable corrections revert. Bookkeeping lives in transient storage so it
/// does not weigh on the measured gas.
contract ForkArbExecutor is IWthArbitrageExecutor {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    error NotCorrector();
    error Unprofitable(int256 ethDelta, int256 coinDelta);

    uint256 internal constant T_CALLS = 0;
    uint256 internal constant T_LEGS = 1;
    uint256 internal constant T_PROFIT = 2;
    uint256 internal constant T_GAS = 3;

    IPoolManager public immutable poolManager;
    address public immutable corrector;
    uint256 public immutable minGapBps;
    PoolKey internal _secondary;

    constructor(IPoolManager poolManager_, address corrector_, uint256 minGapBps_) {
        poolManager = poolManager_;
        corrector = corrector_;
        minGapBps = minGapBps_;
    }

    receive() external payable {}

    function setSecondary(PoolKey calldata key) external {
        _secondary = key;
    }

    function reset() external {
        assembly ("memory-safe") {
            tstore(0, 0)
            tstore(1, 0)
            tstore(2, 0)
            tstore(3, 0)
        }
    }

    function rec(uint256 slot) external view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function executeArbitrage(PoolKey calldata trig, address, ProfitSplit calldata split)
        external
        returns (uint256 profit)
    {
        if (msg.sender != corrector) revert NotCorrector();
        uint256 g0 = gasleft();
        _tinc(T_CALLS);

        PoolKey memory other = _secondary;
        (bool sellCoin, uint256 amountIn, uint160 lim) = _plan(trig, other);
        if (amountIn != 0) {
            _legs(trig, other, sellCoin, amountIn, lim);
            profit = _settle(trig.currency1, split.creatorBps);
        }
        _tset(T_GAS, g0 - gasleft());
    }

    /// @dev Frontier leg: direction, exact input and band-clamped limit; zero input means no trade.
    function _plan(PoolKey calldata trig, PoolKey memory other)
        internal
        view
        returns (bool sellCoin, uint256 amountIn, uint160 lim)
    {
        PoolId id1 = trig.toId();
        (uint160 s1,,,) = poolManager.getSlot0(id1);
        (uint160 s2,,,) = poolManager.getSlot0(other.toId());
        uint256 gap = s1 > s2 ? s1 - s2 : s2 - s1;
        if (gap * 10_000 < uint256(s2) * minGapBps) return (false, 0, 0);

        uint128 l1 = poolManager.getLiquidity(id1);
        uint256 lsum = uint256(l1) + poolManager.getLiquidity(other.toId());
        uint160 target = uint160(FullMath.mulDiv(l1, s1, lsum) + FullMath.mulDiv(lsum - l1, s2, lsum));
        (uint160 lower, uint160 upper) = IWthCorrector(corrector).currentBand(id1);

        sellCoin = s1 < s2;
        if (sellCoin) {
            // coin dearer on Frontier: sell it there (price up)
            lim = target < upper ? target : upper - 1;
            if (lim <= s1) return (true, 0, 0);
            amountIn = SqrtPriceMath.getAmount1Delta(s1, lim, l1, true);
        } else {
            // coin cheaper on Frontier: buy it there (price down)
            lim = target > lower ? target : lower + 1;
            if (lim >= s1) return (false, 0, 0);
            amountIn = SqrtPriceMath.getAmount0Delta(lim, s1, l1, true);
        }
    }

    function _legs(PoolKey calldata trig, PoolKey memory other, bool sellCoin, uint256 amountIn, uint160 lim) internal {
        BalanceDelta d = poolManager.swap(
            trig, SwapParams({zeroForOne: !sellCoin, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: lim}), ""
        );
        if (sellCoin) {
            poolManager.swap(
                other,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: int256(-d.amount1()),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
        } else {
            poolManager.swap(
                other,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(d.amount1()),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        }
        _tset(T_LEGS, 2);
    }

    function _settle(Currency coin, uint16 creatorBps) internal returns (uint256 profit) {
        int256 dEth = poolManager.currencyDelta(address(this), CurrencyLibrary.ADDRESS_ZERO);
        int256 dCoin = poolManager.currencyDelta(address(this), coin);
        if (dEth < 0 || dCoin < 0) revert Unprofitable(dEth, dCoin);
        if (dCoin > 0) poolManager.take(coin, address(this), uint256(dCoin));
        profit = uint256(dEth);
        if (profit > 0) {
            uint256 share = profit * creatorBps / 10_000;
            if (share > 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, corrector, share);
            if (profit > share) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), profit - share);
        }
        _tset(T_PROFIT, profit);
    }

    function _tinc(uint256 slot) internal {
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), 1))
        }
    }

    function _tset(uint256 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}

/**
 * @notice Simulation on a fork of the live Robinhood Chain: a coin launched through the real
 * factory with `WthCorrector` bound on the real FactoryHook, a hookless secondary pool of the same
 * pair, and user swaps of several sizes in both directions. For each swap: gas with and without
 * the correction, the executor's profit, the payout split and the price gap before and after.
 * @dev Run: `FOUNDRY_PROFILE=fork forge test --match-contract WthCorrectorForkSim -vv`.
 */
contract WthCorrectorForkSim is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant FACTORY = 0xe3A826C056e578c240D362BF4C2fa53E5c0c17a5;
    int24 internal constant SPACING = 60;
    uint24 internal constant SECONDARY_FEE = 3000;
    bytes32 internal constant SETTLED_TOPIC = keccak256("CorrectionSettled(bytes32,uint256,uint256,uint256)");

    IBCTokenFactory internal factory = IBCTokenFactory(FACTORY);
    ILiquidityManagerView internal lm;
    IPoolManager internal pm;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liqRouter;
    WthCorrector internal corrector;
    ForkArbExecutor internal executor;

    address internal coin;
    PoolKey internal mainKey;
    PoolKey internal secKey;
    address internal user = makeAddr("user");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);

        lm = ILiquidityManagerView(factory.liquidityManager());
        pm = IPoolManager(lm.POOL_MANAGER());
        router = new PoolSwapTest(pm);
        liqRouter = new PoolModifyLiquidityTest(pm);

        corrector = new WthCorrector(FACTORY, pm, factory.WETH(), 250_000, 1e12);
        executor = new ForkArbExecutor(pm, address(corrector), 17);
        vm.prank(factory.owner());
        corrector.setExecutor(address(executor));

        coin = _launchAndGraduate();
        mainKey = lm.getPoolKey(coin);

        secKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(coin),
            fee: SECONDARY_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
        (uint160 s1,,,) = pm.getSlot0(mainKey.toId());
        pm.initialize(secKey, s1);
        _seedSecondary(pm.getLiquidity(mainKey.toId()) / 2);
        executor.setSecondary(secKey);

        vm.deal(user, 100 ether);
        IERC20(coin).transfer(user, IERC20(coin).balanceOf(address(this)) / 2);
        vm.prank(user);
        IERC20(coin).approve(address(router), type(uint256).max);
    }

    function testFork_simulation() public {
        console2.log("main pool liquidity", uint256(pm.getLiquidity(mainKey.toId())));
        console2.log("secondary liquidity", uint256(pm.getLiquidity(secKey.toId())));
        console2.log("coin TARGET_ETH (wei)", IBCToken(coin).TARGET_ETH());

        uint256[6] memory sizes = [uint256(0.001 ether), 0.01 ether, 0.05 ether, 0.2 ether, 0.5 ether, 1 ether];
        for (uint256 i; i < sizes.length; ++i) {
            _scenario(sizes[i], true);
            _scenario(sizes[i], false);
        }
    }

    struct Result {
        uint256 gasPaused;
        uint256 gasOn;
        uint256 gapBefore;
        uint256 gapAfter;
        uint256 calls;
        uint256 legs;
        uint256 profit;
        uint256 execGas;
        uint256 received;
        uint256 lpAmount;
        uint256 recipientAmount;
    }

    /// @dev `buy`: ETH in for `size` wei. Sell: coin in worth `size` wei at the current price.
    function _scenario(uint256 size, bool buy) internal {
        Result memory r;
        uint256 snap = vm.snapshot();
        r.gasPaused = _swapGas(size, buy, true);
        vm.revertTo(snap);

        snap = vm.snapshot();
        r.gapBefore = _gapBps();
        executor.reset();
        vm.recordLogs();
        r.gasOn = _swapGas(size, buy, false);
        (r.received, r.lpAmount, r.recipientAmount) = _settled();
        r.gapAfter = _gapBps();
        r.calls = executor.rec(0);
        r.legs = executor.rec(1);
        r.profit = executor.rec(2);
        r.execGas = executor.rec(3);
        vm.revertTo(snap);
        _log(size, buy, r);
    }

    function _log(uint256 size, bool buy, Result memory r) internal pure {
        console2.log("----", buy ? "BUY" : "SELL", size);
        console2.log("  gas paused / with corrector", r.gasPaused, r.gasOn);
        console2.log("  correction cost (gas)", r.gasOn > r.gasPaused ? r.gasOn - r.gasPaused : 0);
        console2.log("  executor calls / legs / exec gas", r.calls, r.legs, r.execGas);
        console2.log("  gap before -> after (sqrt price, ppm)", r.gapBefore, r.gapAfter);
        console2.log("  profit wei / paid to corrector", r.profit, r.received);
        console2.log("  split lp / recipient", r.lpAmount, r.recipientAmount);
    }

    function _swapGas(uint256 size, bool buy, bool paused) internal returns (uint256 used) {
        if (paused) {
            vm.prank(factory.owner());
            corrector.setExecutor(address(0));
        }
        SwapParams memory p;
        uint256 value;
        if (buy) {
            p = SwapParams({
                zeroForOne: true, amountSpecified: -int256(size), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            value = size;
        } else {
            (uint160 s,,,) = pm.getSlot0(mainKey.toId());
            uint256 coinIn = FullMath.mulDiv(FullMath.mulDiv(size, s, 1 << 96), s, 1 << 96);
            p = SwapParams({
                zeroForOne: false, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });
        }
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(user, user);
        uint256 g0 = gasleft();
        router.swap{value: value}(mainKey, p, settings, "");
        used = g0 - gasleft();
    }

    /// @dev Price gap between the two pools in sqrt-price bps, times 100.
    function _gapBps() internal view returns (uint256) {
        (uint160 s1,,,) = pm.getSlot0(mainKey.toId());
        (uint160 s2,,,) = pm.getSlot0(secKey.toId());
        uint256 gap = s1 > s2 ? s1 - s2 : s2 - s1;
        return gap * 1_000_000 / s2;
    }

    function _settled() internal returns (uint256 received, uint256 lpAmount, uint256 recipientAmount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(corrector) && logs[i].topics[0] == SETTLED_TOPIC) {
                (received, lpAmount, recipientAmount) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    function _seedSecondary(uint128 liquidity) internal {
        IERC20(coin).approve(address(liqRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + 1000 ether);
        liqRouter.modifyLiquidity{value: 1000 ether}(
            secKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(SPACING),
                tickUpper: TickMath.maxUsableTick(SPACING),
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
    }

    function _launchAndGraduate() internal returns (address launched) {
        (uint256 virtualReserves, uint256 initialSupply,) = factory.initialParams();
        (,,, uint80 creationFee) = factory.feeConfig();
        vm.deal(address(this), creationFee);

        bytes memory bind = abi.encode(SPACING, uint16(5000));
        IFactoryHook.HookConfigV2 memory config = HookPayload.withFee(HookPayload.DEFAULT_FIXED_FEE);
        config = HookPayload.addCalculator(config, address(corrector), bind);
        config = HookPayload.addObserver(config, address(corrector), 1, bind);

        launched = factory.deploy{value: creationFee}(
            "WTH Sim",
            "WSIM",
            "WthCorrector fork simulation",
            "ipfs://wth-sim",
            50,
            keccak256(abi.encode("wth-sim", block.number)),
            IBCTokenFactory.LaunchConfig({
                directSeed: false, virtualReserves: virtualReserves, initialSupply: initialSupply, seedTick: 0
            }),
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            HookPayload.encode(config)
        );

        uint256 targetEth = IBCToken(launched).TARGET_ETH();
        vm.deal(address(this), targetEth * 2);
        IBondingCurve(factory.bondingCurve()).buy{value: targetEth * 2}(launched, address(0), 0);
        assertTrue(IBCToken(launched).isLPd(), "graduated");
    }

    receive() external payable {}
}
