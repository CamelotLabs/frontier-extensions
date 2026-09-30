// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFeeCalculator} from "frontier/interfaces/extensions/IFeeCalculator.sol";
import {IHookObserver} from "frontier/interfaces/extensions/IHookObserver.sol";

/**
 * @title IWthCorrector
 * @notice The correction extension: bound on a pool as its last fee calculator and as an after-swap
 * observer, it has the partner executor close the price gap the user's swap opened and splits the
 * executor's payment, in WETH or native ETH, between the pool's LPs and the coin's fee recipient in
 * the shares the pool bound at launch.
 * @dev A correction runs inside the user's swap, under the hook's observer budget. The legs the
 * executor sends back through the pool are priced by `quoteFee`: a leg opposite to the user's swap,
 * exact-input, with a price limit strictly inside the band the swap opened pays the protocol floor
 * only. A failed correction, or one paid under `MIN_PAYMENT_WEI` in WETH and native ETH together,
 * reverts as a whole, which the hook swallows.
 */
interface IWthCorrector is IFeeCalculator, IHookObserver {
    /**
     * @notice One pool's binding, written at registration.
     * @param coin The coin paired with native ETH.
     * @param tickSpacing The pool's tick spacing.
     * @param lpShareBps Share of every payment donated to the pool's LPs, in bps; the rest goes to the fee recipient.
     * @param roles Bitmask of the roles bound so far (`ROLE_CALCULATOR`, `ROLE_OBSERVER`).
     */
    struct PoolBinding {
        address coin;
        int24 tickSpacing;
        uint16 lpShareBps;
        uint8 roles;
    }

    /**
     * @notice The executor pointer changed; the zero address pauses corrections.
     * @param previousExecutor The executor before the change.
     * @param executor The executor after the change.
     */
    event ExecutorSet(address indexed previousExecutor, address indexed executor);

    /**
     * @notice Tokens held by the corrector were sent out by the factory owner.
     * @param token The token recovered.
     * @param to The recipient.
     * @param amount The amount sent.
     */
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice A correction paid and its payment was split.
     * @param poolId The pool the user swapped on.
     * @param received The payment counted, WETH and native ETH together, in wei.
     * @param lpAmount The share donated to the pool's in-range liquidity.
     * @param recipientAmount The share paid to the coin's fee recipient.
     */
    event CorrectionSettled(PoolId indexed poolId, uint256 received, uint256 lpAmount, uint256 recipientAmount);

    /// @notice Caller is not the BC token factory owner.
    error OnlyFactoryOwner();

    /// @notice A zero address was supplied where one is not allowed.
    error InvalidZeroAddress();

    /// @notice The LP share is not between `MIN_LP_SHARE_BPS` and 10 000 bps.
    error InvalidShares();

    /// @notice The register payload is not `(int24 tickSpacing, uint16 lpShareBps)`, the resulting pool key does not
    /// hash to the pool id, or the two roles disagree.
    error InvalidPoolConfig();

    /// @notice The pool already bound this role.
    error RoleAlreadyBound();

    /// @notice The hook did not answer `getPoolState` with the expected prefix.
    error PoolStateUnavailable();

    /// @notice The executor's payment is below `MIN_PAYMENT_WEI`.
    error PaymentTooLow(uint256 received);

    /// @notice The executor call reverted.
    error ExecutorCallFailed();

    /// @notice The executor left the PoolManager delta snapshot changed.
    error DeltaSnapshotChanged();

    /// @notice `recoverERC20` is not available while a correction is in progress.
    error CorrectionInProgress();

    /// @notice Native ETH is accepted only while a correction is in progress.
    error EthNotAccepted();

    /// @notice WETH refused the transfer.
    error TransferFailed();

    /**
     * @notice Role bit of the fee-calculator binding.
     * @return The bit.
     */
    function ROLE_CALCULATOR() external view returns (uint8);

    /**
     * @notice Role bit of the observer binding.
     * @return The bit.
     */
    function ROLE_OBSERVER() external view returns (uint8);

    /**
     * @notice The Uniswap V4 pool manager.
     * @return The pool manager.
     */
    function POOL_MANAGER() external view returns (IPoolManager);

    /**
     * @notice The canonical WETH, the payout asset.
     * @return The WETH address.
     */
    function WETH() external view returns (address);

    /**
     * @notice Lowest LP share a pool may bind, in bps.
     * @return The minimum, in bps.
     */
    function MIN_LP_SHARE_BPS() external view returns (uint16);

    /**
     * @notice The `creatorBps` named in the profit split handed to the executor: 8000 bps, the sum of the split's
     * three shares, `traderBps` and `triggerPoolBps` being zero.
     * @return The share, in bps.
     */
    function CREATOR_BPS() external view returns (uint16);

    /**
     * @notice Gas left below which `onAfterSwap` returns without calling the executor.
     * @return The threshold, in gas.
     */
    function MIN_CORRECTION_GAS() external view returns (uint256);

    /**
     * @notice Payment below which a correction reverts and its legs unwind, in wei.
     * @return The minimum, in wei.
     */
    function MIN_PAYMENT_WEI() external view returns (uint256);

    /**
     * @notice Gas kept back from the executor call for the snapshot check and the payout.
     * @return The reserve, in gas.
     */
    function TAIL_RESERVE() external view returns (uint256);

    /**
     * @notice The partner executor called after every swap on a bound pool; the zero address pauses corrections.
     * @return The executor.
     */
    function executor() external view returns (address);

    /**
     * @notice Sets the executor; the BC token factory owner only. The zero address pauses corrections.
     * @param newExecutor The executor to call.
     */
    function setExecutor(address newExecutor) external;

    /**
     * @notice Sends tokens held by the corrector to `to`; the BC token factory owner only, outside a correction.
     * @param token The token to recover.
     * @param to The recipient.
     * @param amount The amount to send.
     */
    function recoverERC20(address token, address to, uint256 amount) external;

    /**
     * @notice The price band of the correction in progress on `poolId`: the pool's post-swap price and its
     * pre-swap price moved one tick inside. Zeros while no correction is in progress on the pool, or when the swap
     * did not move the price past a tick boundary.
     * @param poolId The V4 pool id.
     * @return lower The lower sqrt price, X96.
     * @return upper The upper sqrt price, X96.
     */
    function currentBand(PoolId poolId) external view returns (uint160 lower, uint160 upper);

    /**
     * @notice A pool's binding (all-zero when unbound).
     * @param poolId The V4 pool id.
     * @return The binding.
     */
    function bindingOf(PoolId poolId) external view returns (PoolBinding memory);
}
