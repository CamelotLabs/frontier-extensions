LEAD | contract: WthCorrector | function: onAfterSwap | bug_class: gas-limit-skippable-correction | group_key: WthCorrector | onAfterSwap | gas-limit-skippable-correction
smell: At L177, `gasleft() < MIN_CORRECTION_GAS` returns without an error. FactoryHook `_notify` (FactoryHook.sol:636-644) forwards `min(budget, 63/64 of available)` and does not check that the full 600 000 observer budget is available. The swapper sets the tx gas limit, so the swapper decides whether the correction runs. The gap then goes to any external back-runner; LPs lose `lpShareBps` of the payment, the recipient the remainder.
unverified: Whether common wallet gas estimation lands on the skip path (eth_estimateGas success is not monotone here). Not shown that a deliberate skip is profitable for the swapper.
description: The LP and recipient revenue from corrections depends on a gas limit that the swapper controls, and the hook gives no guarantee of the full observer budget.

LEAD | contract: WthCorrector | function: quoteFee | bug_class: waived-lp-fee-not-bound-to-payment | group_key: WthCorrector | quoteFee | waived-lp-fee-not-bound-to-payment
smell: At L170, `quoteFee` returns 0 for every in-band, opposite, exact-input leg. The only payment check is `received >= MIN_PAYMENT_WEI` (L183). Nothing ties the payment to the waived LP fee or to the 8000 bps profit share. An executor can back-run a 100 ETH notional gap at the 3 bps floor and pay only `MIN_PAYMENT_WEI`.
unverified: Executor is an owner-set partner; no path for an untrusted actor. `test_paidBackrun_standsAtTheFloor` appears to accept this.
description: The design waives LP fees in exchange for an executor payment that the contract does not bound against the waived amount.

LEAD | contract: WthCorrector | function: _payout | bug_class: donation-jit-capture | group_key: WthCorrector | _payout | donation-jit-capture
smell: At L360, `donate` pays the LP share to the liquidity in range at that moment. The correction returns the price to within about one tick of the pre-swap tick (predictable). A swapper can add narrow liquidity at the pre-swap tick in the same unlock, swap, let the correction donate, and remove before the unlock settles.
unverified: No net profit shown; the swapper's own liquidity absorbs its own price impact and shrinks the gap and payment. A third party cannot insert itself between the user swap and the donation (same tx).
description: The LP share goes to whoever holds in-range liquidity at the moment of donation, so a party that controls the trigger can join just before the distribution.

Functions opened: 37; lifecycles closed: 8
