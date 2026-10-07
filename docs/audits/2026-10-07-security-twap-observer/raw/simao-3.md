FINDING | contract: WthCorrector | function: _payout | bug_class: distribution-cohort-mismatch | group_key: WthCorrector | _payout | distribution-cohort-mismatch
root_cause: At WthCorrector.sol:360, `POOL_MANAGER.donate(...)` credits only the liquidity in range at the price where the executor's last leg stopped. The LP share is meant to compensate for the LP fee that `quoteFee` waives at L170, but no step pays it to the LPs whose liquidity those zero-fee legs actually used across the band. Sibling site L349: when the corrected price lands in a tick with no liquidity, the whole LP share goes to the fee recipient, even though LPs in the band supplied the liquidity.
internal_pre: The pool has at least one concentrated position inside the band that does not cover the price where the correction stops. The executor is set and pays at least MIN_PAYMENT_WEI.
external_pre: None
path:
  1. t0: Alice holds a full-range position with liquidity L. Bob holds [-1080, -120] with the same liquidity L. Pool at tick 0 (tickSpacing 60). lpShareBps = 5000.
  2. t1: A user sells ETH (zeroForOne) and moves the pool to tick -1200. `_openWindow` stores band [sqrtP(-1200), sqrtP(-1)], direction zeroForOne.
  3. Same tx: executor sends one oneForZero exact-input leg with limit at tick -60, inside the band. `quoteFee` returns 0, the leg pays the protocol floor only. The leg crosses all of Bob's range; about 42% of the liquidity it uses is Bob's.
  4. Executor pays 1 ETH. `_payout` lpAmount = 0.5 ETH donated at tick -60. Bob is out of range there: Alice gets 0.5 ETH, Bob 0.
  5. Variant: leg stops in a tick with no position in range. `getLiquidity == 0` sets lpAmount = 0, fee recipient gets the full 1 ETH.
impact: Bob gives up the LP fee on the leg that crossed his range and receives none of the compensation (pro-rata ~0.21 ETH, Alice takes it). Every LP whose range sits inside the band but not at the corrected price loses this on every correction. The executor chooses where the leg stops, so it chooses which LPs get paid.
mitigation: Stop waiving the LP fee on in-band legs (`quoteFee` returns `previousFee`) and send the whole executor payment to the fee recipient; or state that the LP share is a bonus to liquidity at the corrected price, not compensation to the band.

LEAD | contract: WthCorrector | function: _payout | bug_class: lp-share-redirect-by-presync | group_key: WthCorrector | _payout | lp-share-redirect-by-presync
smell: At L350, the LP share drops to 0 whenever any currency is synced on the PoolManager. The swapper's own router controls whether a currency is synced. A coin's fee recipient (e.g. the creator) who trades through a router that calls `sync(coin)` before the Frontier hop gets the full payment instead of (10000 - lpShareBps) of it, avoiding the 2500 bps LP floor. test_payout_pendingSync_paysTheLpShareToTheRecipient shows the redirect.
unverified: Whether the production executor can complete its legs while a currency stays synced without changing CURRENCY_SLOT. The mocks' `_settle` (sync + settle) clears the slot and would trip the digest. That test runs with no executor legs.
description: In-range LPs lose lpShareBps of every correction that the fee recipient's own presynced trades trigger, and the fee recipient keeps it.

LEAD | contract: WthCorrector | function: _correct | bug_class: jit-capture-of-donation | group_key: WthCorrector | _correct | jit-capture-of-donation
smell: Liquidity adds are open (beforeAddLiquidity is false). Inside executeArbitrage, the executor can mint a large one-spacing position at the corrected tick and settle it, digest unchanged. It then receives about the whole donation and removes the position later. test_lpShare_followsInRangeLiquidity (HostileExecutorMock Mode.Jit, multiplier 100) shows it collects >95% of lpAmount.
unverified: Whether this gives a trusted executor more than paying MIN_PAYMENT_WEI already allows, apart from making the underpayment invisible in CorrectionSettled. Tests appear to accept it as known behavior.
description: Existing in-range LPs can lose the LP share to a position added in the same correction, the same cohort-snapshot defect as the FINDING above.

Functions opened: 37; lifecycles closed: 8
