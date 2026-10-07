LEAD | contract: WthCorrector | function: _openWindow | bug_class: stale-reference-tick | group_key: WthCorrector | _openWindow | stale-reference-tick
code_smells: `_referenceTick` reads `PoolState.referenceTick` (head word 3). `_updateVolatility` (FactoryHook.sol:733) writes that word in every `beforeSwap`, and the nested swaps of an observer bound before the corrector also write it. Each such nested swap triggers its own correction, because the lock is not set yet. The legs of that correction write the word again, so the outer `onAfterSwap` reads the pre-swap tick of the last nested leg, not the pre-swap tick of the user. Trace: user oneForZero T0 to T0+100, then an earlier buyback observer zeroForOne to T0-500, then nested correction legs from T0-500 up: the outer band becomes [price(T0-499), post], far below the user's pre-swap price T0.
description: An earlier observer that swaps can move `referenceTick`, so the outer band lets zero-fee executor legs go past the user's pre-swap price. We did not confirm that a deployed observer makes such nested swaps.

LEAD | contract: WthCorrector | function: _poolStatePrefix | bug_class: hook-layout-assumption | group_key: WthCorrector | _poolStatePrefix | hook-layout-assumption
code_smells: `_bind` checks only head words 0 (`coin`) and 1 (`registered`) of the `getPoolState` return. `_referenceTick` uses head word 3 as `referenceTick` without a check. `HookGated` states that one deployment serves every hook generation, and `_registerPool` accepts whatever hook the liquidity manager names next.
description: The corrector reads word 3 of the v1.1 `PoolState` layout as the band edge, so a later hook with another field order makes it build the band from a different field. We did not see a later hook layout.

Functions opened: 51
