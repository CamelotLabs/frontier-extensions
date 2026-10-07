LEAD | contract: TwapObserver | function: onRegisterObserver | bug_class: duplicate-registration-revert | group_key: TwapObserver | onRegisterObserver | duplicate-registration-revert
code_smells: `if (_pools[poolId].hook != address(0)) revert PoolAlreadyBound(poolId);` (TwapObserver.sol:73). HookGated.sol:48-52 says `_registerPool` "May run more than once for the same pool ... once per entry if the creator lists it twice. Re-pinning is safe". The hook's `_decodeAndValidateConfig` (FactoryHook.sol:286-290) does not reject a repeated observer address, and FactoryHook.sol:245-248 calls `onRegisterObserver` once per entry.
description: A creator who lists TwapObserver twice causes the second `onRegisterObserver` call to revert, so the whole coin deploy fails. Only the creator is affected; no SDK or frontend path adds a duplicate entry.

LEAD | contract: TwapObserver | function: record | bug_class: natspec-behavior-mismatch | group_key: TwapObserver | record | natspec-behavior-mismatch
code_smells: ITwapObserver NatSpec says `record` stores a reading "if at least `interval` seconds passed since its newest observation; does nothing otherwise". The code reverts `PoolNotBound` for an unbound pool (L120) and `PoolNotGraduated` for a bound, ungraduated pool (L122); that pool always has `count == 0`, so `_due` is true and every call reverts.
description: A keeper that follows the NatSpec and batches `record` calls without try/catch has the whole batch revert when one pool is unbound or ungraduated. No such keeper found in this codebase.

Functions opened: 22
