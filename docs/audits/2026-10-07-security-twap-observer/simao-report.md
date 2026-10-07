# Security Review: Frontier Extensions (`feat/twap-observer`)

**Scope:** 5 files, 2 contracts (`TwapObserver`, `WthCorrector`) and 3 interfaces, `CamelotLabs/frontier-extensions` at `da5dce3`
**Method:** accounting-first review across 12 attack lenses (0xSimao pipeline v1.0.0, EVM Cortex adaptation)
**Findings:** 0 High · 4 Medium · 2 Low · 0 Info, plus 6 unverified leads

## Accounting model

`TwapObserver` holds no value. It stores the hook's tick cumulative once per `interval` in a ring per pool, and `consult` returns a time-weighted average tick. `WthCorrector` holds value for one swap only. After a user swap, the partner executor trades the price back inside the same unlock. The executor's in-band legs pay only the protocol floor, and the executor pays the corrector in WETH or native ETH. The corrector donates `lpShareBps` of that payment to the in-range LPs and sends the rest to the coin's fee recipient. The LPs carry the zero-fee legs. The donation is their compensation, so every finding below asks who receives that donation and who controls the answer.

## Systemic observations

- **The triggering transaction decides who receives the LP share.** Three separate paths let the swapper's own unlock change the recipient of the LP share: a pending `sync` (M-1), a same-transaction position (M-2), and the end price of the executor (L-2). All three come from the donation being paid at once, inside the triggering unlock.
- **The delta digest does not contain a hostile executor.** The README treats the executor as hostile, and the digest is the only containment. The digest misses the synced reserves (M-3) and the deltas of third parties (L-1).
- **No lens found a defect in `TwapObserver`.** Every lens worked the ring lifecycles of the money map (bind, record, growth, read, quiet stretch). See the separate TwapObserver-only Pashov scan in [`pashov/twap-observer/`](pashov/twap-observer/).

Completeness: 6 unique (Contract, function) in raw: 6 reported, 0 rejected, 0 merged across functions. Three TwapObserver candidates from the separate Pashov scan were rejected there. The main report gives the reasons.

Lens compliance: all 12 lenses returned. The prompts asked for the final blocks only, so the reasoning markers (`[Model:]`, `[Why:]`, `[Defeat:]`, `[LastOut:]`) were not printed. Each lens reported `lifecycles closed: 8`, which is every lifecycle of the money map.

---

## M-1. A pending `sync` in the swapper's unlock sends the whole LP share of a correction to the fee recipient

**Description:**

`WthCorrector::_payout()` sets `lpAmount` to 0 when `POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0` ([`WthCorrector.sol:347-351`](https://github.com/CamelotLabs/frontier-extensions/blob/da5dce3/contracts/wth-corrector/WthCorrector.sol#L347-L351)). The swapper sets that slot with one free `sync` call in its own unlock. A coin's fee recipient, usually the creator, routes its swaps through such a router and receives 100% of every correction it triggers in place of `10000 - lpShareBps`. With an external price gap, a dust trigger swap collects the full rebate. The LPs still carry the zero-fee executor legs, so they lose all of their compensation for those corrections. This breaks the README statement "LPs never under 25 %". Seven of twelve lenses reached this path.

PoC (passes): [`poc/simao-12/SyncDivert.t.sol`](poc/simao-12/SyncDivert.t.sol), `test_presync_divertsLpShareToRecipient`. With an honest router the event is `CorrectionSettled(pid, 1e15, 3e14, 7e14)`. With the presync router it is `CorrectionSettled(pid, 1e15, 0, 1e15)`.

**Recommended Mitigation (Option A, skip):**

Return from `onAfterSwap` before the executor call when a currency is synced, and remove the synced-currency term from the payout fallback.

```diff
     function onAfterSwap(PoolId poolId, BalanceDelta delta, uint24, uint256, bytes calldata) external {
         _checkPoolHook(poolId);
         address target = executor;
         if (target == address(0) || _tload(LOCK_TSLOT) != 0 || gasleft() < MIN_CORRECTION_GAS) return;
+        if (POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0) return;
```

**Recommended Mitigation (Option B, defer):**

Keep the LP share in a per-pool pending amount when a currency is synced, and donate it at the next correction that runs without a pending sync.

**Fix review:**

## M-2. A position added in the triggering unlock collects most of the donated LP share

**Description:**

`WthCorrector::_payout()` calls `POOL_MANAGER.donate` inside the unlock of the triggering swap ([`WthCorrector.sol:359-360`](https://github.com/CamelotLabs/frontier-extensions/blob/da5dce3/contracts/wth-corrector/WthCorrector.sol#L359-L360)). V4 `donate` pays the liquidity that is in range at that instant. FactoryHook v1.1 does not gate `addLiquidity` or `removeLiquidity`. A swapper adds a one-tick-spacing position at the predicted end tick, swaps, and removes the position in the same unlock. The standing LPs, by default the liquidity manager's graduation position, lose most of the LP share while they still carry the zero-fee legs. The executor can do the same inside `executeArbitrage` (`test_lpShare_followsInRangeLiquidity` in the repo already shows more than 95% capture). Eight lenses reached this shape.

PoC (passes): [`poc/simao-10/SwapperJitPoC.t.sol`](poc/simao-10/SwapperJitPoC.t.sol), `test_swapperJit_capturesDonation`. A position with 20 times the active liquidity collects 2857316425898231 wei of a 3000000000000000 wei donation (95.2%), against a no-correction baseline.

**Recommended Mitigation:**

Do not donate inside the triggering transaction. Accrue the LP share in the corrector and pay it in a later transaction, either to the standing position's fee receiver or through a donation that a same-transaction position cannot enter.

**Fix review:**

## M-3. `_deltaDigest` does not record the synced reserves, so a hostile executor takes a presync router's prepaid input

**Description:**

`WthCorrector::_deltaDigest()` records `CurrencyReserves.CURRENCY_SLOT` but not `CurrencyReserves.RESERVES_OF_SLOT` ([`WthCorrector.sol:322-331`](https://github.com/CamelotLabs/frontier-extensions/blob/da5dce3/contracts/wth-corrector/WthCorrector.sol#L322-L331)). Suppose the router synced the coin and prepaid its input before the Frontier hop. The executor calls `settle()`, `take(coin, executor, coinIn)` and `sync(coin)`. The synced currency is the coin again, the count is unchanged, and the check at line 246 passes. A router that settles a fixed amount then reverts with `CurrencyNotSettled`. A router that settles its open debt pays its input a second time, and the executor keeps the first payment. The executor is one global address. The README and `HostileExecutorMock` treat it as hostile, and the digest is the only thing that contains it.

Likelihood is low: it needs a hostile or compromised executor and a presync router. Severity is Medium, not High, for that reason.

PoC (passes): [`poc/simao-5/ReservesPoC.t.sol`](poc/simao-5/ReservesPoC.t.sol). `test_poc_presyncRouter_userSwapReverts` shows the revert. `test_poc_topUpRouter_userLosesCoinIn` shows the router end at 974,612e18 coin against 1,974,612e18 with the corrector paused, and the executor holding 1,000,000e18 coin.

**Recommended Mitigation:**

```diff
-        bytes32[] memory slots = new bytes32[](6);
+        bytes32[] memory slots = new bytes32[](7);
         ...
         slots[5] = CurrencyReserves.CURRENCY_SLOT;
+        slots[6] = CurrencyReserves.RESERVES_OF_SLOT;
```

Option A of M-1 (skip the correction when a currency is synced) also closes this path.

**Fix review:**

## M-4. The floor-fee window of `quoteFee` is not bound to the executor

**Description:**

`WthCorrector::quoteFee()` returns 0 for any exact-input swap opposite to the user, with a limit inside the band, while `WINDOW_TSLOT` holds the pool id ([`WthCorrector.sol:164-170`](https://github.com/CamelotLabs/frontier-extensions/blob/da5dce3/contracts/wth-corrector/WthCorrector.sol#L164-L170)). `IFeeCalculator.quoteFee` receives no sender. During the executor call, the hook notifies every other observer of the pool for each nested executor leg, with a fresh 600k budget, and only the corrector returns at its lock. An observer that the creator binds, or a hook on a venue of the executor's route, swaps in the band at the floor and settles its own deltas. The LPs earn no fee on that volume, and the executor's payment does not cover it. Four lenses reached this independently; it was promoted from lead under the two-lens rule.

PoC (from the Pashov scan, passes): [`poc/pashov-11/WindowObserver.t.sol`](poc/pashov-11/WindowObserver.t.sol). A creator-bound observer sells 1.0504e25 coin for 0.2989 ETH inside the executor's leg, and `feeGrowthGlobal1` stays 0.

**Recommended Mitigation:**

Close the window in the corrector's nested `onAfterSwap` and let only the executor reopen it per leg, or require the corrector to be the first observer so that it can close the window before any other observer runs.

**Fix review:**

## L-1. A hostile executor pays a router debt with `settleFor` and borrows it back, which reverts multi-hop swaps

**Description:**

`WthCorrector::_correct()` checks the digest at [`WthCorrector.sol:246`](https://github.com/CamelotLabs/frontier-extensions/blob/da5dce3/contracts/wth-corrector/WthCorrector.sol#L246). The digest does not hold the deltas of the swapper's router or of the executor. On a route where the Frontier hop is not the first action of the unlock, the router has an open debt. The executor calls `take` (count plus 1) and `settleFor(router)` (count minus 1), so the count is unchanged. The correction settles, then the unlock ends with the executor's debt open and the user's whole transaction reverts. The executor needs no capital and pays nothing, because everything reverts. No funds are lost. The block lasts until the factory owner calls `setExecutor(address(0))`.

PoC (passes): [`poc/simao-9/DigestShuffle.t.sol`](poc/simao-9/DigestShuffle.t.sol). `test_hostileExecutor_passesDigest_revertsTwoHopSwap` reverts with `CurrencyNotSettled`, and its trace shows `CorrectionSettled` first. The controls `test_control_honestExecutor_twoHopCompletes` and `test_singleHop_hostileExecutorFindsNoDebt` pass.

**Recommended Mitigation:**

Have the hook forward the swap `sender` to observers and add the sender's ETH and coin delta slots to `_deltaDigest`. Otherwise, state in the README that "the user's swap always completes" holds only for an unlock with no other open debt, and name `setExecutor(address(0))` as the response.

**Fix review:**

## L-2. The LP share reaches only the liquidity at the end price, not the liquidity the zero-fee legs used

**Description:**

`WthCorrector::_payout()` donates at the price where the executor's last leg stops ([`WthCorrector.sol:359-360`](https://github.com/CamelotLabs/frontier-extensions/blob/da5dce3/contracts/wth-corrector/WthCorrector.sol#L359-L360)). An LP whose range lies inside the band but not at that price gives up the fee on the legs that crossed its range and receives none of the donation. When the end price has no in-range liquidity, the whole LP share goes to the fee recipient (line 349), and the executor picks the end price. The README states the "in-range" donation, so this is documented behavior. It does not match the purpose of the donation, which is to compensate the LPs for the waived fee. Example from the lens: Bob holds half of the liquidity on 84% of the leg's path and receives 0 of a 0.5 ETH donation.

**Recommended Mitigation:**

Decide whether the LP share is a bonus to the liquidity at the end price or a compensation to the band. If it is a compensation, stop the fee waiver in band and send the whole executor payment to the fee recipient, so that each LP earns the normal fee on the liquidity the legs use.

**Fix review:**

---

## Unverified leads

- `WthCorrector::quoteFee` (two lenses): the executor's payment is checked only against `MIN_PAYMENT_WEI`, not against the LP fee its legs waived. The executor is an owner-set partner, so no untrusted path was found.
- `WthCorrector::onAfterSwap` (two lenses): a swapper who caps the gas so that the observer gets between about 300k and 520k skips the correction and keeps the back-run for itself. A sweep on the real hook confirmed the window (`MIN_CORRECTION_GAS` 250000, 0.3 ETH buy). The loss is income that LPs and the recipient would have had, not funds they held. The fix belongs in the hook (a gas floor before the observer loop).
- `WthCorrector::onAfterSwap`: each executor leg runs the hook's `_updateVolatility`, so a correction that restores the price doubles the volatility reading. The Pashov scan proved the fee impact with a PoC ([`poc/pashov-12/VolatilitySeam.t.sol`](poc/pashov-12/VolatilitySeam.t.sol)).
- `WthCorrector::_openWindow`: the band edge is 1 to 2 ticks inside the pre-swap price for a sell and 0 to 1 tick for a buy. Only the fee on less than one tick is at stake.
- `WthCorrector::_correct`: the payment model assumes a push payment in WETH or ETH during the call. If the partner executor pays in another form, every correction reverts with `PaymentTooLow`. No deployed executor confirms the model.
- `WthCorrector::_payout`: the zero-liquidity fallback is checked at an end price that the executor chooses. Whether real Frontier pools have such gaps near the corrected price was not checked. Folded into L-2.
