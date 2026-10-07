# Money map: frontier-extensions @ da5dce3 (`feat/twap-observer`)

Two singletons bound per pool by the Frontier hook (FactoryHook v1.1). Pools are native ETH (currency0)
/ coin (currency1), dynamic fee. Neither contract holds value between transactions. TwapObserver holds no
value at all: its "accounting" is a history ring whose truth source is the hook's tick cumulative.
WthCorrector moves real value (ETH and WETH) inside one swap. The `lib/` hook source is out of scope but
defines the inputs: `FactoryHook.sol` `observe` (L377), `_settleSwapTail` (L597), `_notify` (L636),
`_updateVolatility` (L726), `_checkpointSwap` (L742).

## 1. Assets

| Asset | In | Out | Contract |
|---|---|---|---|
| Native ETH | executor sends during a correction (`receive`, only while `LOCK_TSLOT` set); forced ETH (selfdestruct) at any time | `POOL_MANAGER.settle{value: lpAmount}` then `donate` to in-range LPs; leftover wrapped `IWETH.deposit` | WthCorrector |
| WETH | executor transfers during a correction; anyone can transfer at any time | `IWETH.withdraw` for the LP share; `IWETH.transfer(recipient)`; `recoverERC20` by factory owner | WthCorrector |
| Any ERC-20 | stray transfers | `recoverERC20` (factory owner, blocked while a correction runs) | WthCorrector |
| Storage paid by callers | `increaseCardinality` caller pays placeholder writes | none | TwapObserver |

## 2. Tracked totals and state

TwapObserver, `_pools[poolId]` (one packed slot) and `_rings[poolId][0..254]`:

| Variable | Writers | Direction |
|---|---|---|
| `hook`, `interval` | `onRegisterObserver` only (once; `PoolAlreadyBound`) | set once |
| `cardinality` | `onRegisterObserver` (init); `_record` (`= cardinalityNext` only when `newest == cardinality - 1` and growth pending) | up only |
| `cardinalityNext` | `onRegisterObserver` (init); `increaseCardinality` (anyone, `> previous`, `<= 255`) | up only |
| `newest` | `_record` (`(newest + 1) % cardinality`, or 0 when `count == 0`) | ring cursor |
| `count` | `_record` (`++` while `< cardinality`) | up only |
| `lastTimestamp` | `_record` (`= uint32(block.timestamp)`) | up only (gated by `_due`) |
| `ring[slot]` | `_record` (real reading); `increaseCardinality` (placeholder `{1, 0}` for slots `[previous, cardinalityNext)`) | overwrite |

WthCorrector:

| Variable | Writers | Direction |
|---|---|---|
| `executor` | `setExecutor` (factory owner, no delay) | any |
| `_bindings[poolId]` (`coin`, `tickSpacing`, `lpShareBps`, `roles`) | `_bind` via `onRegisterCalculator` / `onRegisterObserver` (hook-gated, write-once per role, `lpShareBps` must match across roles) | set once per role |
| `hookOf[poolId]` (HookGated) | `_registerPool` (current hook only) | set |
| transient `LOCK`, `WINDOW`, `LOWER`, `UPPER`, `DIRECTION` | `onAfterSwap`, `_openWindow`, `_correct` | per correction |
| received (local) | `_correct`: `WETH.balanceOf(this)` delta + `address(this).balance` delta around the executor call | per correction |

## 3. Asymmetry table

| Item | Observation |
|---|---|
| Live balance reads | `_correct` reads `WETH.balanceOf(this)` and `address(this).balance` before and after the executor call. Any WETH or ETH that reaches the corrector during the call counts as payment, whoever sent it. Pre-existing stray WETH is excluded by the delta, but stays in the contract until `recoverERC20`. |
| Native vs WETH split | `nativeReceived` and the WETH delta are summed into `received`; `_payout` unwraps WETH if native is short of `lpAmount`, wraps native surplus. The recipient is paid `received - lpAmount` in WETH from the contract's whole WETH balance, not only this correction's. |
| LP share fallback | `lpAmount` drops to 0 when `getLiquidity(poolId) == 0` or a currency is synced on the PoolManager; the whole payment then goes to the recipient. |
| PoolManager deltas | `settle{value}` credits the corrector `+lpAmount`; `donate(amount0 = lpAmount)` debits `-lpAmount`. Net zero, after the digest check. |
| Hook cumulative vs ring | TwapObserver stores `observe().tickCumulative` at `block.timestamp`. `observe` extrapolates `truncatedTick * (now - lastSwapTimestamp)` with the tick the last swap left; the stored value is final for timestamps before `now` only if no later swap in the same second changes `truncatedTick` before time passes. |
| Placeholder slots | `increaseCardinality` writes `{timestamp: 1, tickCumulative: 0}` into slots that `_slot`/`_search` must never reach while `count` excludes them. |
| Record gating | `onAfterSwap` records without the graduation check; `record` checks `isLPd()` but only after `_due` returns true. |

## 4. Invariants

TwapObserver (NatSpec, TwapObserver.sol L27-32, plus derived):
- T1. `count <= cardinality <= cardinalityNext <= 255`; none decreases.
- T2. Only the `count` positions from the oldest are read; each holds a real recording, never a placeholder.
- T3. Stored timestamps increase strictly from oldest to newest, at least `interval` apart; `lastTimestamp` is the newest.
- T4. `consult(poolId, s)` returns `span >= s` or reverts; `averageTick == floor((cumNow - cumPast) / span)`.
- T5. A growth never loses or reorders a kept observation.
- T6. Every stored `tickCumulative` equals the hook's true cumulative at its timestamp (a later read cannot disagree with it).
- T7. Gas: the no-op `onAfterSwap` path and `consult` stay inside the budgets readers assume (README: budget `consult` at 255 slots).

WthCorrector:
- W1. `received == lpAmount + recipientAmount` for every `CorrectionSettled`.
- W2. The corrector's ETH and WETH balances after a correction equal those before it (it holds nothing between transactions).
- W3. PoolManager nonzero-delta count, the hook's and the corrector's deltas, and the synced currency are unchanged by the executor call.
- W4. The user's swap always completes; a failing correction reverts only the observer call.
- W5. `quoteFee` returns 0 only inside the open window of the same pool, for exact-input legs opposite to the user, with a limit strictly inside the band.
- W6. `lpShareBps` in [2500, 10000], identical across both roles of one pool.
- W7. Only the pool's registering hook reaches `onAfterSwap`, `onFeeChange`, `quoteFee`-sensitive state.

## 5. Lifecycles

- L1 TWAP bind: hook `onRegisterObserver` → `_pools` set (`count 0`).
- L2 TWAP record: swap → hook `_settleSwapTail` → `onAfterSwap` → `_due` → `_record` (reads `observe`) ; or anyone `record` → `isLPd` → `_record`.
- L3 TWAP growth: anyone `increaseCardinality` (placeholders) → ring laps to last slot → `_record` applies `cardinality = cardinalityNext` → continues into new slots.
- L4 TWAP read: consumer `consult(s)` → `_search` binary search → `observe` now → average.
- L5 TWAP quiet stretch: no swaps for > `interval` → first swap after → `_record` → reads reach back to the pre-quiet observation.
- C1 Correction: user swap → hook calls calculators (`quoteFee`, window closed → previous fee) → swap → observers → `onAfterSwap` → lock, `_openWindow` (band, direction) → `_correct` → executor runs legs through the pool (nested hook calls: `quoteFee` returns 0 for in-band opposite legs, nested `onAfterSwap` returns at lock) → executor pays WETH/ETH → digest check → `_payout` (donate LP share, WETH to recipient) → unlock.
- C2 Failure: executor reverts, digest changes, payment < `MIN_PAYMENT_WEI`, recipient WETH transfer fails → whole observer call reverts, hook swallows.
- C3 Admin: `setExecutor`, `recoverERC20`.

## 6. Cohorts

- Swapper (user who triggers a correction; pays the normal fee).
- Executor (partner contract, set by the factory owner; must pay ≥ `MIN_PAYMENT_WEI`; keeps 2000 bps of its profit).
- In-range LPs at the moment of `donate` (receive `lpShareBps` of the payment).
- Coin fee recipient (`IBCToken.getFeeRecipient()`; receives the rest in WETH).
- Other observers of the same pool (share the 600k observer budget; ordered after or before these extensions).
- TWAP consumers (any contract reading `consult`: fee calculators under 50k stipend, observers, lending or pricing integrations).
- Recorder / cardinality grower (anyone; pays gas).
- Factory owner (sets executor, recovers tokens; also the hook owner side).
- MEV searchers on Robinhood Chain (several blocks share a timestamp; the hook clamps the truncated tick to 9116 per second).

Sections with little content: there is no share token, no debt, no pro-rata pool owned by these contracts. The accounting-desync class applies to the correction payment split (W1, W2) and to the TWAP ring as a tracked history (T1 to T6).
