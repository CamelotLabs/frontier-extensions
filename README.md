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
  instead when the pool has none), the rest goes to the coin's `getFeeRecipient()` in WETH; the
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
  `MIN_CORRECTION_GAS` and `MIN_PAYMENT_WEI` are constructor immutables.

Tests: [`test/wth-corrector/`](test/wth-corrector/) (the corrector through real swaps on the real
hook, a scripted executor arbitraging against a plain v4 pool, a hostile executor whose every
misbehaviour must stay contained, and the `getPoolState` prefix read checked against the typed
decode); [`test/fork/`](test/fork/) checks that prefix on the live hook and simulates corrections on
a coin launched through the live factory.

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

Each extension is tagged on its own: `wth-corrector/v1.0.0`, and so on. Once an extension is
deployed, its addresses live in `deployments/<extension>/<chainId>.json`, one file per chain.
Nothing is deployed yet.

## License

MIT (`LICENSE`).
