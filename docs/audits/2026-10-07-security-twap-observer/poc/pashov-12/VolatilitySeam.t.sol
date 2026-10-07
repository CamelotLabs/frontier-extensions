// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HostileExecutorMock} from "../../wth-corrector/HostileExecutorMock.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrectorHostileTest} from "../../wth-corrector/WthCorrectorHostile.t.sol";

contract VolatilitySeamTest is WthCorrectorHostileTest {
    using StateLibrary for IPoolManager;

    function _prime() internal returns (uint256 bought) {
        uint256 coinsBefore = wCoin.balanceOf(address(executor));
        executor.set(HostileExecutorMock.Mode.Idle, 0);
        executor.buy(key, 0.2 ether);
        bought = wCoin.balanceOf(address(executor)) - coinsBefore;
        // let the priming swap decay fully
        vm.warp(block.timestamp + 1000);
    }

    function test_seam_volatility_uncorrected() public {
        _prime();
        (, int24 t0,,) = poolManager.getSlot0(pid);
        // executor pays nothing: the correction reverts, as if no corrector were bound
        executor.set(HostileExecutorMock.Mode.Idle, 0);
        _swapEthForCoin(address(wCoin), users.buyerTwo, 0.06 ether);
        (, int24 t1,,) = poolManager.getSlot0(pid);
        vm.warp(block.timestamp + 1);
        emit log_named_int("uncorrected: tick before", t0);
        emit log_named_int("uncorrected: tick after", t1);
        emit log_named_uint("uncorrected: volatility read by the next swap", hook.getVolatility(pid));
    }

    function test_seam_volatility_corrected() public {
        uint256 bought = _prime();
        (, int24 t0,,) = poolManager.getSlot0(pid);
        executor.setSellAmount(bought);
        executor.set(HostileExecutorMock.Mode.InBandSell, MIN_PAYMENT);
        vm.recordLogs();
        _swapEthForCoin(address(wCoin), users.buyerTwo, 0.06 ether);
        assertEq(_countLogs(address(corrector), IWthCorrector.CorrectionSettled.selector), 1, "settled");
        (, int24 t1,,) = poolManager.getSlot0(pid);
        vm.warp(block.timestamp + 1);
        emit log_named_int("corrected: tick before", t0);
        emit log_named_int("corrected: tick after correction", t1);
        emit log_named_uint("corrected: volatility read by the next swap", hook.getVolatility(pid));
    }
}
