| 1 | Medium | [90] | Executor pays the router debt with settleFor and borrows it back, so the digest check in _correct passes | `WthCorrector._correct` |
| 2 | Medium | [90] | Delta digest misses executor deltas and synced reserves, so a hostile executor reverts multi-step swaps | `WthCorrector._deltaDigest` |
| 3 | Medium | [85] | Executor legs count as a new price move in the hook, so later swappers pay a higher volatility fee | `WthCorrector.onAfterSwap` |
| 4 | Medium | [80] | quoteFee gives the floor fee to any in-band swapper, so a creator-bound observer trades inside the window at 3 bps | `WthCorrector.quoteFee` |
| 6 | Medium | [75] | The LP share is donated to liquidity in range at payout, so a same-transaction position takes most of it | `WthCorrector._payout` |
| 5 | Low | [75] | The band edge reads a referenceTick that nested swaps overwrite, so the band can reach past the user's pre-swap price | `WthCorrector._openWindow` |
