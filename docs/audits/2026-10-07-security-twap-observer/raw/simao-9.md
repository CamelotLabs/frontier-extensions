FINDING | contract: WthCorrector | function: _correct | bug_class: incomplete-delta-digest-swap-dos | group_key: WthCorrector | _correct | incomplete-delta-digest-swap-dos
root_cause: L246 (`if (_deltaDigest(msg.sender, binding.coin) != digest) revert DeltaSnapshotChanged();`) checks only the nonzero delta count, the hook's deltas, the corrector's deltas and the synced currency (`_deltaDigest`, L322-331). It never checks the deltas of other parties (the swapper's router, or any address the executor controls). A pair of delta changes that keeps the count the same passes: the executor turns one of its own deltas zero to nonzero and one of the router's open debts nonzero to zero with `settleFor`.
internal_pre: The owner-set executor is hostile, compromised or faulty (README and hostile-executor tests treat this as in scope). The pool binds the corrector both roles.
external_pre: The user's swap reaches the Frontier pool when the swapper's unlock already has an open debt (any multi-hop route where the Frontier pool is not the first hop: coin -> ETH elsewhere -> coin here, or USDC -> ETH -> coin). Single-hop is safe (PoC confirms).
path:
  1. Owner sets executor E; E is or becomes hostile.
  2. User two-hop swap via router R: hop 1 sells coin on a plain ETH/coin pool (R owes D coin); hop 2 buys coin with the ETH credit on the Frontier pool.
  3. Hop 2's `afterSwap` notifies the corrector; `onAfterSwap` calls `E.executeArbitrage`.
  4. E `take(coin, E, D)` (count +1), `sync(coin)`, transfers D coin, `settleFor(R)` (R's delta -D to 0, count -1). Synced currency resets to zero.
  5. E sends 1e12 wei native ETH (MIN_PAYMENT_WEI). Digest unchanged; `CorrectionSettled(received 1e12, lp 3e11, recipient 7e11)`.
  6. R reads live deltas (Universal Router SETTLE_ALL/TAKE_ALL style), pays 0 coin, takes output. Unlock ends with E at -D: `CurrencyNotSettled()`, whole tx reverts. E pays nothing, needs no capital.
  PoC (passes, forge 1.7.1): scratchpad/work/simao-9/test/poc/DigestShuffle.t.sol `test_hostileExecutor_passesDigest_revertsTwoHopSwap` (expects CurrencyNotSettled; trace shows CorrectionSettled before the revert). Controls `test_control_honestExecutor_twoHopCompletes` and `test_singleHop_hostileExecutorFindsNoDebt` pass.
impact: The executor can revert, selectively and at no cost, any swap into a bound pool that is not the first action of its unlock (multi-hop and aggregator routes), e.g. every sell. Holders routing through more than one hop cannot exit; LPs and the recipient lose that volume, until `setExecutor(address(0))`. Breaks "the user's swap always completes" (x-ray I-23). No theft (PM conservation holds).
mitigation: Have the hook forward the swap `sender` to observers and add the sender's ETH and coin delta slots to `_deltaDigest`; and drop "the user's swap always completes" from the README for unlocks carrying other open debts, naming `setExecutor(address(0))` as the response.

LEAD | contract: WthCorrector | function: quoteFee | bug_class: floor-fee-not-bound-to-executor | group_key: WthCorrector | quoteFee | floor-fee-not-bound-to-executor
smell: `quoteFee` (L159-171) returns 0 for any exact-input opposite in-band swap while the window is open; it never checks the executor is the swapper. Any code inside `executeArbitrage` (third-party V4 hook on a venue the executor routes through, a token or venue callback) gets protocol-floor pricing.
unverified: Whether the partner executor routes through a venue handing control to outside code, and whether that party can take the leg and still let the correction pass MIN_PAYMENT_WEI and the digest. The fee-calculator interface gives no swapper address.
description: The x-ray (I-24) already names the missing swapper identity. The concrete path needs the executor to call untrusted code while the window is open.

LEAD | contract: WthCorrector | function: _payout | bug_class: executor-jit-recaptures-lp-share | group_key: WthCorrector | _payout | executor-jit-recaptures-lp-share
smell: `_payout` (L346-360) donates `lpShareBps` of the executor's payment to liquidity in range at payout time. The executor can add a large in-range position inside `executeArbitrage`, settle it so the digest holds, take most of the donation, remove next tx. `test_lpShare_followsInRangeLiquidity` asserts >95% capture.
unverified: Whether the team accepts this; one-block price exposure of the JIT position not measured.
description: The executor can take back up to all of the documented minimum 25% LP share of its own payment, so passive LPs receive less than the README promises ("LPs never under 25 %").

Functions opened: 41; lifecycles closed: 8
