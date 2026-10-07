FINDING | contract: WthCorrector | function: onAfterSwap | bug_class: correction-legs-inflate-hook-volatility | group_key: WthCorrector | onAfterSwap | correction-legs-inflate-hook-volatility
seam: three-way (execution × periphery × first-principles)
trace: user swap → hook `_settleSwapTail` → `WthCorrector.onAfterSwap` → `_callExecutor` → executor in-band leg → hook `_beforeSwap` → `_updateVolatility` adds the user move to `volatilityAccumulator` and sets `referenceTick` to the user post-swap tick → the leg moves the price back → the next user swap reads `decayed(acc) + |tick - referenceTick|`, about 2× the user move → `DynamicFeeExtension.quoteFee` returns a higher tier
violated_principle: The correction restores the pre-swap price, so the volatility reading should fall back. Here a correction that undoes the move doubles the reading, and later users pay a fee tier the market move never reached.
path: any user swap on a pool that binds WthCorrector and DynamicFeeExtension → correction runs → hook volatility for the next swaps doubles for up to DECAY_WINDOW (600 s) → each later swap in that window pays midFee or capFee instead of floorFee
proof: PoC on the real v1.1 hook at scratchpad/work/pashov-12/test/wth-corrector/VolatilitySeam.t.sol, extends WthCorrectorHostileTest, buys 0.06 ETH of coin, reads `hook.getVolatility` 1 s later. Without a correction (executor pays 0, correction reverts): tick 173445 → 173162, volatility 282. With a paid in-band correction: tick 173445 → 173443 (price restored), volatility 562. DynamicFeeExtension defaults T1 = 300, T2 = 900. Without correction the next swaps pay floorFee 3000 pips; with it, midFee 5000 pips while 562 × (600 - e) / 600 >= 300 (~280 s). A user move of 450+ ticks gives 900+ after correction, so later swaps pay capFee 12 000 pips. `FOUNDRY_OFFLINE=true forge test --match-test test_seam -vv`.
description: Each executor leg registers as a new price move in the hook, so after a correction later users pay a higher volatility fee tier.
fix: Do not count swaps that run inside an open correction window in the hook volatility, or block a pool from binding WthCorrector with a volatility fee calculator.

LEAD | contract: WthCorrector | function: _openWindow | bug_class: band-from-overwritten-reference-tick | group_key: WthCorrector | _openWindow | band-from-overwritten-reference-tick
seam: execution × periphery
code_smells: `_openWindow` reads `referenceTick` (PoolState word 3) and `slot0` when the corrector runs, not when the user swap ends. The hook overwrites `referenceTick` in every nested `_beforeSwap`. An observer bound before the corrector can run a nested swap, moving `referenceTick` and the price, and triggering its own correction because `LOCK_TSLOT` is not set yet.
description: An earlier observer that swaps changes the tick that the corrector uses for the band of the user swap. We did not find a deployed observer that swaps in `onAfterSwap`.

LEAD | contract: WthCorrector | function: _openWindow | bug_class: asymmetric-band-edge | group_key: WthCorrector | _openWindow | asymmetric-band-edge
seam: execution × first-principles
code_smells: `edgeTick = zeroForOne ? ref - 1 : ref + 1` with floor tick `ref`. For zeroForOne, `edge = sqrt(ref - 1)` is 1 to 2 ticks below the pre-swap price, so a swap crossing one boundary (post in tick ref - 1) gives `lower >= upper`, band zero. For oneForZero, `edge = sqrt(ref + 1)` is 0 to 1 tick above. `currentBand` NatSpec says the band is zero only when the swap crossed no tick boundary.
description: The band edge is one tick wider for zeroForOne swaps than for oneForZero swaps, so the code disagrees with the NatSpec. We found no loss of funds from it.

LEAD | contract: WthCorrector | function: _callExecutor | bug_class: correction-legs-feed-other-observers | group_key: WthCorrector | _callExecutor | correction-legs-feed-other-observers
seam: periphery × first-principles
code_smells: Executor legs are real hooked swaps, so the hook notifies every observer on the pool for each leg. `LotteryRecipient.onAfterSwap` (frontier-contracts) mints tickets weighted by `feeAmount` to `tx.origin` when hookData is empty, which is the user who triggered the correction. The legs pay the floor only and the treasury takes all of it, so they add nothing to the prize pot. `MilestonesObserver` also counts the leg ETH as volume.
description: A user who triggers a correction also gets lottery tickets for the executor legs. We did not measure whether the WETH payout to the fee recipient covers this.

Functions opened: 64
