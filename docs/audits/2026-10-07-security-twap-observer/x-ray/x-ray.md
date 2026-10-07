# X-Ray Pre-Audit Report

> Frontier Extensions (TwapObserver, WthCorrector) | 417 nSLOC | da5dce3 (`feat/twap-observer`) | Foundry | 07/10/26

---

## 1. Protocol Overview

**What it does:** Two singleton extensions of the Frontier Uniswap V4 hook (`FactoryHook` v1.1): a TWAP history ring fed by after-swap notifications, and a back-run corrector that has a partner executor arbitrage the pool inside the user's swap and splits the executor's payment.

- **Users**: swappers on Frontier coin/ETH pools (they trigger both extensions through the hook), contracts that read a TWAP, coin creators who bind the extensions at launch, LPs and fee recipients who receive correction payments.
- **Core flow**: user swap → hook `_afterSwap` → observer notifications under a shared 600k gas budget → TwapObserver stores `observe()` once per `interval`, WthCorrector calls `executor.executeArbitrage` and pays out.
- **Key mechanism**: TwapObserver keeps a per-pool ring of `(timestamp, tickCumulative)` read from the hook's truncated tick oracle. WthCorrector opens a transient price band and returns a fee of 0 (floored by the hook to 3 bps) for executor legs inside it.
- **Token model**: no token of its own. WthCorrector handles WETH and native ETH payments only. TwapObserver holds no value.
- **Admin model**: `BCTokenFactory.owner()` can set or pause the executor and recover ERC-20 from WthCorrector, instantly. TwapObserver has no admin. Each pool answers only to the hook that registered it (`HookGated`).

For a visual overview see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| TWAP history | `contracts/twap-observer/TwapObserver.sol` | 144 | After-swap observer, per-pool observation ring, `consult`, open `record` and `increaseCardinality`. New on this branch (4 commits ahead of `origin/main`) |
| Back-run correction | `contracts/wth-corrector/WthCorrector.sol` | 273 | Last fee calculator plus after-swap observer, executor call, delta digest, LP donation and WETH payout. On `main`, after one audit fix round (`11750cd..742d643`) |

Reference only (not counted): `ITwapObserver.sol` (42), `IWthCorrector.sol` (43), `IWthArbitrageExecutor.sol` (13). Out of scope but read: `lib/extension-kit/contracts/HookGated.sol`, `lib/extension-kit/lib/factory-hook/v1.1/src/hook/FactoryHook.sol`.

nSLOC note: the skill's `enumerate.sh` uses `grep -P`, which macOS BSD grep refuses, so its nSLOC, NatSpec and test sections came back zero. This report computed nSLOC (non-blank, non-comment lines), NatSpec counts and test signals with POSIX `awk`/`grep`. Aderyn reports the same per-file nSLOC (144, 273).

### How It Fits Together

The core trick: the hook already calls observers inside the user's swap with a bounded gas budget and swallows their reverts, so each extension does its work in that callback and cannot make the user's swap revert by its own failure.

```
Swap with both extensions bound (WthCorrector listed last)
PoolManager.swap() → FactoryHook._beforeSwap()            *isLPd gate, referenceTick := pre-swap tick*
  └─ fee chain: ... → WthCorrector.quoteFee()             *window closed: returns previousFee*
  → FactoryHook._afterSwap() → _checkpointSwap()          *truncated tick clamped to ±9116 per second*
     └─ _settleSwapTail() → _notify(observer, budget)     *raw call, revert ignored, shared 600k budget*
        ├─ TwapObserver.onAfterSwap()
        │    └─ _due()? → _record() → FactoryHook.observe()   *one slot write, cursor in the same slot*
        └─ WthCorrector.onAfterSwap()                      *LOCK := 1*
             ├─ _openWindow()                              *band = (post price, pre-swap tick ± 1), direction*
             ├─ _correct(): digest₀ → executor.executeArbitrage(gas - 120k)
             │    └─ executor legs → hook → quoteFee() = 0 in band   *nested onAfterSwap returns at once*
             │    └─ WETH / ETH → WthCorrector.receive()           *accepted only while LOCK is set*
             │  WINDOW := 0, digest₁ == digest₀ else revert
             └─ _payout(): lpShareBps → settle + donate (ETH), rest → feeRecipient (WETH)
```

```
Open TWAP path
record(poolId) → _due() → poolCoin().isLPd() → _record()
increaseCardinality(poolId, n) → pre-write slots [cardinalityNext, n) with timestamp 1
   *growth applies inside _record() when newest == cardinality - 1*
consult(poolId, secondsAgo) → _search(target = now - secondsAgo) → observe() → (cumNow - cumPast) / span, floor
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as **DEX / AMM** (Uniswap V4 hook extension) with **oracle-provider (TWAP)** characteristics

Both contracts run inside `PoolManager` swaps, price legs through the fee chain, `settle` and `donate` on the PoolManager, and TwapObserver exposes a `consult` price for other contracts. There is no share accounting, lending or bridge logic.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Swapper (EOA or router) | Untrusted | Triggers both extensions on every swap. Chooses the router, so it controls pending `sync` state and `hookData` |
| Anyone | Untrusted | `TwapObserver.record`, `increaseCardinality` (pays for slots), all views |
| TWAP reader (contract) | Untrusted consumer | Reads `consult`. Must check `span` itself |
| FactoryHook (pinned per pool) | Trusted | Only caller of notifications and binds. Supplies `observe`, `getPoolState`, `poolCoin` |
| Factory owner (`BCTokenFactory.owner()`) | Trusted | Instant `setExecutor` (zero pauses all pools), instant `recoverERC20`. Also points the LM at a new hook generation (out of scope). No timelock in scope |
| Partner executor | Bounded (digest check, `MIN_PAYMENT_WEI`, gas budget, revert unwinds) | Runs arbitrary code inside the user's unlock with the floor-fee window open |
| Coin creator / fee recipient | Bounded (LP share ≥ 25 % at bind) | Chooses extension order and `lpShareBps` at launch. Receives the non-LP part in WETH |
| LP | Untrusted | Receives donations. Can add in-range liquidity at any time |
| MEV searcher | Adversarial | Orders transactions around swaps that trigger corrections |

**Adversary Ranking** (by threat level for this protocol type, adjusted by git evidence):

1. **Code that runs during the correction window**: the executor and anything it calls see a pool where in-band legs pay the floor fee only.
2. **MEV searcher / JIT LP**: corrections end with a `donate` to in-range liquidity inside a swap that is visible in the mempool.
3. **Swapper with a custom router**: it controls PoolManager state (synced currency, own deltas) that the corrector reads during payout.
4. **TWAP manipulator**: anyone who can hold the pool price for several seconds moves short `consult` windows (TwapObserver is the newest code).
5. **Compromised factory owner**: one instant call replaces the executor for every bound pool.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Hook to extension**: per-pool pinning (`HookGated.sol:55-60`, `WthCorrector.sol:387-389`, `TwapObserver.sol:105`). The LM's current hook can bind any not-yet-bound pool id. *Git signal: WthCorrector binding changed in 4 fix-scored commits.*
- **Extension to executor**: protected by the delta digest (`WthCorrector.sol:322-331`), payment floor and gas reserve. The executor still runs with the floor-fee window open and the user's unlock active.
- **Admin**: `setExecutor` and `recoverERC20` (`WthCorrector.sol:133-146`) execute instantly, with an event and no delay. Whether the factory owner is a multisig could not be determined from the source.
- **Extension to readers**: `consult` (`TwapObserver.sol:149-173`) reports `span` but enforces no maximum. Readers own the tolerance check.

### Key Attack Surfaces

- **Floor-fee window open to any swap** &nbsp;&#91;[I-24](invariants.md#i-24), [I-20](invariants.md#i-20), [G-27](invariants.md#g-27), [E-3](invariants.md#e-3)&#93;: `quoteFee` (`WthCorrector.sol:159-171`) checks pool, direction, exact input and the limit, not the swapper or the start price. Worth tracing which code can swap the pool while the executor runs, and legs that start outside the band.

- **Delta digest coverage** &nbsp;&#91;[I-23](invariants.md#i-23), [I-22](invariants.md#i-22), [G-36](invariants.md#g-36)&#93;: the digest (`WthCorrector.sol:322-331`) holds the nonzero count plus four deltas and the synced currency. Worth tracing `settleFor`, `take`, `clear` and `sync` sequences that keep the count equal while they move a router or executor delta.

- **LP share fallbacks and JIT donation** &nbsp;&#91;[I-25](invariants.md#i-25), [G-39](invariants.md#g-39), [E-2](invariants.md#e-2)&#93;: `WthCorrector.sol:347-351` sends the whole payment to the fee recipient when a currency is synced or liquidity is zero. Worth checking who can make that true for a swap, and who captures the `donate` at :360.

- **Observer order and the shared gas budget** &nbsp;&#91;[X-1](invariants.md#x-1), [X-5](invariants.md#x-5), [I-15](invariants.md#i-15), [G-28](invariants.md#g-28)&#93;: the corrector forwards `gasleft() - 120k` (`:264-268`) out of the hook's shared 600k budget, and reads `referenceTick` that any earlier swapping observer rewrites. Worth tracing every listing order of the two extensions on one pool.

- **Ring growth and slot arithmetic (new code)** &nbsp;&#91;[I-5](invariants.md#i-5), [I-7](invariants.md#i-7), [I-8](invariants.md#i-8), [G-16](invariants.md#g-16)&#93;: growth applies at `TwapObserver.sol:209-211`, and `_slot` (:261-266) maps positions through the modulo. Worth tracing several `increaseCardinality` calls between two wraps, and growth at `cardinalityNext == 255`.

- **`consult` window semantics** &nbsp;&#91;[I-10](invariants.md#i-10), [I-11](invariants.md#i-11), [X-2](invariants.md#x-2), [E-1](invariants.md#e-1)&#93;: `TwapObserver.sol:149-173` returns the newest observation of any age when it is older than the target. Worth confirming how far `span` can exceed `secondsAgo` after an idle stretch, and the per-second clamp on chains that share a timestamp across blocks.

- **Unpaid corrections cost the swapper gas** &nbsp;&#91;[I-21](invariants.md#i-21), [G-29](invariants.md#g-29), [G-35](invariants.md#g-35)&#93;: every swap on a bound pool runs the executor until `PaymentTooLow` or `ExecutorCallFailed` (`WthCorrector.sol:183`, :245) unwinds it. Worth measuring the worst case per swap inside the 600k budget.

- **Binding checks** &nbsp;&#91;[I-14](invariants.md#i-14), [I-13](invariants.md#i-13), [X-6](invariants.md#x-6), [X-3](invariants.md#x-3)&#93;: `onAfterSwap` never reads `binding.roles` (`WthCorrector.sol:174-187`), the prefix check covers words 0 and 1 only (:225), and TwapObserver binds a hook without checking for `observe`. Worth checking observer-only bindings and a hook generation change.

- **Permissionless ring growth against gas-capped readers** &nbsp;&#91;[I-3](invariants.md#i-3), [G-11](invariants.md#g-11)&#93;: anyone can raise a pool to 255 slots (`TwapObserver.sol:128-146`), which raises `consult` cost for every reader. Worth checking readers that call `consult` under `CALC_GAS_STIPEND` (50k).

- **Factory owner operational powers**: `setExecutor` (`WthCorrector.sol:133-137`) takes effect at once for all pools, with no allowlist, delay or two-step. The new executor receives the floor-fee window on its first call.

- **Stray native ETH** &nbsp;&#91;[I-18](invariants.md#i-18), [I-17](invariants.md#i-17)&#93;: ETH that arrives without `receive` has no exit path (`recoverERC20` only, :140). Worth confirming that it cannot enter a later `nativeReceived` count (:248).

### Protocol-Type Concerns

**As a DEX / AMM extension:**
- `WthCorrector._openWindow` (:274-291): the band edge is the pre-swap tick moved one tick toward the post price. Partial-tick positions of the pre-swap price leave part of the user's move outside the band.
- `WthCorrector._payout` (:343-367): the LP share is donated to in-range liquidity at the post-correction tick, not to the liquidity that the user's swap crossed.

**As a TWAP oracle provider:**
- `TwapObserver.consult` (:149-173): the average is the hook's truncated tick, clamped to `MAX_ABS_TICK_MOVE` (9116) per second from the tick the second opened at (`FactoryHook.sol:747-763`). It is not the pool tick.
- `TwapObserver._record` (:195-224): the guaranteed reach is `(cardinality - 1) * interval` (README, test `test_audit_guaranteedReachIsCardinalityMinusOneIntervals`). After a growth, the extra reach builds one recording at a time.

### Temporal Risk Profile

**Deployment & Initialization**
- Extension order and configs are creator choices at `registerPool`. Nothing in scope enforces "corrector last" (`I-15`). Status: unmitigated onchain, documented in README.
- WthCorrector is usable at deploy with `executor == address(0)` (corrections paused) until `setExecutor`. Status: mitigated (zero pauses, `:177`).
- TwapObserver has no history right after graduation. `record` (:118-125) fills the first point. Status: documented.

**Market Stress**
- Fast moves: the truncated tick lags the pool tick by up to 9116 ticks per second, so short `consult` windows lag a crash or a spike. Status: documented in README "Limits".
- Gas spikes do not matter on the swap path, since the correction gas is part of the user's own swap gas. Unpaid corrections still burn it (`G-29`). Status: partially mitigated by `MIN_CORRECTION_GAS`.

**Governance & Upgrade Windows**
- No proxies. A hook generation change (LM pointer, out of scope) leaves old pools on their pinned hook, while new pools bind the new hook through `_registerPool`. `X-3` and `X-6` apply to the new generation. Status: partially mitigated by per-pool pinning.

### Composability & Dependency Risks

> **FactoryHook v1.1** via `TwapObserver._record()`, `consult()`, `WthCorrector._poolStatePrefix()`
> - Assumes: `observe` is continuous in time, `getPoolState` head words 0, 1, 3 are coin, registered, referenceTick
> - Validates: words 0 and 1 at bind (`G-34`), returndata size (`G-38`). Nothing on `observe`
> - Mutability: immutable per pool (pinned), new generations through the LM pointer (factory owner)
> - On failure: TwapObserver reverts (hook swallows it on the swap path), WthCorrector reverts the correction

> **Partner executor** via `WthCorrector._callExecutor()`
> - Assumes: pays at least `MIN_PAYMENT_WEI` in WETH or ETH, leaves the digested PoolManager slots unchanged
> - Validates: digest (`G-36`), payment floor (`G-29`), call success (`G-35`), returndata never copied
> - Mutability: replaceable at once by the factory owner
> - On failure: correction reverts, hook swallows it, user swap continues

> **Uniswap V4 PoolManager** via `WthCorrector._payout()`, `_deltaDigest()`, `_openWindow()`
> - Assumes: transient slot layout of `NonzeroDeltaCount`, `CurrencyReserves` and currency deltas as in v4-core
> - Validates: synced currency and in-range liquidity before `settle`/`donate` (`G-39`)
> - Mutability: immutable
> - On failure: revert of the correction

> **BCToken / BCTokenFactory / LiquidityManager** via `record()` (`isLPd`), `_payout()` (`getFeeRecipient`), `HookGated._registerPool()` (`liquidityManager().hook()`), admin gates (`owner()`)
> - Assumes: `getFeeRecipient` returns an address that WETH can pay
> - Validates: nothing on the recipient address
> - Mutability: fee recipient set per coin (out of scope), owner and LM governed by the factory owner
> - On failure: a refused WETH transfer reverts the correction (`G-40`)

**Token Assumptions** *(unvalidated only)*:
- WETH: assumes the canonical WETH9 behavior (`withdraw` sends ETH through `receive`, `transfer` returns `bool`). Impact if violated: corrections revert.
- Native ETH: assumes ETH reaches the corrector only through `receive`. Impact if violated: stray ETH is stuck (`I-18`).

**Shared State Exposure**:
- Both extensions are singletons. One `executor` and one `LOCK_TSLOT` serve every pool of WthCorrector. One `consult` cost profile serves every TwapObserver reader. The hook's 600k observer budget is shared by every observer of a pool.

---

## 3. Invariants

> ### Full invariant map: **[invariants.md](invariants.md)**
>
> - **41 Enforced Guards** (`G-1` … `G-41`): per-call preconditions with check, location, purpose
> - **27 Single-Contract Invariants** (`I-1` … `I-27`): Conservation, Bound, StateMachine, Temporal
> - **6 Cross-Contract Invariants** (`X-1` … `X-6`): caller/callee pairs, hook side read at v1.1 (out of scope)
> - **3 Economic Invariants** (`E-1` … `E-3`): higher-order properties from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift with write sites, state edge,
> temporal predicate, or NatSpec quote. The **Onchain: No** blocks (13) are the high-signal ones.
> Each is at the same time an invariant and a potential bug. Attack surfaces above link
> directly into the relevant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | 166 lines. Per-extension design, gas figures, limits, owner levers. Acts as the spec |
| NatSpec | 82 `@`-tags in the two contracts, 146 in the three interfaces | Full NatSpec on interfaces, `@inheritdoc` on implementations, `@notice` on internals |
| Spec/Whitepaper | Missing as a separate file | README sections carry the spec (per spec claims tagged below) |
| Inline Comments | Thorough | TwapObserver states four `INVARIANT:` lines (:27-32). Every cast and tool suppression has a reason |

- `(per spec)` README: "The user's swap always completes." See `I-23` for what the code enforces.
- `(per spec)` README: a full correction costs about 292k with the test executor. Not measured here.
- `(per code)` `TwapObserver.sol:27-32` invariants are confirmed in `I-3`, `I-6`, `I-7`, `I-10`.
- `SECURITY.md` gives a private disclosure path. No known-issues list exists.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 7 test contracts (plus 3 mocks, 2 fork files excluded by the default profile) | File scan (always reliable) |
| Test functions | 132 (123 `test*` incl. 2 fork, 5 `testFuzz*`, 4 `invariant_*`) | File scan (always reliable) |
| Line coverage | 100.00 % (242/242). TwapObserver 91/91, WthCorrector 151/151 | `forge coverage`, default profile |
| Branch coverage | 98.39 % (61/62). TwapObserver 28/28, WthCorrector 33/34 | `forge coverage`, default profile |
| `forge test` (1.7.1) | 128 pass, 2 fail | Local run |
| `forge build --force` | Pass | Local run |
| `forge fmt --check` | Pass (exit 0) | Local run |

Failing tests on forge 1.7.1, both gas ceilings in `test/twap-observer/TwapObserver.t.sol`: `test_gas_onAfterSwapRecordingIntoAPrewrittenSlot` (15348 >= 12000) and `test_gas_onAfterSwapRecordingPath` (32377 >= 32000). CI pins Foundry v1.5.1. This report did not check the result on v1.5.1. Under coverage instrumentation, five gas ceiling tests fail (`consultOnA255SlotRing`, `increaseCardinalityPerSlot`, `onAfterSwapNoOpPath` and the two above). This is expected for unoptimized builds and does not affect the coverage numbers.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit / integration (real hook on a local V4 stack) | 121 | Both |
| Fork (Robinhood RPC, not run) | 2 | WthCorrector |
| Stateless Fuzz | 5 | TwapObserver (2), WthCorrector (2), prefix read (1) |
| Stateful Fuzz (Foundry) | 4 invariants, 48 runs × depth 40 | TwapObserver only |
| Stateful Fuzz (Echidna / Medusa) | 0 | None |
| Formal Verification (Certora / Halmos / HEVM) | 0 | None |

### Gaps

- No stateful fuzz for WthCorrector. A handler with a hostile executor (settle, take, `settleFor`, `sync`, swap in and out of band) would exercise `I-23`, `I-24`, `I-25`.
- The TwapObserver invariant campaign is small (48 runs, depth 40). Growth to 255 with many wraps needs deeper runs.
- No formal check of `_slot` / `_search` arithmetic (`I-5`, `I-7`), which is small and bounded: a good Halmos target.
- Hostile executor modes (`HostileExecutorMock.sol:31-40`) cover stale sync, in-band sell, coin and native payment, recovery, JIT, gas burn. None calls `settleFor` or `clear`.
- One WthCorrector branch is not covered (33/34). The coverage summary does not name it.
- No test lists TwapObserver after a gas-heavy WthCorrector on the same pool. `test_audit_greedyObserverListedFirstStarvesTheRing` uses a generic greedy observer.

---

## 6. Developer & Git History

> Analyzed branch: `feat/twap-observer` at `da5dce3`. Repo shape: normal_dev. 10 commits over 3 days (2026-09-30 to 2026-10-03), 8 touch source.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| 0xpercival | 10 | +1245 / -154 | 100 % |

Single developer for all in-scope code.

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 of 10 | No merge commits on this branch, no visible peer review |
| Repo age | 2026-09-30 → 2026-10-03 | 3 days |
| Recent source activity (30d) | All 8 source commits | Late burst: the whole codebase is recent |
| Test co-change rate | 87.5 % | Measures co-modification, NOT coverage |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `contracts/wth-corrector/WthCorrector.sol` | 5 | 4 fix-scored commits after the first one |
| `contracts/wth-corrector/IWthCorrector.sol` | 5 | Follows the contract |
| `contracts/twap-observer/TwapObserver.sol` | 3 | New, last change on 2026-10-03 |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 53f5159 | 2026-09-30 | fix(wth-corrector): drop the claimable path, add token recovery | 17 | Guard added, transfer logic, net removal |
| 742d643 | 2026-10-01 | fix(wth-corrector): keep a router's pending sync intact, bound the constructor | 16 | Guard added (`InvalidGates`), payout settle path |
| 11750cd | 2026-09-30 | fix(wth-corrector): address audit findings | 16 | Guards added (digest of synced currency, `MIN_PAYMENT_WEI`, tail reserve) |
| c877501 | 2026-09-30 | fix(wth-corrector): fixed 8000 bps split, per-pool LP/recipient payout | 12 | Payout split rewrite |
| 4753526 | 2026-10-02 | feat(twap-observer): add the TWAP observer extension | 8 | New oracle code, 378 lines |
| 440b38c | 2026-09-30 | feat: official extensions repo with WthCorrector | 8 | Initial import, 611 lines |
| 4a2c8a8 | 2026-10-03 | feat(twap-observer): let anyone grow a pool's cardinality | 6 | New permissionless entry point, ring growth |
| a069029 | 2026-10-03 | docs(twap-observer): state the guaranteed history and the reader's gas budget | 5 | Comment only |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| oracle_price | 8 | All four contract and interface files |
| fund_flows | 5 | `WthCorrector.sol` |
| signatures | 5 | `WthCorrector.sol` (keyword match on `digest`, no signature code exists) |
| state_machines | 3 | `TwapObserver.sol` |

### Forked Dependencies

| Library | Path | Upstream | Status | Notes |
|---------|------|----------|--------|-------|
| frontier-extension-kit | `lib/extension-kit` | CamelotLabs/frontier-extension-kit | Submodule at `b62e5d1` | Provides `HookGated` |
| factory-hook | `lib/extension-kit/lib/factory-hook` | FrontierFun/factory-hook | Nested submodule at `9ab69b1` | Folder `v1.1` is the hook source. Its `lib/` carries OpenZeppelin, v4-periphery, v4-core |

No internalized copies of third-party libraries in `contracts/`.

### Technical Debt Markers

None. No TODO, FIXME, HACK, XXX or BUG markers in scope.

### Security Observations

- **Prior audit round** on WthCorrector: four fix commits `11750cd..742d643` added the synced-currency digest, `MIN_PAYMENT_WEI`, the tail reserve and the pending-sync payout fallback.
- **TwapObserver is unreviewed new code**: `4753526`, `4a2c8a8` and `a069029` landed 2026-10-02 and 2026-10-03, then `da5dce3` added audit probe tests only.
- **Ring growth came last**: `4a2c8a8` added `increaseCardinality`, raised the maximum to 255 and replaced `SafeCast` with explicit checks.
- **Single author, no merges**: every source line comes from `0xpercival`.
- **Suppression density**: TwapObserver carries 12 `slither-disable` lines and 6 `aderyn-ignore` lines, each with a reason. WthCorrector carries none.
- **Gas ceilings are part of the spec**: the observer budget and `CALC_GAS_STIPEND` make gas a correctness input, and two ceiling tests fail on forge 1.7.1.

### Cross-Reference Synthesis

- Fix history concentrates on the executor boundary and payout → the digest and LP fallback surfaces (`I-23`, `I-25`) are where the earlier round found issues.
- Newest code is the ring growth → `I-5`, `I-7`, `I-8` and the gas ceilings carry the least review time.
- Single developer plus README-as-spec → every `Onchain: No` block that quotes NatSpec (`I-14`, `I-15`, `I-25`) is a design statement no second person checked.

---

## 7. Static Analysis Summary

| Tool | High | Medium | Low | Notes |
|------|-----:|-------:|----:|-------|
| Slither | 0 | 6 | 3 | All on WthCorrector. 0 on TwapObserver (annotated). 17 informational (naming, assembly) |
| Aderyn 0.1.9 | 2 | 0 | 4 | Report written, then the binary panicked on a version parse (exit 101) |

Slither Medium triage: `incorrect-equality` on `amount == 0` (:371) is benign. `uninitialized-local` `lower`/`upper` (:279-280) are zero on purpose (empty band). `unused-return` on `getSlot0` (:275), `settle` (:359), `donate` (:360) is by design. Low: `missing-zero-check` on `setExecutor` (zero pauses by design), two `reentrancy-events`.

### Findings Requiring Manual Review

- Aderyn H-1 unsafe cast `int24(word)` at `WthCorrector.sol:296`: the word is the raw ABI head of an `int24` from the pinned hook (`X-6`).
- Aderyn H-2 "locks Ether without a withdraw function": matches `I-18` (no ETH exit for force-sent ETH).
- Aderyn L-1 on `IWETH(WETH).transfer` at :372: the return value is checked. Low signal.

---

## X-Ray Verdict

**ADEQUATE**: unit, fuzz and Foundry invariant tests exist with 100 % line coverage, NatSpec and a README spec are thorough, but the single admin lever has no timelock and two gas tests fail locally.

### Readiness Criteria

| Criterion | Status | Notes |
|-----------|--------|-------|
| Build succeeds | Yes | `forge build --force` passes on forge 1.7.1 |
| Tests pass | Partial | 128 of 130 pass on 1.7.1. Two gas ceiling tests fail. CI version v1.5.1 not checked |
| Coverage measured on core | Yes | 100 % lines, 98.39 % branches |
| NatSpec on public functions | Yes | Interfaces carry full NatSpec, implementations use `@inheritdoc` |
| Invariants documented | Partial | Four `INVARIANT:` lines in TwapObserver. None stated for WthCorrector |
| Known issues listed | No | No known-issues file. README "Limits" covers TWAP limits only |
| No critical Slither findings | Yes | 0 High. 6 Medium triaged as by-design |
| Architecture documented | Yes | README per extension |

### Structural Facts

1. 417 nSLOC across 2 contracts in 2 subsystems, plus 98 nSLOC of interfaces. No proxies, no upgradeable storage.
2. 132 test functions: 121 local unit/integration, 2 fork, 5 stateless fuzz, 4 Foundry invariants (TwapObserver only). 0 Echidna, Medusa or formal.
3. 1 contributor wrote 100 % of source lines in 10 commits over 3 days, with 0 merge commits.
4. 1 admin role (`BCTokenFactory.owner()`) with 2 instant functions. TwapObserver has no admin.
5. 2 of 10 entry points are permissionless state writers (`record`, `increaseCardinality`). Both are on TwapObserver, the newest code.

### Top Concerns for Auditors

1. The floor-fee window and the delta digest of WthCorrector, as one system: which code runs, and which deltas move, while the executor holds the user's unlock (`I-23`, `I-24`).
2. LP share fallbacks and the donation recipient set (`I-25`, `E-2`).
3. TwapObserver ring growth and `_slot`/`_search` arithmetic under repeated growth (`I-5`, `I-7`, `I-8`).
4. Listing order and gas budget interaction of the two extensions on one pool (`X-1`, `X-5`).
5. `consult` semantics for consumers: span bounds, truncated tick, gas cost after growth (`I-11`, `E-1`).

### Recommended Audit Mode

**Core**: small scope (417 nSLOC) with tests and docs in place, but the executor boundary is subtle and TwapObserver has had no review.
