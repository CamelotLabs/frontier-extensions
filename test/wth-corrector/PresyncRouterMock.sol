// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Test double for a two-hop router with deferred settlement: it syncs and transfers the coin
/// before its hops (sell on a plain pool, buy back on the Frontier pool with the ETH credit) and
/// settles after them, so the coin is still the synced currency when the Frontier hop's observers run.
contract PresyncRouterMock is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    function roundTrip(PoolKey memory plainKey, PoolKey memory frontierKey, uint256 coinIn) external {
        poolManager.unlock(abi.encode(plainKey, frontierKey, coinIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pm");
        (PoolKey memory plainKey, PoolKey memory frontierKey, uint256 coinIn) =
            abi.decode(data, (PoolKey, PoolKey, uint256));

        poolManager.sync(plainKey.currency1);
        IERC20(Currency.unwrap(plainKey.currency1)).transfer(address(poolManager), coinIn);

        BalanceDelta hop1 = poolManager.swap(
            plainKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 ethGot = uint256(uint128(hop1.amount0()));
        BalanceDelta hop2 = poolManager.swap(
            frontierKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethGot), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        poolManager.settle();
        poolManager.take(frontierKey.currency1, address(this), uint256(uint128(hop2.amount1())));
        return "";
    }
}
