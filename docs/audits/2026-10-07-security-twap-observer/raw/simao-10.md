FINDING | contract: WthCorrector | function: _payout | bug_class: same-tx-jit-donation-capture | group_key: WthCorrector | _payout | same-tx-jit-donation-capture
root_cause: L360 calls `POOL_MANAGER.donate(...)` inside the same unlock as the triggering swap. V4 `donate` pays only liquidity in range at that instant, including a position the swapper added earlier in the same unlock. FactoryHook v1.1 has `beforeAddLiquidity: false` and `beforeRemoveLiquidity: false`. The LP share is not held back or paid to the standing position.
internal_pre: Pool binds WthCorrector both roles. Executor set. Correction pays at least `MIN_PAYMENT_WEI`. No currency synced.
external_pre: None. The attacker needs a custom router and some coin for a narrow position.
path:
  1. The swapper finds the post-correction resting tick (eth_call of the swap; executor target is deterministic for the state).
  2. In one `unlock`, router `modifyLiquidity` adds a one-tickSpacing (60 ticks) position at that tick, liquidity 20x the pool's active liquidity.
  3. Same unlock, router swaps 0.3 ETH for coin, exact input. Executor pays 0.01 ETH; with `lpShareBps = 3000`, `_payout` donates 0.003 ETH.
  4. Same unlock, router removes the position, collects 0.002857 ETH of the 0.003 ETH donation (95.2%).
  5. PoC: scratchpad/work/simao-10/test/wth-corrector/SwapperJitPoC.t.sol `test_swapperJit_capturesDonation` PASS on the real v1.1 hook, subtracting a no-correction baseline: "captured by the swapper's same-tx position: 2857316425898231" of a 3000000000000000 donation.
impact: Standing LPs (by default the liquidity manager's graduation position) lose up to ~95% of the LP share of every correction a swapper with a custom router triggers, while the in-band legs already paid them a zero LP fee. Capture ratio L_jit / (L_jit + L_pool). Risk-free rebate for the swapper.
mitigation: Do not donate inside the triggering transaction: keep the LP share in the corrector and pay it to the standing LP position's fee receiver, or use a distribution a same-transaction position cannot enter.

LEAD | contract: WthCorrector | function: quoteFee | bug_class: zero-fee-window-not-sender-bound | group_key: WthCorrector | quoteFee | zero-fee-window-not-sender-bound
smell: `quoteFee` (L164-170) gives the zero LP fee to any in-band, opposite, exact-input swap while `WINDOW_TSLOT` is open; `IFeeCalculator.quoteFee` gets no sender. Every observer bound on the pool is notified again for each nested executor leg with a fresh 600k budget; only the corrector returns at its lock. A third-party hook or token callback on the executor's other venue also runs inside the window.
unverified: Whether such code can take in-band volume at zero LP fee and still leave the executor at least `MIN_PAYMENT_WEI` of profit.
description: The zero-fee band is keyed only on the pool id and the swap shape, so a creator-bound observer or a hook on the executor's secondary pool can swap in band at zero LP fee.

LEAD | contract: WthCorrector | function: _payout | bug_class: swapper-controlled-lp-share-destination | group_key: WthCorrector | _payout | swapper-controlled-lp-share-destination
smell: At L347-351, `lpAmount` becomes 0 when `CURRENCY_SLOT` is nonzero; the triggering swapper controls that slot (presync router), sending the whole payment to `getFeeRecipient()`.
unverified: That any party profits enough to do this deliberately; the fee recipient gains only on swaps it makes anyway.
description: A fee recipient that routes its own swaps through a pre-sync router takes 100 percent of each correction it triggers instead of `1 - lpShareBps`.

LEAD | contract: WthCorrector | function: _correct | bug_class: partner-executor-payment-assumption | group_key: WthCorrector | _correct | partner-executor-payment-assumption
smell: `_correct` counts only WETH and native ETH reaching the corrector during the call and ignores the executor's `profit` return value. Selector 0xd4641322 and the PoolManager transient slot constants confirmed against the live Robinhood PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951; live WETH is aeWETH (proxy 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73), `withdraw` works with `receive`.
unverified: Partner executor source not in the repo. If it pays the creator share in another token, as ERC-6909 claims, or accrues it for later, every correction reverts `PaymentTooLow` (no loss, but no payout and wasted gas per swap).
description: The payment model assumes a push payment in ETH or WETH during the call, and no deployed partner contract confirms this.

Functions opened: 49; lifecycles closed: 8
