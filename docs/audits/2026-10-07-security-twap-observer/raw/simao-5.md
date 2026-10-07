FINDING | contract: WthCorrector | function: _deltaDigest | bug_class: incomplete-poolmanager-snapshot | group_key: WthCorrector | _deltaDigest | incomplete-poolmanager-snapshot
root_cause: At L323-330, `_deltaDigest` records `CurrencyReserves.CURRENCY_SLOT` but not `CurrencyReserves.RESERVES_OF_SLOT`. The executor can re-sync the coin after it changes the PoolManager's reserves snapshot, so the synced currency matches again and the check at L246 passes. The router's pending `settle` is then priced against reserves the executor moved.
internal_pre: The owner-set executor is hostile or compromised (README and HostileExecutorMock treat it as hostile; the digest is the only containment). The pool binds the corrector as an observer.
external_pre: The swapper uses a router that leaves the coin synced and prepaid across the Frontier hop (the repo's PresyncRouterMock pattern: sync(coin), transfer coinIn, plain-pool hop, Frontier hop, then settle()).
path:
  1. Router calls `sync(coin)`; reserves R0 = B0. Router transfers coinIn = 1,000,000e18 coin; PM balance B0 + coinIn. Router swaps coin to ETH on a plain pool and ETH to coin on the Frontier pool.
  2. Hook notifies the corrector. `_correct` takes the digest with CURRENCY_SLOT = coin and calls the executor.
  3. Executor calls `settle()` (credited balance minus R0 = coinIn), `take(coin, executor, coinIn)`, then `sync(coin)`. Reserves now B0, CURRENCY_SLOT coin again. Executor pays 1e12 wei WETH (MIN_PAYMENT_WEI).
  4. Digest unchanged. Correction settles, CorrectionSettled emitted.
  5. Router calls `settle()`, credited 0. Fixed-prepaid router (PresyncRouterMock): unlock ends CurrencyNotSettled, user tx reverts (breaks W4). A simpler executor that only calls `sync(coin)` (existing StaleSync mode) causes the same revert. If the router settles its open debt instead, it pays coinIn a second time.
  6. Verified in Foundry on the real v1.1 hook, work/simao-5/test/wth-corrector/ReservesPoC.t.sol. With PresyncRouterMock the swap reverts CurrencyNotSettled. With a router that settles its open debt, the router ends at 974,612e18 coin against 1,974,612e18 with the corrector paused, and the executor holds 1,000,000e18 coin.
impact: The executor is one global address for every bound pool. A hostile or compromised executor can take the prepaid input of every swapper whose router keeps a currency synced across the Frontier hop (here 1,000,000e18 coin for 1e12 wei paid). Against fixed-settle routers it can revert their swaps on every bound pool. An honest executor that re-syncs only to satisfy the digest also makes those routers' swaps revert.
mitigation: Add `CurrencyReserves.RESERVES_OF_SLOT` to the `_deltaDigest` slot array, so any change to the reserves snapshot reverts the correction.

LEAD | contract: WthCorrector | function: quoteFee | bug_class: window-not-bound-to-caller | group_key: WthCorrector | quoteFee | window-not-bound-to-caller
smell: The zero-fee window at L164-171 is keyed only on the transient pool id, direction, exact input and price limit; not who swaps. Every swap on the triggering pool during the executor call qualifies, including swaps by the pool's other observers, which the hook notifies again, nested, on each executor leg.
unverified: Could not find a bound observer or a contract on an executor route that sends such a swap.
description: If such a nested swap exists, the pool's LPs lose the LP fee on that swap, and the executor's payment does not cover it.

LEAD | contract: WthCorrector | function: onAfterSwap | bug_class: hook-volatility-desync | group_key: WthCorrector | onAfterSwap | hook-volatility-desync
smell: Each executor leg runs the hook's `_updateVolatility` (FactoryHook.sol:726-735). The first leg adds the user's full displacement and sets referenceTick to the post-swap tick. The next organic swap adds about delta again for the move back, so a round trip ending near the start leaves the accumulator at about 2x delta.
unverified: Fee raise and decay over DECAY_WINDOW not measured.
description: The hook and the corrector disagree on what a "price move" is, so swappers that follow a correction can pay an elevated dynamic fee for a move that the correction already undid.

Functions opened: 52; lifecycles closed: 8
