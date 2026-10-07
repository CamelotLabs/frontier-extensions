FINDING | contract: WthCorrector | function: _payout | bug_class: swapper-controlled-split | group_key: WthCorrector | _payout | swapper-controlled-split
root_cause: At L350, `_payout` sets `lpAmount` to 0 whenever `POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0`. The triggering swapper controls that slot (it can `sync` in its own unlock before it swaps). No operation keeps the LP share for the LPs in this case; it is sent to `getFeeRecipient()`.
internal_pre: Pool bound with `lpShareBps` above 2500, e.g. 5000. Executor set.
external_pre: An arbitrage gap exists between the Frontier pool and the executor's other venue when the trigger tx lands, and the attacker's trigger lands first. The executor's arbitrage settles without touching the synced-currency slot (a two-pool V4 arbitrage that nets the coin and takes ETH profit, as WthExecutorMock models).
path:
  1. A third party sells coin on the plain V4 pool (or the coin price moves elsewhere). The executor can earn 1.25 ETH correcting the Frontier pool.
  2. The coin's fee recipient (creator) sends one tx from a router: inside `unlock`, `poolManager.sync(coin)`, then swaps 0.001 ETH to coin exact input on the Frontier pool (PresyncRouterMock pattern).
  3. Hook notifies WthCorrector. Executor arbitrages the gap, pays 1 ETH (8000 bps of 1.25 ETH). Digest unchanged (executor never touched CURRENCY_SLOT).
  4. `_payout` reads CURRENCY_SLOT == coin, `lpAmount = 0`. `CorrectionSettled(pid, 1 ether, 0, 1 ether)`; creator receives 1 WETH instead of 0.5.
  5. Router calls `settle()` (0 coin, slot resets), `settle{value: 0.001 ether}()`, `take(coin)`. Tx completes. `test_payout_pendingSync_paysTheLpShareToTheRecipient` shows steps 2 to 4.
impact: In-range LPs lose the LP share (25% to 100%) of every correction the fee recipient triggers; 0.5 ETH per correction in the example, taken by the creator. LPs also bore the stale-price loss the profit came from.
mitigation: When a currency is pending sync, keep the LP share in a per-pool pending amount and donate it at the next correction without a pending sync (or revert the correction).

LEAD | contract: WthCorrector | function: _payout | bug_class: jit-donation-capture | group_key: WthCorrector | _payout | jit-donation-capture
smell: `donate` at L360 pays the whole LP share, same tx, to liquidity in range where the executor stops. Anyone can add liquidity in the same unlock that triggers the correction: add a large narrow position around the executor's stop price, send a 0.001 ETH trigger, collect most of `lpShareBps * payment`, remove. Example: payment 1 ETH, lpShareBps 5000, attacker liquidity 19x passive: attacker ~0.475 ETH, passive LPs 0.025 instead of 0.5.
unverified: Net profit depends on where the executor stops relative to the attacker's range; the executor's last part trades through the attacker's position at full fee outside the band; not quantified. Front-running a victim is not practical on Robinhood Chain (FCFS, no public mempool); realistic path is self-trigger on an external gap.
description: The LP share of a correction is a one-time same-transaction donation to whoever is in range at that moment, so a same-transaction JIT position can take most of it from the passive LPs.

LEAD | contract: WthCorrector | function: quoteFee | bug_class: unbound-zero-fee-window | group_key: WthCorrector | quoteFee | unbound-zero-fee-window
smell: `quoteFee` returns 0 at L170 for any exact-input swap on the window's pool opposite to the user with a limit inside the band; never checks who swaps (IFeeCalculator passes no sender). If the executor routes a leg through a venue a third party controls (e.g. an ETH/coin V4 pool with an attacker hook), that hook can swap back across the band on the Frontier pool at the floor and net its own deltas.
unverified: Depends on how the real executor routes; the attacker's leg persists only if the executor still pays MIN_PAYMENT_WEI afterwards.
description: The zero-fee price is gated only by the transient pool window, not by the identity of the executor, so any code that the executor call reaches can take the in-band zero-fee leg from the LPs.

Functions opened: 46; lifecycles closed: 8
