# Severity annex: frontier-extensions (full scope)

_EVM Cortex layer over [`full-report.md`](full-report.md) (stamp `20261007-140638`). Severity is impact times likelihood per the global severity matrix, and it is independent of confidence. `#` is the number of the finding in the report. Rows: 6 of 6 findings._

| # | Severity | Confidence | Title | Location |
|---|---|---|---|---|
| 1 | Medium | [90] | Executor pays the router debt with settleFor and borrows it back, so the digest check in _correct passes | `WthCorrector._correct` |
| 2 | Medium | [90] | Delta digest misses executor deltas and synced reserves, so a hostile executor reverts multi-step swaps | `WthCorrector._deltaDigest` |
| 3 | Medium | [85] | Executor legs count as a new price move in the hook, so later swappers pay a higher volatility fee | `WthCorrector.onAfterSwap` |
| 4 | Medium | [80] | quoteFee gives the floor fee to any in-band swapper, so a creator-bound observer trades inside the window at 3 bps | `WthCorrector.quoteFee` |
| 6 | Medium | [75] | The LP share is donated to liquidity in range at payout, so a same-transaction position takes most of it | `WthCorrector._payout` |
| 5 | Low | [75] | The band edge reads a referenceTick that nested swaps overwrite, so the band can reach past the user's pre-swap price | `WthCorrector._openWindow` |

## Proof of concept

_No finding is Critical or High, so no PoC is mandatory. The agents wrote PoCs for five of the six Medium findings. All of them were copied into one isolated copy of the repo at `da5dce3` and run together with `FOUNDRY_OFFLINE=true forge test --match-path 'test/poc/**'` on forge 1.7.1 (local chain, no fork, so no block pin applies). Result: 342 tests passed, 2 failed. The 2 failures are exploratory tests of agent 6 that try the single-hop route. They fail as the agent predicted, which confirms that a single-hop swap is safe._

| # | Severity | PoC | Status |
|---|---|---|---|
| 1 | Medium | [`poc/pashov-7/DigestBypass.t.sol`](../../poc/pashov-7/DigestBypass.t.sol) `test_hostileExecutor_passesDigest_butRevertsUserSwap` | passes, with 2 control tests |
| 2 | Medium | [`poc/pashov-5/DebtShiftPoC.t.sol`](../../poc/pashov-5/DebtShiftPoC.t.sol), [`poc/pashov-6/DigestBypass.t.sol`](../../poc/pashov-6/DigestBypass.t.sol), [`poc/pashov-6/ReservesBypass.t.sol`](../../poc/pashov-6/ReservesBypass.t.sol), [`poc/pashov-8/Poc8.t.sol`](../../poc/pashov-8/Poc8.t.sol), [`poc/pashov-4/ResyncPoC.t.sol`](../../poc/pashov-4/ResyncPoC.t.sol) | all headline tests pass |
| 3 | Medium | [`poc/pashov-12/VolatilitySeam.t.sol`](../../poc/pashov-12/VolatilitySeam.t.sol) `test_seam_volatility_corrected` vs `_uncorrected` | passes: volatility 562 with the correction, 282 without |
| 4 | Medium | [`poc/pashov-11/WindowObserver.t.sol`](../../poc/pashov-11/WindowObserver.t.sol) `test_creatorObserver_tradesInTheWindowAtTheFloor` | passes |
| 6 | Medium | [`poc/simao-10/SwapperJitPoC.t.sol`](../../poc/simao-10/SwapperJitPoC.t.sol) (from the Simao pipeline) | passes: 95.2% of the donation captured |
| 5 | Low | none | description only |

## Fix verification (confidence 75 or more)

- **#1, #2 (digest).** Option C of #2 (return when a currency is synced) closes the re-sync and settle mechanisms, because the presync state is the precondition. It does not close the `settleFor` plus `take` mechanism of #1, which needs no synced currency. Option A (executor deltas) closes that mechanism only for an executor that takes in its own name. The executor can call `take` from a helper contract it deploys, which opens the debt on the helper, so Option A alone is not complete. Option D (skip when any party other than the hook and the corrector holds an open delta) closes both, but it also skips every correction on a multi-hop route. Recommended: Option C plus a skip when the nonzero-delta count shows a foreign open delta, and a README statement of the residual trust in the executor. No new reentrancy path: each option only returns early or adds a read.
- **#3 (volatility).** The fix sits in the hook, which is out of scope. A corrector-side fix is to refuse a binding next to a volatility-priced calculator, which needs the corrector to read the pool's calculator list at bind time.
- **#4 (window).** Closing the window in the corrector's nested `onAfterSwap` works only if the corrector is notified before any other observer of the nested leg. The README asks for the corrector to be listed last, so the order rule has to change, or the window must be bound to the executor through `hookData`.
- **#6 (JIT).** Deferring the donation to a later transaction removes the same-transaction capture. A deferred donation still pays whoever is in range at that later time, so a two-transaction JIT stays possible at the cost of one block of price exposure.
- **Pattern check.** `rg "donate\(|exttload\(|settle\(|take\("` over `contracts/` finds no other site with the same shape. `TwapObserver` makes no PoolManager call.

```
Severity: Critical 0 · High 0 · Medium 5 · Low 1 · Informational 0
```
