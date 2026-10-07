// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthExecutorMock} from "../../wth-corrector/WthExecutorMock.sol";
import {WthCorrectorTest} from "../../wth-corrector/WthCorrector.t.sol";

contract SyncBuyRouter is IUnlockCallback {
    IPoolManager public immutable pm;
    constructor(IPoolManager _pm) { pm = _pm; }
    receive() external payable {}
    function buy(PoolKey memory key, uint256 ethIn, bool presync) external payable {
        pm.unlock(abi.encode(key, ethIn, presync));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 ethIn, bool presync) = abi.decode(data, (PoolKey, uint256, bool));
        if (presync) pm.sync(key.currency1); // one free call, nothing transferred
        BalanceDelta d = pm.swap(key, SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), "");
        if (presync) pm.sync(CurrencyLibrary.ADDRESS_ZERO); // reset before the native settle
        pm.settle{value: uint256(uint128(-d.amount0()))}();
        pm.take(key.currency1, address(this), uint256(uint128(d.amount1())));
        return "";
    }
}

contract SyncDivertTest is WthCorrectorTest {
    function test_presync_divertsLpShareToRecipient() public {
        executor.setPay(WthExecutorMock.PayMode.Weth, PAYMENT);
        SyncBuyRouter router = new SyncBuyRouter(poolManager);
        vm.deal(address(router), 10 ether);

        uint256 snap = vm.snapshot();
        uint256 r0 = weth.balanceOf(recipient);
        vm.expectEmit(true, false, false, true, address(corrector));
        emit IWthCorrector.CorrectionSettled(pid, PAYMENT, PAYMENT * LP_BPS / 10_000, PAYMENT - PAYMENT * LP_BPS / 10_000);
        router.buy(key, USER_BUY, false);
        uint256 honest = weth.balanceOf(recipient) - r0;
        vm.revertTo(snap);

        r0 = weth.balanceOf(recipient);
        vm.expectEmit(true, false, false, true, address(corrector));
        emit IWthCorrector.CorrectionSettled(pid, PAYMENT, 0, PAYMENT);
        router.buy(key, USER_BUY, true);
        uint256 diverted = weth.balanceOf(recipient) - r0;
        emit log_named_uint("recipient honest", honest);
        emit log_named_uint("recipient presync", diverted);
        assertEq(diverted - honest, PAYMENT * LP_BPS / 10_000, "LP share diverted");
    }
}
