// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {HookPayload} from "kit/HookPayload.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

/// Two-hop router that settles by reading its live deltas (Universal Router SETTLE_ALL / TAKE_ALL style).
contract TwoHopRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function go(PoolKey memory plainKey, PoolKey memory frontierKey, uint256 coinIn) external {
        pm.unlock(abi.encode(plainKey, frontierKey, coinIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory plainKey, PoolKey memory frontierKey, uint256 coinIn) =
            abi.decode(data, (PoolKey, PoolKey, uint256));
        BalanceDelta hop1 = pm.swap(
            plainKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        pm.swap(
            frontierKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(uint128(hop1.amount0()))),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        Currency coin = frontierKey.currency1;
        int256 d = pm.currencyDelta(address(this), coin);
        if (d < 0) {
            pm.sync(coin);
            IERC20(Currency.unwrap(coin)).transfer(address(pm), uint256(-d));
            pm.settle();
        }
        d = pm.currencyDelta(address(this), coin);
        if (d > 0) pm.take(coin, address(this), uint256(d));
        return "";
    }
}

contract ShuffleExecutor is IWthArbitrageExecutor {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    address public immutable corrector;
    address public victimRouter;
    bool public hostile;

    constructor(IPoolManager _pm, address _corrector) {
        pm = _pm;
        corrector = _corrector;
    }

    receive() external payable {}

    function set(address router, bool h) external {
        victimRouter = router;
        hostile = h;
    }

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        if (hostile) {
            int256 routerDebt = pm.currencyDelta(victimRouter, key.currency1);
            require(routerDebt < 0, "router owes no coin");
            uint256 debt = uint256(-routerDebt);
            // borrow the coin from the PoolManager: the executor's coin delta turns nonzero (+1)
            pm.take(key.currency1, address(this), debt);
            // pay the router's coin debt for it: the router's coin delta turns zero (-1)
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), debt);
            pm.settleFor(victimRouter);
        }
        (bool ok,) = corrector.call{value: 1e12}("");
        require(ok, "pay");
        return 0;
    }
}

contract DigestShuffleTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;
    using StateLibrary for IPoolManager;

    WthCorrector internal corrector;
    ShuffleExecutor internal executor;
    TwoHopRouter internal router;
    MockBCToken internal wCoin;
    PoolId internal pid;
    PoolKey internal plainKey;

    function setUp() public override {
        super.setUp();
        corrector = new WthCorrector(address(factory), poolManager, address(weth), 250_000, 1e12);
        (wCoin, pid) = _deployGraduated(
            HookPayload.withFee(3000).addCalculator(address(corrector), abi.encode(TICK_SPACING, uint16(3000)))
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, abi.encode(TICK_SPACING, uint16(3000))),
            false
        );
        executor = new ShuffleExecutor(poolManager, address(corrector));
        vm.deal(address(executor), 1 ether);
        vm.prank(users.owner);
        corrector.setExecutor(address(executor));
        router = new TwoHopRouter(poolManager);

        uint256 held = wCoin.balanceOf(users.buyerOne);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(this), held);

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
            sqrtPrice, TickMath.getSqrtPriceAtTick(low), TickMath.getSqrtPriceAtTick(high), 2 ether, held / 2
        );
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
        wCoin.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 10 ether);
        lp.modifyLiquidity{value: 2 ether}(
            plainKey,
            ModifyLiquidityParams({tickLower: low, tickUpper: high, liquidityDelta: int256(uint256(liquidity)), salt: 0}),
            ""
        );
        wCoin.transfer(address(router), held / 100);
    }

    function test_control_honestExecutor_twoHopCompletes() public {
        executor.set(address(router), false);
        vm.recordLogs();
        router.go(plainKey, _poolKey(address(wCoin)), wCoin.balanceOf(address(router)) / 2);
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 1, "settled");
    }

    function test_singleHop_hostileExecutorFindsNoDebt() public {
        executor.set(address(swapRouter), true);
        vm.recordLogs();
        assertGt(_swapEthForCoin(address(wCoin), users.buyerTwo, 0.3 ether), 0, "single hop completes");
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 0, "correction unwound");
    }

    function test_hostileExecutor_passesDigest_revertsTwoHopSwap() public {
        executor.set(address(router), true);
        uint256 amount = wCoin.balanceOf(address(router)) / 2;
        PoolKey memory fk = _poolKey(address(wCoin));
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.go(plainKey, fk, amount);
    }

    function _countLogs(address emitter, bytes32 topic) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) ++n;
        }
    }
}
