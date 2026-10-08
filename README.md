# Frontier Extensions

The official extensions of the [Frontier](https://frontier.fun) hook: fee calculators and observers
maintained by Frontier, tested against the real `FactoryHook` and deployed on Robinhood Chain.

To build your own extension, start from the
[Frontier Extension Kit](https://github.com/CamelotLabs/frontier-extension-kit): it is the template
this repository builds on, and its README explains how extensions work, the rules they must follow
and how to test them. This repository pulls the kit as a submodule (`lib/extension-kit`), which
carries the published hook source ([FrontierFun/factory-hook](https://github.com/FrontierFun/factory-hook),
folder `v1.1`, the hook live on Robinhood Chain 4663).

A catalog of the extensions (here or served by the API) and a process for community submissions are
upcoming; this repository holds Frontier's own extensions only for now.

```sh
git clone --recurse-submodules <this repo> && cd frontier-extensions
forge test                          # local: real hook on a local Uniswap v4 stack
FOUNDRY_PROFILE=fork forge test     # live: against Robinhood Chain (in CI: the "Fork" workflow, by hand)
```

## Extensions

| Extension | Roles | Status |
|---|---|---|
| [`WthCorrector`](contracts/wth-corrector/WthCorrector.sol) | fee calculator + after-swap observer | not deployed |
| [`TwapObserver`](contracts/twap-observer/TwapObserver.sol) | after-swap observer | deployed, `twap-observer/v1.0.0` |

### WthCorrector

One singleton bound on a pool **in both roles**: last fee calculator of the chain and last after-swap
observer. After a user swap it has a partner executor close the price gap the swap opened against
other venues, inside the same Uniswap unlock, and splits what the executor pays between the pool's
LPs and the coin's fee recipient.

- **Binding.** `onRegisterCalculator` and `onRegisterObserver`, hook-gated through the kit's
  `HookGated`, write-once per role. The config of each role is `abi.encode(int24 tickSpacing,
  uint16 lpShareBps)`, the same for both roles: the pool key `(ETH, coin, dynamic fee, tickSpacing,
  hook)` rebuilt from it must hash to the pool id, the hook's `getPoolState` prefix must name that
  coin as registered, and `lpShareBps` must lie between `MIN_LP_SHARE_BPS` (2500) and 10 000. There
  is no default: an empty or malformed config fails the deploy. List the corrector last in both
  lists: a calculator after it could reprice the legs, an observer before it that swaps would move
  the band.
- **Flow.** `onAfterSwap` opens a transient window carrying the band of the user's swap (its
  post-swap price and its pre-swap tick moved one tick inside) and calls
  `executor.executeArbitrage(poolKey, address(0), ProfitSplit(this, 0, CREATOR_BPS, 0))`, with
  `CREATOR_BPS` the constant 8000, the sum the executor requires of the split's three shares
  ([`IWthArbitrageExecutor`](contracts/wth-corrector/IWthArbitrageExecutor.sol), selector `0xd4641322`).
  `quoteFee` prices the legs the executor sends back through the pool: opposite to the user's swap,
  exact-input, with a price limit strictly inside the band, a leg pays the protocol floor only; any
  other leg pays the pool's normal fee. `currentBand(poolId)` exposes the band while the window is
  open.
- **Unwinding.** The executor's own legs notify the corrector again; a transient self-lock returns
  them at once. Around the call the corrector digests the PoolManager's nonzero-delta count, the
  hook's and its own deltas on both currencies and the synced currency: a changed digest, a reverting
  executor or a payment under `MIN_PAYMENT_WEI` reverts the correction, which the hook swallows, and
  every leg unwinds with it. The user's swap always completes.
- **Payout.** The corrector receives `CREATOR_BPS` (8000) of the executor's realized profit, the
  executor's interface reserving the other 2000 bps, and takes nothing for the protocol. The payment is counted in the
  pool's quote currency, WETH and native ETH together (`receive` accepts ETH only during a
  correction); under `MIN_PAYMENT_WEI` the correction reverts, whatever else the executor sent. The
  pool's `lpShareBps` of it is donated to the pool's in-range liquidity in ETH (to the fee recipient
  instead when the pool has none, or when the swapper's router left a currency synced on the
  PoolManager), the rest goes to the coin's `getFeeRecipient()` in WETH; the
  coin creator sets that split at launch, LPs never under 25 %. A refused WETH transfer reverts the
  correction. `CorrectionSettled(poolId, received, lpAmount, recipientAmount)` records every split;
  `ExecutorSet` and `TokensRecovered` the owner's actions.
- **Gas.** The correction runs inside the hook's 600k observer budget, shared with the pool's other
  observers. With the test executor a full correction (one in-band leg through the hook, one leg on
  a plain pool, payout with donation) costs about 292k: roughly 90k in the corrector, 103k for the
  hook leg, 49k for the plain leg. `onAfterSwap` returns without calling the executor when
  `gasleft()` is under `MIN_CORRECTION_GAS`, and keeps `TAIL_RESERVE` (120k) back from the executor
  call for the snapshot check and the payout.
- **Owner levers.** `setExecutor(address)`, callable by the `BCTokenFactory` owner, with an event and
  no delay: the zero address pauses corrections on every bound pool. `recoverERC20(token, to, amount)`,
  same gate, sends out stray tokens (the corrector holds nothing between transactions).
  `MIN_CORRECTION_GAS` (above `TAIL_RESERVE`) and `MIN_PAYMENT_WEI` (nonzero) are constructor
  immutables.

Tests: [`test/wth-corrector/`](test/wth-corrector/) (the corrector through real swaps on the real
hook, a scripted executor arbitraging against a plain v4 pool, a hostile executor whose every
misbehaviour must stay contained, and the `getPoolState` prefix read checked against the typed
decode); [`test/fork/`](test/fork/) checks that prefix on the live hook and simulates corrections on
a coin launched through the live factory.

### TwapObserver

One singleton bound on a pool as an after-swap observer. The hook's `observe(poolId)` gives the
truncated tick cumulative at the current timestamp, with no history; the observer stores those
readings so that any contract can read a time-weighted average tick without a keeper.

- **Binding.** `onRegisterObserver`, hook-gated through the kit's `HookGated`, once per pool (listing
  the observer twice fails the deploy). The config is empty, for the defaults (`interval` 5 minutes,
  `cardinality` 16), or `abi.encode(uint32 interval, uint16 cardinality)` with `interval` between
  1 minute and 1 day and `cardinality` between 2 and 255; anything else fails the deploy. Subscribe
  with `CALL_AFTER_SWAP`. `PoolBound(poolId, hook, interval, cardinality)` records the binding.
- **Recording.** On every swap, if at least `interval` seconds passed since the pool's newest
  observation, `onAfterSwap` stores `(block.timestamp, tickCumulative)` in the next slot of the
  pool's ring of `cardinality` slots, overwriting the oldest once full; otherwise it returns after one
  storage read. `record(poolId)` does the same for anyone, on a bound and graduated pool (right after
  graduation, or after a quiet stretch). No event on recording.
- **Reading.** `consult(poolId, secondsAgo)` returns `(averageTick, span)`: the average truncated tick
  from the newest observation at least `secondsAgo` old to now, rounded toward negative infinity,
  and the seconds it actually covers. `span >= secondsAgo` always and the answer is exact for that
  span (no interpolation); check `span` against your own tolerance. It reverts `NotEnoughHistory`
  when no stored observation is that old, and on `secondsAgo == 0`. `poolState`, `observationAt`
  (index 0 the oldest) and `latestObservation` expose the ring.
- **Cardinality.** The cardinality is the number of observations a pool's ring keeps, so with the
  interval it sets how far back `consult` can reach. Anyone may grow it with
  `increaseCardinality(poolId, cardinalityNext)`, up to 255, and pays for the new storage: the new
  slots are written with a placeholder at once, so later recordings into them cost an overwrite,
  not a fresh slot. It never shrinks, and the interval never changes. The growth is pending
  (`cardinalityNext` in `poolState`) until the ring next writes its current last slot; from there it
  continues into the new slots, so no kept observation is lost or reordered, and the extra history
  builds up one recording at a time. A placeholder is never read. `CardinalityIncreased(poolId, old,
  new)` records every growth.
- **Gas.** Measured on the observer alone, its account cold: about 4.1k when nothing is due, 29.6k
  when it writes a fresh slot, 9.7k when it writes a slot a growth pre-wrote, about 10.9k for
  `record` overwriting a slot of a full ring, 21.5k for `consult` on a full 16-slot ring and 33.1k on
  a full 255-slot ring. `increaseCardinality` costs about 22.7k per added slot. Inside a real swap,
  the hook's notification included, a bound pool pays about 9.5k more per swap when nothing is due
  and 37.5k when a fresh slot is written. Since anyone may grow a pool's ring and it never shrinks,
  a reader under a gas cap (a fee calculator under `CALC_GAS_STIPEND`, an observer under the shared
  budget) budgets `consult` at its 255-slot cost, whatever the pool's cardinality today.
- **Limits.** It knows only what the hook's truncated tick knows: that tick moves at most
  `MAX_ABS_TICK_MOVE` (9116) per second (the clamp keys on `block.timestamp`, which several blocks
  share on Robinhood Chain) from the tick the second opened at, so a larger jump reaches the
  average over several seconds. 9116 ticks is a factor of 2.49 on the price, so a short window
  stays movable: a tick held off by `d` for `t` seconds shifts an average over `S` seconds by
  `d * t / S`. History reaches back `(cardinality - 1) * interval` seconds at least once the ring
  is full (the newest observation can be brand new), more when swaps are sparse; after a growth,
  only once the ring has filled the new slots. Ask `consult` for at most that, since anyone
  recording on schedule holds the history at exactly that reach. Nothing is recorded while nobody
  swaps, which is harmless since the price does not move then; `record` fills the gap when a
  consumer needs it.
  When swaps resume after a quiet stretch, a read reaches back to the observation taken before the
  stretch until the fresh one is `secondsAgo` old, so the average catches up within `secondsAgo`.
  The cumulative comes from `IFactoryHook.observe`, not from the `IExtensionHost` surface.

Tests: [`test/twap-observer/`](test/twap-observer/) (binding and refused configs, recording through
real swaps and `record`, `consult` against hand computations, binary search against a linear scan on
fuzzed rings that grew, ring growth at every stage of a lap, an invariant suite of random swaps,
time jumps and growths, and gas ceilings).

## Build and test

You need [Foundry](https://getfoundry.sh). Everything else comes from the submodules.

```sh
forge build
forge test
FOUNDRY_PROFILE=ci forge snapshot --check    # gas regressions, as CI runs it
```

Import paths: `kit/…` for the kit (`kit/HookGated.sol`), `frontier/…` for the hook's interfaces,
`frontier-test/…` for its test harness, `contracts/…` for this repository.

## Versioning and deployments

Each extension is tagged on its own: `twap-observer/v1.0.0`, `wth-corrector/v1.0.0`, and so on.
Deployed addresses are listed below, one line per extension and chain. Deploy scripts live in
[`script/`](script/) and pick the chain's `BCTokenFactory` by chain id.

| Extension | Chain | Address | Tag |
|---|---|---|---|
| `TwapObserver` | Robinhood Chain (4663) | [`0xC2f8516564D25F76f6E838A1798682D6B9EEc158`](https://robinscan.io/address/0xC2f8516564D25F76f6E838A1798682D6B9EEc158) | `twap-observer/v1.0.0` |
| `TwapObserver` | Arbitrum Sepolia (421614) | [`0xdFDc85f355bB593b9092aa308AA2A8b12a455F6e`](https://sepolia.arbiscan.io/address/0xdFDc85f355bB593b9092aa308AA2A8b12a455F6e) | `twap-observer/v1.0.0` |

Both are verified on Sourcify.

## License

MIT (`LICENSE`).
