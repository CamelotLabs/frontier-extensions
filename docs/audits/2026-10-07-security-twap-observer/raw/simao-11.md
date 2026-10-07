FINDING | contract: WthCorrector | function: _payout | bug_class: lp-share-redirect-by-swapper-state | group_key: WthCorrector | _payout | lp-share-redirect-by-swapper-state
root_cause: At L349-351, `_payout` sets `lpAmount = 0` when `POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0`, sending the whole LP share to the fee recipient. It should skip or revert the correction. The synced currency is state the swapper's own router sets, so the swapper picks the owner of the LP share. Breaks README "LPs never under 25 %".
internal_pre: Pool binds WthCorrector both roles with `lpShareBps` >= 2500 (e.g. 5000). Executor set, finds a profitable correction.
external_pre: None. A router that calls `poolManager.sync(token)` on any ERC-20 before it swaps, and `sync(address(0))` or `settle()` after. `test_payout_pendingSync_paysTheLpShareToTheRecipient` with `PresyncRouterMock` shows the mechanic.
path:
  1. Creator C is `getFeeRecipient()`, launches with `lpShareBps = 5000`.
  2. C's router: in `unlockCallback`, `sync(WETH)`, swap 10 ETH into the coin on the Frontier pool, `sync(address(0))`, `settle{value: 10 ether}`, `take`. C uses it directly or as the default route on C's frontend.
  3. Hook calls `onAfterSwap`; executor back-runs and pays 1 WETH; digest passes (synced currency unchanged across the call).
  4. `_payout`: `exttload(CURRENCY_SLOT)` returns WETH, `lpAmount` 0, `_pay(recipient, 1 ether)` sends the full 1 WETH to C.
  5. Without presync: 0.5 WETH donated to in-range LPs, 0.5 to C. C repeats on every swap it routes.
impact: In-range LPs lose `lpShareBps` (>= 25%, 50% here) of every correction a presync swap triggers; the fee recipient collects it for one extra `sync`. Any swapper can also move this value from LPs to the recipient at no cost.
mitigation: In `onAfterSwap`, return before `_openWindow` when `POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0`, and remove the synced-currency term from the `lpAmount = 0` condition.

LEAD | contract: WthCorrector | function: _payout | bug_class: lp-share-redirect-zero-liquidity | group_key: WthCorrector | _payout | lp-share-redirect-zero-liquidity
smell: Sibling on L349-351: when `getLiquidity(poolId) == 0` at the executor's final price, the whole LP share goes to the fee recipient. The executor picks that price; the tests treat it as hostile; it could collude with the creator.
unverified: Whether a graduated Frontier pool can hold a price with no in-range liquidity. If the liquidity manager seeds a full-range position at graduation, it cannot occur.
description: If graduated pools can have liquidity gaps, a colluding executor can end each correction inside a gap and send the LPs' minimum 25% to the recipient. Reverting the correction instead of falling back would close this path.

Functions opened: 45; lifecycles closed: 8
