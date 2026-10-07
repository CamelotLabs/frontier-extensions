# Run 1 — solidity-auditor

<!--RUN pass=1 of=1 stamp=20261007-140638 sha=da5dce3 agents=12/12-->

Pass 1 of 1 · 2026-10-07 · `da5dce3` · 12/12 agents returned.

## Findings

<!--F key=wthcorrector|-deltadigest|incomplete-delta-snapshot conf=90 kind=FINDING agents=4-->

[90] **Delta digest misses executor deltas and synced reserves, so a hostile executor reverts multi-step swaps**

`WthCorrector._deltaDigest` · Confidence: 90

**Description**
The executor nets the delta count with `take` plus `settleFor(router)`, or re-syncs the synced coin, so the digest stays equal and the user's swap reverts.

**Severity** Medium · Impact High · Likelihood Unlikely

**Fix (Option A — validate executor deltas)**:

```diff
-        bytes32[] memory slots = new bytes32[](6);
+        bytes32[] memory slots = new bytes32[](8);
         slots[0] = NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT;
         ...
         slots[5] = CurrencyReserves.CURRENCY_SLOT;
+        slots[6] = _deltaSlot(executor, address(0));
+        slots[7] = _deltaSlot(executor, coin);
```

**Fix (Option B — validate synced reserves)**:

```diff
-        bytes32[] memory slots = new bytes32[](6);
+        bytes32[] memory slots = new bytes32[](7);
         ...
         slots[5] = CurrencyReserves.CURRENCY_SLOT;
+        slots[6] = CurrencyReserves.RESERVES_OF_SLOT;
```

**Fix (Option C — ban the presync path)**:

```diff
     function onAfterSwap(PoolId poolId, BalanceDelta delta, uint24, uint256, bytes calldata) external {
         _checkPoolHook(poolId);
         address target = executor;
         if (target == address(0) || _tload(LOCK_TSLOT) != 0 || gasleft() < MIN_CORRECTION_GAS) return;
+        if (POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0) return;
```

**Fix (Option D — restrict to a debt-free unlock)**:

```diff
+        // skip when any party other than the hook and the corrector holds an open delta
+        if (uint256(POOL_MANAGER.exttload(NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT)) > _knownNonzero(msg.sender, coin)) return;
```

<!--/F-->

<!--F key=wthcorrector|-correct|delta-snapshot-bypass conf=90 kind=FINDING agents=1-->

[90] **Executor pays the router debt with settleFor and borrows it back, so the digest check in _correct passes**

`WthCorrector._correct` · Confidence: 90

**Description**
On a route with an open router debt, the executor calls `settleFor(router)` and `take` for the same amount, so `_correct` accepts the correction and the user's unlock reverts.

**Severity** Medium · Impact High · Likelihood Unlikely

**Fix**

```diff
-        if (_deltaDigest(msg.sender, binding.coin) != digest) revert DeltaSnapshotChanged();
+        if (_deltaDigest(msg.sender, binding.coin) != digest) revert DeltaSnapshotChanged();
+        // also snapshot the swapper's ETH and coin deltas (sender forwarded by the hook) and fail on any change
```

<!--/F-->

<!--F key=wthcorrector|onafterswap|correction-legs-inflate-hook-volatility conf=85 kind=FINDING agents=1-->

[85] **Executor legs count as a new price move in the hook, so later swappers pay a higher volatility fee**

`WthCorrector.onAfterSwap` · Confidence: 85

**Description**
Each in-band executor leg runs the hook's `_updateVolatility`, so a correction that restores the price doubles the volatility reading and later users pay a higher fee tier.

**Severity** Medium · Impact Medium · Likelihood Likely

**Fix**

```diff
-    // pool binds WthCorrector and a volatility-priced calculator together
+    // refuse to bind next to a volatility-priced calculator, or have the hook skip
+    // volatility accrual for swaps that run inside an open correction window
```

<!--/F-->

<!--F key=wthcorrector|quotefee|window-fee-any-swapper conf=80 kind=FINDING agents=4-->

[80] **quoteFee gives the floor fee to any in-band swapper, so a creator-bound observer trades inside the window at 3 bps**

`WthCorrector.quoteFee` · Confidence: 80

**Description**
`quoteFee` never checks who swaps, so an observer the creator binds swaps opposite and in band during an executor leg, and the pool's LPs earn no fee on it.

**Severity** Medium · Impact Medium · Likelihood Possible

**Fix**

```diff
     function onAfterSwap(PoolId poolId, BalanceDelta delta, uint24, uint256, bytes calldata) external {
         _checkPoolHook(poolId);
         address target = executor;
-        if (target == address(0) || _tload(LOCK_TSLOT) != 0 || gasleft() < MIN_CORRECTION_GAS) return;
+        // nested notification of an executor leg: close the window so no other observer gets the floor
+        if (_tload(LOCK_TSLOT) != 0) { _tstore(WINDOW_TSLOT, 0); return; }
+        if (target == address(0) || gasleft() < MIN_CORRECTION_GAS) return;
```

<!--/F-->

<!--F key=wthcorrector|-payout|jit-donation-capture conf=75 kind=FINDING agents=2-->

[75] **The LP share is donated to liquidity in range at payout, so a same-transaction position takes most of it**

`WthCorrector._payout` · Confidence: 75

**Description**
`_payout` donates the LP share to the liquidity in range at the executor's final price, so a narrow position added in the triggering unlock takes most of it.

**Severity** Medium · Impact Medium · Likelihood Possible

<!--/F-->

<!--F key=wthcorrector|-openwindow|stale-reference-tick conf=75 kind=FINDING agents=4-->

[75] **The band edge reads a referenceTick that nested swaps overwrite, so the band can reach past the user's pre-swap price**

`WthCorrector._openWindow` · Confidence: 75

**Description**
An observer listed before the corrector that swaps the same pool rewrites `referenceTick` and slot0, so `_openWindow` builds the band from that swap and not the user's.

**Severity** Low · Impact Medium · Likelihood Unlikely

<!--/F-->

## Leads

<!--F key=wthcorrector|quotefee|band-start-price-unchecked kind=LEAD agents=2-->

- **quoteFee checks the leg limit but not the leg start** — `WthCorrector.quoteFee` — Code smells: only `sqrtPriceLimitX96` is checked against the band; the tick argument is ignored — A paid same-direction leg can push the price below `post`, then a floor-fee opposite leg crosses that range; no profit sequence was found.

<!--/F-->

<!--F key=wthcorrector|quotefee|lp-fee-diversion kind=LEAD agents=1-->

- **The floor-fee legs move LP fee income to the fee recipient** — `WthCorrector.quoteFee` — Code smells: in-band legs pay only the protocol floor; LPs get `lpShareBps * 8000 / 1e8` of profit; stakers get nothing — At `lpShareBps` 2500 the LPs can earn less than a normal-fee arbitrage would pay them; the counterfactual volume was not modelled.

<!--/F-->

<!--F key=wthcorrector|-openwindow|asymmetric-band-edge kind=LEAD agents=2-->

- **The band edge is one tick wider for zeroForOne swaps than for oneForZero swaps** — `WthCorrector._openWindow` — Code smells: `edgeTick = zeroForOne ? ref - 1 : ref + 1` with a floor tick below the pre-swap price — A sell that crosses one tick boundary gets a zero band, which disagrees with the `currentBand` NatSpec; no fund loss was found.

<!--/F-->

<!--F key=wthcorrector|-poolstateprefix|hook-layout-assumption kind=LEAD agents=1-->

- **The corrector reads word 3 of the v1.1 PoolState layout without a check** — `WthCorrector._poolStatePrefix` — Code smells: `_bind` checks words 0 and 1; `_referenceTick` uses word 3 unchecked; one deployment serves every hook generation — A later hook with another field order makes the band use a different field; no later layout exists yet.

<!--/F-->

<!--F key=wthcorrector|-correct|executor-unlock-scope kind=LEAD agents=1-->

- **The executor runs inside the user's unlock and can move other pools of the route** — `WthCorrector._correct` — Code smells: the digest checks only the hook and the corrector; the swapper delta is applied after afterSwap — The executor can move a later hop's pool before the user reaches it; no PoC, and the executor is a trusted partner.

<!--/F-->

<!--F key=wthcorrector|-callexecutor|correction-legs-feed-other-observers kind=LEAD agents=1-->

- **Executor legs notify every other observer on the pool** — `WthCorrector._callExecutor` — Code smells: `LotteryRecipient` mints tickets to `tx.origin` per leg; `MilestonesObserver` counts leg volume — The user who triggers a correction gets lottery tickets for the executor legs; whether the payout covers it was not measured.

<!--/F-->
