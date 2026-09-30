// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IWthArbitrageExecutor
 * @notice The partner executor `WthCorrector` calls after a user swap. Only the ABI matters: the
 * field types and their order fix the selector (`0xd4641322`); the names do not.
 */
interface IWthArbitrageExecutor {
    /**
     * @notice The profit shares the caller names, in bps; the three shares sum to 8000.
     * @param creator The address paid `creatorBps`.
     * @param traderBps The trader's share.
     * @param creatorBps The creator's share.
     * @param triggerPoolBps The triggering pool's share.
     */
    struct ProfitSplit {
        address creator;
        uint16 traderBps;
        uint16 creatorBps;
        uint16 triggerPoolBps;
    }

    /**
     * @notice Runs one arbitrage against the pool that triggered it and pays out the split.
     * @param triggeringPool The pool the user swapped on.
     * @param rebateRecipient The trader rebate destination, or the zero address.
     * @param split The profit shares.
     * @return profit The realized profit, in the executor's own unit.
     */
    function executeArbitrage(PoolKey calldata triggeringPool, address rebateRecipient, ProfitSplit calldata split)
        external
        returns (uint256 profit);
}
