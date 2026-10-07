// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

import {HostileExecutorMock} from "../../wth-corrector/HostileExecutorMock.sol";

/// @dev A swapper's router: add a narrow position, swap, remove it, all in one unlock.
contract SwapperJitRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    int128 public fees0;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function run(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity, uint256 ethIn) external {
        pm.unlock(abi.encode(key, lower, upper, liquidity, ethIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity, uint256 ethIn) =
            abi.decode(data, (PoolKey, int24, int24, uint128, uint256));
        if (liquidity != 0) {
            pm.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: 0
                }),
                ""
            );
        }
        pm.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        if (liquidity != 0) {
            (, BalanceDelta fees) = pm.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: lower, tickUpper: upper, liquidityDelta: -int256(uint256(liquidity)), salt: 0
                }),
                ""
            );
            fees0 = fees.amount0();
        }
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency currency) internal {
        int256 delta = pm.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            pm.sync(currency);
            if (currency.isAddressZero()) {
                pm.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(pm), owed);
                pm.settle();
            }
        } else if (delta > 0) {
            pm.take(currency, address(this), uint256(delta));
        }
    }
}

contract SwapperJitPoCTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;
    using StateLibrary for IPoolManager;

    uint24 internal constant BASE_FEE = 3000;
    uint16 internal constant LP_BPS = 3000;
    uint256 internal constant MIN_GAS = 250_000;
    uint256 internal constant MIN_PAYMENT = 1e12;
    uint256 internal constant USER_BUY = 0.3 ether;
    uint256 internal constant PAYMENT = 0.01 ether;

    WthCorrector internal corrector;
    HostileExecutorMock internal executor;
    SwapperJitRouter internal router;
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

        router = new SwapperJitRouter(poolManager);
        vm.deal(address(router), 100 ether);
        uint256 held = wCoin.balanceOf(users.buyerOne);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), held);
    }

    function _postSwapRange() internal returns (int24 lower, int24 upper) {
        uint256 snap = vm.snapshot();
        executor.set(HostileExecutorMock.Mode.Idle, 0);
        router.run(key, 0, 0, 0, USER_BUY);
        (, int24 tick,,) = poolManager.getSlot0(pid);
        vm.revertTo(snap);
        lower = tick / TICK_SPACING * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) lower -= TICK_SPACING;
        upper = lower + TICK_SPACING;
    }

    function _runJit(uint256 payment) internal returns (int128 fees0) {
        (int24 lower, int24 upper) = _postSwapRange();
        uint128 liq = poolManager.getLiquidity(pid) * 20;
        executor.set(HostileExecutorMock.Mode.Idle, payment);
        router.run(key, lower, upper, liq, USER_BUY);
        fees0 = router.fees0();
    }

    function test_swapperJit_capturesDonation() public {
        uint256 snap = vm.snapshot();
        int128 baseline = _runJit(0); // correction reverts: PaymentTooLow(0)
        vm.revertTo(snap);
        int128 withDonation = _runJit(PAYMENT);

        uint256 lpAmount = PAYMENT * LP_BPS / 10_000;
        uint256 captured = uint256(int256(withDonation - baseline));
        console.log("LP share donated (wei):", lpAmount);
        console.log("captured by the swapper's same-tx position:", captured);
        assertGt(captured * 100, lpAmount * 90, "swapper takes over 90% of the LP share");
    }
}
