FINDING | contract: WthCorrector | function: quoteFee | bug_class: window-fee-any-swapper | group_key: WthCorrector | quoteFee | window-fee-any-swapper
seam: three-way (access x economics x asymmetry)
actor: the coin creator, through an observer it binds on its pool at launch. Any observer bound on the pool qualifies.
path: user swaps -> corrector.onAfterSwap opens the window, calls the executor -> executor's in-band leg runs PoolManager.swap -> hook _settleSwapTail notifies every bound observer for that nested leg -> creator's observer reads currentBand(poolId) and swaps opposite, exact-input, limit upper-1 -> quoteFee (L159-170) returns 0 (checks only window, direction, exact-in, limit; never the swapper) -> hook floors to 300 pips, LP fee 0 -> observer settles its own deltas, digest holds -> executor pays MIN_PAYMENT_WEI -> CorrectionSettled, observer leg stands.
proof: PoC scratchpad/work/pashov-11/test/poc11/WindowObserver.t.sol, `FOUNDRY_OFFLINE=true forge test --match-contract WindowObserverPoC -vv`, PASSES on real v1.1 hook. Base fee 3000 pips, lpShareBps 3000, observers [WindowSniper, corrector]. Lean executor sells 1e15 coin in band, pays 1e12 wei. User buys 1.0448e25 coin for 0.3 ETH. Inside the executor's leg, the sniper's quoteFee returns 0, sniper sells 1.0504e25 coin for 0.2989 ETH. feeGrowthGlobal1 0 before and after. CorrectionSettled emitted.
description: A creator-bound observer swaps inside the executor's leg at the 3 bps floor, because quoteFee grants the floor to every in-band swap, so LPs lose their fee.
fix: Close the window in the corrector's nested onAfterSwap (corrector bound as first observer) and let only the executor reopen it per leg, so no other swapper gets the floor.

LEAD | contract: WthCorrector | function: _correct | bug_class: executor-unlock-scope | group_key: WthCorrector | _correct | executor-unlock-scope
seam: three-way (access x economics x asymmetry)
actor: the executor the factory owner sets (no delay)
code_smells: _deltaDigest covers only NonzeroDeltaCount, the triggering hook's and corrector's deltas, and CURRENCY_SLOT. The executor runs with full PoolManager access inside the user's unlock. PoolManager.swap applies the swapper's delta after afterSwap (PoolManager.sol:221-226). The executor can move the price of another pool in the user's multi-hop route before the user's next hop (a sandwich inside the victim's own tx). It can also keep the count unchanged with take() on itself plus settleFor() of the router's earlier debt, so the user's tx reverts CurrencyNotSettled.
description: The executor can sandwich or revert later hops of the user's route, because the digest checks only the hook and the corrector. We did not run a PoC, and the executor is a trusted partner.

Functions opened: 48
