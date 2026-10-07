FINDING | contract: WthCorrector | function: _payout | bug_class: rebate-redirect-by-presync | group_key: WthCorrector | _payout | rebate-redirect-by-presync
root_cause: At WthCorrector.sol:349-351, `_payout` sets `lpAmount` to 0 and sends the full payment to `getFeeRecipient()` when `exttload(CURRENCY_SLOT) != 0`. The swapper controls that slot at no cost, because `PoolManager.sync` has no lock check and no settlement duty. Missing operation: `onAfterSwap` does not skip the correction when a currency is already synced before the executor call. The digest at L246 proves the slot cannot change during the call, so the fallback is a choice of the caller.
internal_pre: A pool binds WthCorrector in both roles with `lpShareBps` 5000. Executor set and pays at least `MIN_PAYMENT_WEI`.
external_pre: None
path:
  1. Coin creator C, who is `getFeeRecipient()`, deploys a small unlock-callback contract.
  2. In `unlockCallback`, C calls `poolManager.sync(WETH)` (~5k gas, no delta). CURRENCY_SLOT is now WETH.
  3. C swaps 1 ETH for the coin. Hook calls `onAfterSwap`. Executor runs in-band reverse legs at the protocol floor, LPs earn no LP fee on them (WthCorrectorHostile asserts `fg1After == fg1Before`). Executor pays 0.01 ETH.
  4. Digest passes (slot WETH before and after). `_payout` reads slot nonzero, `lpAmount = 0`, pays 0.01 WETH to C. Intended: 0.005 ETH to LPs, 0.005 WETH to C.
  5. C calls `poolManager.sync(address(0))` to reset, settles the 1 ETH, takes the coin. Repeats on every swap. Same move with a dust swap on a stale-priced pool sends C 100% of the executor's rebate.
impact: In-range LPs (including the liquidity manager's graduation position) lose `lpShareBps` (at least 25%) on every correction the fee recipient triggers, and still carry the zero-LP-fee legs. README "LPs never under 25 %" fails. Test `test_payout_pendingSync_paysTheLpShareToTheRecipient` shows the redirect mechanism.
mitigation: In `onAfterSwap`, return before the lock and the executor call when `POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0`.

FINDING | contract: WthCorrector | function: _payout | bug_class: jit-capture-of-lp-share | group_key: WthCorrector | _payout | jit-capture-of-lp-share
root_cause: At L360, `donate` pays the LP share to whatever liquidity is in range at that moment, inside the same transaction as the triggering swap. No operation limits the share to liquidity that existed before the triggering transaction. Liquidity is permissionless (FactoryHook `beforeAddLiquidity`/`beforeRemoveLiquidity` false), so the swapper can add before the swap and remove after, in one unlock.
internal_pre: Pool bound with `lpShareBps` 3000. Executor active. Honest in-range liquidity L in the tick-spacing range holding the post-correction price.
external_pre: None. The attacker is also the swapper; no ordering needed.
path:
  1. Trader T opens one `unlock`, adds 99L in the single tick-spacing range holding the current tick (as `HostileExecutorMock._addJit`).
  2. T swaps 10 ETH for the coin. Executor reverses the move to inside the band (within one tick of pre-swap price), pays 0.4 ETH.
  3. `_payout` donates 0.12 ETH. T's position is 99% of in-range liquidity, accrues ~0.119 ETH; honest LPs ~0.0012 ETH.
  4. Same unlock, T removes the position near its original composition, collects 0.119 ETH. `test_lpShare_followsInRangeLiquidity` shows a 100x position collects >95% of `lpAmount`.
impact: Honest in-range LPs absorb the zero-LP-fee correction legs but lose ~99% of the compensating donation on every correction a JIT-wrapped swapper triggers.
mitigation: Keep the LP share in the corrector and donate it at the next correction in a later block, so only a position in range across transactions collects it.

LEAD | contract: WthCorrector | function: _payout | bug_class: rebate-redirect-by-empty-range | group_key: WthCorrector | _payout | rebate-redirect-by-empty-range
smell: At L349, `getLiquidity(poolId) == 0` at payout sends the full payment to the fee recipient. LPs whose liquidity the zero-fee legs crossed get nothing.
unverified: Could not establish that a swapper can make the executor end inside a zero-liquidity gap; the final price is the executor's choice within (post, edge).
description: Sibling of the presync redirect: if the post-correction price can be steered into a liquidity gap, the recipient gets 100% while the crossed LPs bore the zero-fee legs.

Functions opened: 44; lifecycles closed: 8
