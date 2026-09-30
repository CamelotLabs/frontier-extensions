// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCToken} from "frontier/interfaces/IBCToken.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IBondingCurve} from "frontier/interfaces/IBondingCurve.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookPayload} from "kit/HookPayload.sol";

import {WthCorrectorHarness} from "../wth-corrector/PoolStatePrefix.t.sol";

/// @notice The liquidity manager reads this test needs (not part of the published hook interfaces).
interface ILiquidityManagerView {
    function hook() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function getPoolKey(address coin) external view returns (PoolKey memory);
}

/**
 * @notice Against the LIVE Frontier contracts on Robinhood Chain: launches a plain coin through the
 * real factory (no extension bound), graduates it, and checks that the raw `getPoolState` prefix read
 * `WthCorrector` relies on agrees with the live hook's typed decode, before and after a swap.
 * @dev Run: `FOUNDRY_PROFILE=fork forge test`. Uses `RPC_URL` (default: the public Robinhood RPC)
 * and forks the latest block unless `FORK_BLOCK_NUMBER` is set (pinning needs an archive RPC).
 */
contract WthCorrectorLiveTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Frontier `BCTokenFactory` on Robinhood Chain (4663). Everything else is read from it.
    address internal constant FACTORY = 0xe3A826C056e578c240D362BF4C2fa53E5c0c17a5;

    IBCTokenFactory internal factory = IBCTokenFactory(FACTORY);
    ILiquidityManagerView internal liquidityManager;
    IPoolManager internal poolManager;
    IFactoryHook internal hook;
    PoolSwapTest internal router;
    WthCorrectorHarness internal harness;

    address internal buyer = makeAddr("buyer");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 blockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);

        liquidityManager = ILiquidityManagerView(factory.liquidityManager());
        poolManager = IPoolManager(liquidityManager.POOL_MANAGER());
        hook = IFactoryHook(liquidityManager.hook());
        router = new PoolSwapTest(poolManager);
        harness = new WthCorrectorHarness(FACTORY, poolManager, factory.WETH());
        vm.deal(buyer, 10 ether);
    }

    function testFork_poolStatePrefix_matchesTheLiveHook() public {
        address coin = _launchAndGraduate();
        PoolKey memory key = liquidityManager.getPoolKey(coin);
        PoolId poolId = key.toId();

        assertEq(hook.getPoolState(poolId).coin, coin, "registered on the live hook");
        _assertMatches(poolId);

        (, int24 preTick,,) = poolManager.getSlot0(poolId);
        vm.prank(buyer, buyer);
        router.swap{value: 0.1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(_assertMatches(poolId), preTick, "pre-swap tick of the last swap");
    }

    function _assertMatches(PoolId poolId) internal view returns (int24 typed) {
        typed = hook.getPoolState(poolId).referenceTick;
        assertEq(harness.referenceTick(address(hook), poolId), typed, "raw prefix read");
    }

    /// @dev Launches on the default curve with an empty hook payload, then buys the whole curve so
    /// the coin graduates to its Uniswap v4 pool.
    function _launchAndGraduate() internal returns (address coin) {
        (uint256 virtualReserves, uint256 initialSupply,) = factory.initialParams();
        (,,, uint80 creationFee) = factory.feeConfig();
        vm.deal(address(this), creationFee);

        coin = factory.deploy{value: creationFee}(
            "Prefix Test",
            "PFX",
            "Frontier extensions fork test",
            "ipfs://extensions",
            50,
            keccak256(abi.encode("extensions", block.number)),
            IBCTokenFactory.LaunchConfig({
                directSeed: false, virtualReserves: virtualReserves, initialSupply: initialSupply, seedTick: 0
            }),
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            HookPayload.encode(HookPayload.withFee(HookPayload.DEFAULT_FIXED_FEE))
        );

        uint256 targetEth = IBCToken(coin).TARGET_ETH();
        vm.deal(address(this), targetEth * 2);
        IBondingCurve(factory.bondingCurve()).buy{value: targetEth * 2}(coin, address(0), 0);
        assertTrue(IBCToken(coin).isLPd(), "graduated");
    }

    receive() external payable {}
}
