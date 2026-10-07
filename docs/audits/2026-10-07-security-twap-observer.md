# Security Audit Report: Frontier Extensions, `feat/twap-observer`

## 1. Executive Summary

- **Protocol**: Frontier Extensions, the official extensions of the Frontier hook (`FactoryHook` v1.1 on Robinhood Chain 4663). `TwapObserver` stores a TWAP history per pool. `WthCorrector` has a partner executor back-run the user's swap and splits the executor's payment between the LPs and the coin's fee recipient.
- **Scope**: every contract under `contracts/` of [`CamelotLabs/frontier-extensions`](https://github.com/CamelotLabs/frontier-extensions/tree/feat/twap-observer/contracts), branch `feat/twap-observer`, commit `da5dce3`. That is `TwapObserver.sol` (144 nSLOC, new on this branch), `WthCorrector.sol` (273 nSLOC, on `main` since an earlier fix round) and three interfaces.
- **Timeline**: 2026-10-07.
- **Auditors**: AI review (Claude Opus 5.5), EVM Cortex pipelines, for the operator.
- **Methodology**: `xray-pre-audit` readiness report, the Pashov pipeline (v4, 12 agents) twice (full scope, then `TwapObserver` only), and the 0xSimao accounting-first pipeline (v1.0.0, 12 lenses). Each pipeline ran one pass on Opus. Every PoC an agent wrote was re-run in one isolated copy of the repo. Static analysis: Slither, Aderyn. Coverage: `forge coverage`.
- **Findings Summary** (consolidated across the pipelines):

  | Severity | Count |
  |----------|-------|
  | Critical | 0 |
  | High | 0 |
  | Medium | 5 |
  | Low | 2 |
  | Info | 4 |

- **Readiness verdict**: `TwapObserver` is ready for an external Core audit. `WthCorrector` is not ready. Decide and fix F-01 to F-05 first, because each one changes a guarantee that the README states.

All five Medium findings and both Low findings are in `WthCorrector`. Thirty-six lenses read `TwapObserver` (12 in the full-scope Pashov scan, 12 in the TwapObserver-only Pashov scan, 12 Simao lenses), and none raised a finding on it.

### Outputs

| Output | Where |
|---|---|
| X-ray readiness report, entry points, invariant map, diagram | [`x-ray/`](2026-10-07-security-twap-observer/x-ray/x-ray.md) |
| Pashov report, full scope, with severity annex | [`pashov/full-scope/`](2026-10-07-security-twap-observer/pashov/full-scope/full-report.md), [annex](2026-10-07-security-twap-observer/pashov/full-scope/severity-annex.md) |
| Pashov report, `TwapObserver` only | [`pashov/twap-observer/`](2026-10-07-security-twap-observer/pashov/twap-observer/full-report.md) |
| Simao report and money map | [`simao-report.md`](2026-10-07-security-twap-observer/simao-report.md), [`simao-money-map.md`](2026-10-07-security-twap-observer/simao-money-map.md) |
| Raw output of all 36 agents | [`raw/`](2026-10-07-security-twap-observer/raw/) |
| PoC tests (Foundry) | [`poc/`](2026-10-07-security-twap-observer/poc/) |
| Pre-flight tool output | [`pre-flight/`](2026-10-07-security-twap-observer/pre-flight/) |

## 2. Scope

### Files in Scope

| File | nSLOC | Description |
|------|------:|-------------|
| `contracts/twap-observer/TwapObserver.sol` | 144 | After-swap observer: per-pool ring of `(timestamp, tickCumulative)`, open `record` and `increaseCardinality`, `consult` |
| `contracts/wth-corrector/WthCorrector.sol` | 273 | Last fee calculator and after-swap observer: band window, executor call, delta digest, LP donation, WETH payout |
| `ITwapObserver.sol`, `IWthCorrector.sol`, `IWthArbitrageExecutor.sol` | 98 | Interfaces with the full NatSpec |

### Out of Scope

- The hook (`lib/extension-kit/lib/factory-hook/v1.1`) and the extension kit (`HookGated`). The agents read them for context.
- The partner executor. Its source is not in the repository.
- Tests and the fork suite.

## 3. Audit readiness

The x-ray verdict is **ADEQUATE**, and its recommended audit mode is **Core**. The full verdict is in [`x-ray/x-ray.md`](2026-10-07-security-twap-observer/x-ray/x-ray.md#x-ray-verdict).

| Criterion | Status | Notes |
|---|---|---|
| Build succeeds | Yes | `forge build --force`, solc 0.8.26, no warnings |
| Tests pass | Partial | 128 of 130 pass on forge 1.7.1. Two gas ceilings fail: `test_gas_onAfterSwapRecordingPath` (32377 >= 32000) and `test_gas_onAfterSwapRecordingIntoAPrewrittenSlot` (15348 >= 12000). CI pins Foundry v1.5.1, and this review did not run that version |
| Coverage | Yes | 100% lines (242/242), 98.39% branches (61/62), 100% on `TwapObserver` |
| Stateful fuzz | Partial | 4 Foundry invariants on `TwapObserver` (48 runs, depth 40). None on `WthCorrector`. No Echidna, Medusa or formal verification |
| NatSpec | Yes | Full on the interfaces, `@inheritdoc` on the implementations. One mismatch (I-01) |
| Invariants documented | Partial | Four `INVARIANT:` lines in `TwapObserver`. None for `WthCorrector`. The x-ray adds 27 single-contract, 6 cross-contract and 3 economic invariants, 13 of them `Onchain: No` |
| Known issues listed | No | No known-issues file. The README "Limits" covers `TwapObserver` only |
| Static analysis | Yes | Slither: 0 High, 6 Medium and 3 Low, all triaged by design. Aderyn 0.1.9: 2 High (the cast at `WthCorrector.sol:296`, which reads an int24 that the hook encoded, and "locks Ether", see I-04). `forge fmt --check` is clean |
| Git hygiene | Partial | 1 contributor, 10 commits in 3 days, 0 merge commits. The branch is 4 commits ahead of `main` and has no pull request |

**Before an external audit:**

1. Decide F-01 to F-05, then fix them, or state the accepted risk in the README.
2. Run the gas tests on Foundry v1.5.1 and fix or re-baseline the two ceilings.
3. Add a known-issues section that names the executor trust, the donation semantics and the listing-order rules.
4. Add invariant tests for `WthCorrector` (I-23 to I-25 in the x-ray map), and run a longer `TwapObserver` campaign or Halmos on `_record` and `_search` after repeated growth.
5. Open a pull request for `feat/twap-observer`, so the audit commit has a review record.

## 4. System Overview

See the [architecture diagram](2026-10-07-security-twap-observer/x-ray/architecture.svg) and the [entry point map](2026-10-07-security-twap-observer/x-ray/entry-points.md). The trust model in short:

- Each pool answers only to the hook that registered it (`HookGated`).
- `BCTokenFactory.owner()` sets or pauses the executor and recovers ERC-20 from `WthCorrector`, with no delay.
- `TwapObserver` has no admin. Anyone can call `record` and `increaseCardinality`.
- The README treats the partner executor as hostile. The delta digest is the only thing that contains it, and the README states that "the user's swap always completes".

## 5. Findings

The two pipelines ran independently. A finding that both pipelines raised is listed once, with each source.

## [MEDIUM] F-01: The delta digest misses third-party deltas and the synced reserves

**Severity**: Medium (Impact High, Likelihood Unlikely)
**Type**: Access Control
**Location**: `contracts/wth-corrector/WthCorrector.sol:L235-L250`, `L320-L331`
**Status**: Open
**Sources**: Pashov full scope #1 and #2 (5 agents), Simao M-3 and L-1

### Description
`_deltaDigest` hashes the nonzero-delta count, the deltas of the hook and the corrector, and the synced currency. It does not hash the deltas of the router or the executor, or the synced reserves. A hostile executor keeps the digest equal in two ways:
- On a route where the Frontier hop is not the first action of the unlock, it calls `take` (count plus 1) and `settleFor(router)` (count minus 1).
- On a presync route, it calls `settle`, `take` and `sync`, or only `sync`, so the synced currency matches again with other reserves.

### Impact
The user's whole transaction reverts with `CurrencyNotSettled` on every multi-hop or presync route into a bound pool, at no cost to the executor, until the owner pauses it. With a router that settles its open debt, the executor keeps the router's prepaid input: in the PoC, 1,000,000e18 coin for a payment of 1e12 wei. This breaks the README guarantee "the user's swap always completes".

### Root Cause
The digest proves that the count is unchanged, not that every delta is unchanged. The PoolManager cannot list all deltas, so a count-plus-known-slots digest cannot detect a pair of changes on two unknown addresses.

### Proof of Concept
All pass: [`poc/pashov-7/DigestBypass.t.sol`](2026-10-07-security-twap-observer/poc/pashov-7/DigestBypass.t.sol), [`poc/simao-9/DigestShuffle.t.sol`](2026-10-07-security-twap-observer/poc/simao-9/DigestShuffle.t.sol), [`poc/pashov-4/ResyncPoC.t.sol`](2026-10-07-security-twap-observer/poc/pashov-4/ResyncPoC.t.sol), [`poc/simao-5/ReservesPoC.t.sol`](2026-10-07-security-twap-observer/poc/simao-5/ReservesPoC.t.sol) (`test_poc_topUpRouter_userLosesCoinIn`), and the variants of agents 5, 6 and 8.

### Recommendation
1. Return from `onAfterSwap` when `exttload(CURRENCY_SLOT) != 0`. This closes the presync mechanisms and F-02.
2. Add `CurrencyReserves.RESERVES_OF_SLOT` to the digest.
3. For the `settleFor` mechanism, either have the hook forward the swap `sender` and add the sender's ETH and coin deltas to the digest, or state in the README that the guarantee holds only for an unlock with no other open debt.

```solidity
// Before
if (target == address(0) || _tload(LOCK_TSLOT) != 0 || gasleft() < MIN_CORRECTION_GAS) return;

// After
if (target == address(0) || _tload(LOCK_TSLOT) != 0 || gasleft() < MIN_CORRECTION_GAS) return;
if (POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0) return;
```

## [MEDIUM] F-02: A pending `sync` in the swapper's unlock sends the LP share to the fee recipient

**Severity**: Medium (Impact Medium, Likelihood Possible)
**Type**: Logic
**Location**: `contracts/wth-corrector/WthCorrector.sol:L346-L351`
**Status**: Open
**Sources**: Simao M-1 (7 lenses)

### Description
`_payout` sets `lpAmount` to 0 when a currency is synced on the PoolManager. The swapper's router controls that state with one free `sync` call. A coin's fee recipient, usually the creator, routes its swaps through such a router and receives the whole correction payment.

### Impact
The in-range LPs lose `lpShareBps` (25% to 100%) of every correction that such a swap triggers, while they still carry the zero-fee executor legs. With an external price gap, a dust trigger collects the full rebate. This breaks the README statement "LPs never under 25 %".

### Root Cause
A fallback that protects the native `settle` lets the caller choose the recipient of the LP share.

### Proof of Concept
[`poc/simao-12/SyncDivert.t.sol`](2026-10-07-security-twap-observer/poc/simao-12/SyncDivert.t.sol), `test_presync_divertsLpShareToRecipient`, passes: `CorrectionSettled(pid, 1e15, 3e14, 7e14)` becomes `CorrectionSettled(pid, 1e15, 0, 1e15)`.

### Recommendation
Skip the correction when a currency is synced (item 1 of F-01), and remove the synced-currency term from the payout fallback.

## [MEDIUM] F-03: A position added in the triggering unlock collects most of the donated LP share

**Severity**: Medium (Impact Medium, Likelihood Possible)
**Type**: MEV
**Location**: `contracts/wth-corrector/WthCorrector.sol:L353-L361`
**Status**: Open
**Sources**: Pashov full scope #6 (promoted from 2 agents), Simao M-2 (8 lenses)

### Description
`_payout` calls `donate` inside the unlock of the triggering swap. The hook does not gate liquidity changes. A swapper adds a narrow position at the predicted end tick, swaps, and removes the position in the same unlock. The executor can do the same inside its own call.

### Impact
The standing LPs, by default the liquidity manager's graduation position, lose up to about 95% of the LP share of each such correction.

### Root Cause
The donation is paid at once to the liquidity in range at that instant, and the triggering transaction controls that liquidity.

### Proof of Concept
[`poc/simao-10/SwapperJitPoC.t.sol`](2026-10-07-security-twap-observer/poc/simao-10/SwapperJitPoC.t.sol), `test_swapperJit_capturesDonation`, passes: 2857316425898231 of 3000000000000000 wei captured.

### Recommendation
Accrue the LP share and pay it in a later transaction. A deferred donation still allows a two-transaction JIT, at the cost of one block of price exposure.

## [MEDIUM] F-04: The floor-fee window of `quoteFee` is not bound to the executor

**Severity**: Medium (Impact Medium, Likelihood Possible)
**Type**: Access Control
**Location**: `contracts/wth-corrector/WthCorrector.sol:L159-L171`
**Status**: Open
**Sources**: Pashov full scope #4 (4 agents), Simao M-4 (4 lenses)

### Description
`quoteFee` gives the protocol floor to any exact-input swap opposite to the user, in band, while the window is open. It receives no sender. During each executor leg the hook notifies every other observer of the pool, and only the corrector returns at its lock. An observer that the creator binds, or a hook on the executor's route, swaps in band at the floor.

### Impact
The LPs earn no fee on that volume, and the executor's payment does not cover it.

### Root Cause
The window is keyed on the pool and the swap shape only.

### Proof of Concept
[`poc/pashov-11/WindowObserver.t.sol`](2026-10-07-security-twap-observer/poc/pashov-11/WindowObserver.t.sol) passes: a creator-bound observer sells 1.0504e25 coin for 0.2989 ETH inside the executor's leg, and `feeGrowthGlobal1` stays 0.

### Recommendation
Bind the window to the executor's own legs, for example through `hookData`, or close it in the corrector's nested notification and require the corrector to be notified first.

## [MEDIUM] F-05: Executor legs count as a price move in the hook, so later swappers pay a higher volatility fee

**Severity**: Medium (Impact Medium, Likelihood Likely)
**Type**: Logic
**Location**: `contracts/wth-corrector/WthCorrector.sol:L174-L187` with `FactoryHook.sol:L726-L735`
**Status**: Open
**Sources**: Pashov full scope #3, Simao lead (`hook-volatility-desync`)

### Description
Each in-band executor leg runs the hook's `_updateVolatility`. A correction that restores the price therefore doubles the volatility reading.

### Impact
On a pool that also binds a volatility-priced calculator such as `DynamicFeeExtension`, later swappers pay the mid or cap fee tier for up to about 280 seconds after a correction of a move that never reached that tier.

### Root Cause
The hook and the corrector disagree on what a price move is.

### Proof of Concept
[`poc/pashov-12/VolatilitySeam.t.sol`](2026-10-07-security-twap-observer/poc/pashov-12/VolatilitySeam.t.sol) passes: volatility 562 with the correction and 282 without it, against tier thresholds 300 and 900.

### Recommendation
Refuse a binding next to a volatility-priced calculator, or have the hook skip volatility accrual for swaps inside an open correction window (a hook change).

## [LOW] F-06: The band edge reads a `referenceTick` that nested swaps overwrite

**Severity**: Low (Impact Medium, Likelihood Unlikely)
**Type**: Logic
**Location**: `contracts/wth-corrector/WthCorrector.sol:L274-L297`
**Status**: Open
**Sources**: Pashov full scope #5 (promoted from 4 agents)

### Description
An observer listed before the corrector that swaps the same pool rewrites `referenceTick` and slot0, and it triggers its own correction because the lock is not set yet. `_openWindow` then builds the band from that swap, and the band can reach past the user's pre-swap price.

### Impact
Floor-fee legs across ticks that the user's swap did not open. No observer in the codebase swaps in `onAfterSwap`.

### Recommendation
Read the band inputs from the user's swap only, or enforce the "corrector last" listing rule at bind time.

## [LOW] F-07: The LP share reaches only the liquidity at the end price

**Severity**: Low (Impact Medium, Likelihood Unlikely)
**Type**: Logic
**Location**: `contracts/wth-corrector/WthCorrector.sol:L346-L361`
**Status**: Open
**Sources**: Simao L-2

### Description
The donation pays the liquidity at the price where the executor stops, not the liquidity that the zero-fee legs used. When that price has no liquidity, the fee recipient gets the whole payment, and the executor chooses that price. The README describes the in-range donation, so the behavior is documented. It does not match the purpose of the donation.

### Recommendation
Decide whether the LP share is a bonus or a compensation. If it is a compensation, stop the fee waiver and send the whole payment to the fee recipient.

## [INFO] I-01: `TwapObserver.record` reverts where its NatSpec says it does nothing

**Location**: `contracts/twap-observer/TwapObserver.sol:L118-L125`, `ITwapObserver.sol:L139-L145`
**Status**: Open

The NatSpec says `record` "does nothing otherwise". It reverts `PoolNotBound` and `PoolNotGraduated`. A keeper that batches calls without `try`/`catch` loses the batch. Align the NatSpec with the code.

## [INFO] I-02: The band edge is asymmetric between buys and sells

**Location**: `contracts/wth-corrector/WthCorrector.sol:L277`
**Status**: Open

`edgeTick = zeroForOne ? ref - 1 : ref + 1` with a floor tick gives a margin of 1 to 2 ticks for a sell and 0 to 1 tick for a buy. A sell that crosses one tick boundary gets a zero band, which disagrees with the `currentBand` NatSpec. Raised by 4 agents across both pipelines. No fund loss.

## [INFO] I-03: The corrector reads word 3 of the v1.1 `PoolState` layout without a check

**Location**: `contracts/wth-corrector/WthCorrector.sol:L294-L318`
**Status**: Open

`_bind` checks words 0 and 1. `_referenceTick` uses word 3 unchecked, and one deployment serves every hook generation. A later hook with another layout gives a wrong band edge.

## [INFO] I-04: Forced ETH stays in `WthCorrector`

**Location**: `contracts/wth-corrector/WthCorrector.sol:L127-L146`
**Status**: Open

ETH that arrives by `selfdestruct` or as a coinbase reward has no exit, because `recoverERC20` covers ERC-20 only (Aderyn H-2, x-ray I-18). The payout counts deltas, so the stray ETH does not change any split.

## 6. Leads and rejected candidates

Leads that no pipeline could prove, kept for manual review:

- The executor payment is checked only against `MIN_PAYMENT_WEI`, not against the waived LP fee (Pashov and Simao, 3 agents). This rests on the executor trust.
- A swapper who caps the gas skips the correction and keeps the back-run (Simao, 2 lenses, gas window measured at about 300k to 520k). The fix belongs in the hook.
- The executor runs inside the user's unlock and can move a later hop's pool (Pashov 11).
- Executor legs feed other observers, for example lottery tickets to `tx.origin` (Pashov 12).
- The payment model assumes a push payment in ETH or WETH, and no deployed executor confirms it (Simao 10).
- A floor-fee leg can start outside the band after a paid push (Pashov 6, 10). No profit found.

Rejected, with the gate that blocked each:

| Candidate | Reason |
|---|---|
| `TwapObserver.record` before pool initialization (TwapObserver scan, agent 9) | Unreachable. A direct launch sets `isLPd` and calls `initialize` in one transaction (`BCToken.sol:119-120`, `LiquidityManager.sol:208-209`), and a curve launch initializes the pool long before graduation |
| `TwapObserver.onRegisterObserver` duplicate listing (agent 8) | Documented in the README ("listing the observer twice fails the deploy"). Self-harm to the creator only |
| `TwapObserver.onRegisterObserver` binding by a malicious current hook (agent 2) | Needs the factory owner to point the liquidity manager at a hostile hook. Admin action with no unprivileged amplifier |

## 7. Recommendations

1. Treat the executor boundary as one design decision: what the digest must prove, and what the README promises (F-01, F-04).
2. Move the LP share out of the triggering transaction (F-02, F-03, F-07).
3. Coordinate with the hook team on the volatility accrual of executor legs and on a gas floor before the observer loop (F-05, gas lead).
4. Enforce, or remove, the listing-order rules at bind time (F-04, F-06).
5. `TwapObserver`: fix the NatSpec (I-01), and add a Halmos or longer invariant campaign for repeated growth before the audit.

## 8. Appendix

### A. Method notes and deviations

- Pass count and model were not asked: one pass per pipeline, all agents on Opus, because Sonnet agents and batched launches failed on earlier runs. Prompts used the neutral reviewer-panel form, so agents returned final blocks only and the reasoning-marker check of both skills could not run. Each agent reported its function count, and each Simao lens reported `lifecycles closed: 8`.
- The first Pashov scan (full scope) gave no finding or lead on `TwapObserver`, so a second Pashov scan in filename mode covered `TwapObserver.sol` and `ITwapObserver.sol` alone.
- Upstream `solidity-auditor` is at 4.1. The vendored skill is at 4.
- The copies of the assembled Pashov reports and run files are verbatim. Their em dashes come from the vendored assembler format.
- `.gitignore` now lists the root-level tool output (`.solidity-auditor/`, `.audit-*/`, `x-ray/`, Slither, Aderyn and coverage files), so a later run leaves the tree clean.
- PoCs: every agent PoC was re-run in one isolated copy at `da5dce3` with `FOUNDRY_OFFLINE=true forge test --match-path 'test/poc/**'`: 342 passed, 2 failed (agent 6's single-hop probes, which fail as the agent predicted). To re-run, copy a PoC folder to `test/poc/` of a checkout. The imports expect `test/wth-corrector/` two levels up.

### B. Static Analysis Output

[`pre-flight/slither.txt`](2026-10-07-security-twap-observer/pre-flight/slither.txt), [`pre-flight/aderyn.md`](2026-10-07-security-twap-observer/pre-flight/aderyn.md). Aderyn 0.1.9 wrote its report and then stopped on a version parse error.

### C. Test Coverage

[`pre-flight/coverage.txt`](2026-10-07-security-twap-observer/pre-flight/coverage.txt). Under coverage instrumentation 5 gas-ceiling tests fail, which is expected for an unoptimized build.

### D. Contract sizes

[`pre-flight/sizes.txt`](2026-10-07-security-twap-observer/pre-flight/sizes.txt): `TwapObserver` 6,547 B, `WthCorrector` 10,280 B runtime.
