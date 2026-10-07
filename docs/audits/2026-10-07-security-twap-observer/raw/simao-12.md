FINDING | contract: WthCorrector | function: _payout | bug_class: swapper-controlled-fallback-diverts-lp-share | group_key: WthCorrector | _payout | swapper-controlled-fallback-diverts-lp-share
root_cause: At L350, `_payout` sets `lpAmount = 0` when `POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0`. The swapper alone sets that slot with one free `sync`. The code neither keeps the LP share nor skips the correction; it moves the whole LP share to the fee recipient (L364). Breaks README "LPs never under 25 %".
internal_pre: Pool binds the corrector both roles with lpShareBps >= 2500. Executor set. Swapper is the coin's fee recipient (creator or an ally).
external_pre: The executor's route must not call `settle` or `sync` (nets legs against another V4 pool, pays with `take` plus transfer, like `WthExecutorMock`). If it calls `settle`, the digest reverts the correction.
path:
  1. Fee recipient R of coin C deploys a router; in `unlockCallback` it calls `POOL_MANAGER.sync(C)` and transfers nothing.
  2. Router swaps 0.3 ETH for C on the Frontier pool. Executor runs the correction, pays 1e15 wei WETH.
  3. `_payout`: CURRENCY_SLOT is C, `lpAmount = 0`, R gets all 1e15 (should be 0.7e15 with 0.3e15 donated at lpShareBps 3000).
  4. Router `sync(address(0))`, `settle{value}`, `take`. Unlock closes normally.
  5. PoC passes: scratchpad/work/simao-12/test/wth-corrector/SyncDivert.t.sol `test_presync_divertsLpShareToRecipient`. Honest router: recipient 0.88e15 (correction share plus hook fee); presync router: 1.18e15. Event changes from `CorrectionSettled(pid, 1e15, 3e14, 7e14)` to `CorrectionSettled(pid, 1e15, 0, 1e15)`.
impact: In-range LPs lose lpShareBps (25% to 100%) of every correction on swaps the fee recipient or an ally makes, while still carrying the zero-LP-fee correction legs. Cost: one `sync` call.
mitigation: Return from `onAfterSwap` before the executor call if `exttload(CURRENCY_SLOT) != 0`; do not route the LP share to the fee recipient; keep the zero-liquidity fallback.

LEAD | contract: WthCorrector | function: _payout | bug_class: executor-chosen-zero-liquidity-fallback | group_key: WthCorrector | _payout | executor-chosen-zero-liquidity-fallback
smell: The `getLiquidity(poolId) == 0` fallback at L349 is checked at the price the executor's legs leave; the executor picks it. LiquidityManager seeds bounded ranges, so gaps can exist outside them.
unverified: Whether the partner executor can or would end in a gap; whether real pools have gaps near the post-correction price.
description: The same branch as the finding, chosen by the executor instead of the swapper, gives the LP share to the recipient whenever the final tick has zero liquidity.

LEAD | contract: WthCorrector | function: _payout | bug_class: jit-capture-of-donation | group_key: WthCorrector | _payout | jit-capture-of-donation
smell: `donate` at L360 pays only in-range liquidity at donation time inside the user's swap. A swapper can add concentrated liquidity at the expected end tick in one unlock, swap, remove.
unverified: Predictability of the end tick, net result after the swap trades through the JIT position; no PoC.
description: This is the standard V4 donate-JIT shape, applied to the payment meant to compensate passive LPs.

LEAD | contract: WthCorrector | function: _openWindow | bug_class: asymmetric-band-margin | group_key: WthCorrector | _openWindow | asymmetric-band-margin
smell: At L277 the edge is `referenceTick -/+ 1` with referenceTick the floor tick of the pre-swap price: margin 1 to 2 ticks for zeroForOne, 0 to 1 tick for oneForZero.
unverified: Only the LP fee on less than one tick is at stake; may be intended.
description: The two directions of the same band computation do not give the same margin.

Functions opened: 54; lifecycles closed: 8
