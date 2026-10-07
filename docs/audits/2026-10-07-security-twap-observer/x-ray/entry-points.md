# Entry Point Map

> Frontier Extensions | `da5dce3` (`feat/twap-observer`) | 10 entry points | 3 permissionless | 2 role-gated | 2 admin-only | 3 initialization

View functions are not entry points. They are listed at the end for reference, because `quoteFee` and
`consult` are read by other contracts inside swaps.

---

## Protocol Flow Paths

### Setup (deploy, then the coin creator inside the pool deploy)

`WthCorrector constructor(factory, poolManager, weth, minCorrectionGas, minPaymentWei)` → `setExecutor()` (factory owner)

`TwapObserver constructor(factory)` (no admin setup)

Coin launch: `FactoryHook.registerPool()` (out of scope) ◄── the extension is in the creator's hook config
  ├─→ `WthCorrector.onRegisterCalculator()` ◄── listed last in `feeCalculators`
  ├─→ `WthCorrector.onRegisterObserver()` ◄── listed last in `observers`, same config
  └─→ `TwapObserver.onRegisterObserver()` ◄── empty config or `(interval, cardinality)`

### Swap path (Swapper, through the PoolManager and the hook)

`[setup above]` → [coin graduates, `isLPd()` true] → `PoolManager.swap()` → `FactoryHook._afterSwap()` → `_settleSwapTail()`
  ├─→ `TwapObserver.onAfterSwap()` ◄── `interval` passed since the newest observation
  └─→ `WthCorrector.onAfterSwap()` ◄── executor set, not nested, `gasleft() >= MIN_CORRECTION_GAS`
        └─→ `executor.executeArbitrage()` → executor legs → `FactoryHook` → `WthCorrector.quoteFee()` (floor fee in band)
              └─→ `WthCorrector.receive()` ◄── lock set → `_payout()` → `PoolManager.settle()` + `donate()`, `WETH.transfer()`

### Open TWAP path (anyone)

`[TwapObserver bind above]` → `record()` ◄── pool graduated, `interval` passed
`[TwapObserver bind above]` → `increaseCardinality()` → [ring writes its last slot] → growth applies in `_record()`
`[at least one recording]` → `consult()` ◄── an observation at least `secondsAgo` old exists

### Admin (factory owner)

`setExecutor(address(0))` pauses corrections on every bound pool. `recoverERC20()` ◄── no correction in progress

---

## Permissionless

### `TwapObserver.increaseCardinality(PoolId poolId, uint16 cardinalityNext)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | `poolId` (user-controlled), `cardinalityNext` (user-controlled, bounded by `G-11`) |
| Call chain | `→ TwapObserver.increaseCardinality()` (no external call) |
| State modified | `_rings[poolId][previous .. cardinalityNext - 1]` (placeholder `timestamp = 1`), `_pools[poolId].cardinalityNext` |
| Value flow | None (caller pays gas, about 22.7k per slot per README) |
| Reentrancy guard | no (no external call) |

### `TwapObserver.record(PoolId poolId)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | `poolId` (user-controlled) |
| Call chain | `→ TwapObserver._due() → FactoryHook.poolCoin() → BCToken.isLPd() → TwapObserver._record() → FactoryHook.observe()` |
| State modified | `_rings[poolId][slot]`, `_pools[poolId]` (`newest`, `count`, `lastTimestamp`, maybe `cardinality`) |
| Value flow | None |
| Reentrancy guard | no (calls go to the pinned hook and the coin only) |

### `WthCorrector.receive()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable |
| Caller | Anyone, but only while `LOCK_TSLOT` is set (inside `onAfterSwap`): in practice the executor, WETH unwrap, or code the executor calls |
| Parameters | `msg.value` (user-controlled) |
| Call chain | `→ WthCorrector.receive()` |
| State modified | None (ETH balance only) |
| Value flow | sender → WthCorrector (counted as payment in `_correct`) |
| Reentrancy guard | transient lock is the gate itself |

---

## Role-Gated

### Pool hook (`hookOf[poolId]` / `_pools[poolId].hook`)

### `WthCorrector.onAfterSwap(PoolId poolId, BalanceDelta delta, uint24, uint256, bytes calldata)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | The pinned hook of `poolId` (`_checkPoolHook`, :388), under the hook's shared 600k observer budget, revert ignored |
| Parameters | `poolId` (protocol-derived), `delta` (protocol-derived, user's swap delta), others unused |
| Call chain | `→ WthCorrector._openWindow() → PoolManager.getSlot0() → FactoryHook.getPoolState()` (raw prefix) `→ WthCorrector._correct() → PoolManager.exttload() → WETH.balanceOf() → executor.executeArbitrage() → WthCorrector._payout() → BCToken.getFeeRecipient() → PoolManager.getLiquidity()/exttload() → WETH.withdraw() → PoolManager.settle() → PoolManager.donate() → WETH.deposit() → WETH.transfer()` |
| State modified | Transient only: `LOCK`, `WINDOW`, `LOWER`, `UPPER`, `DIRECTION` |
| Value flow | executor → WthCorrector (WETH/ETH) → PoolManager donate (LP share, ETH) and fee recipient (WETH) |
| Reentrancy guard | transient self-lock `LOCK_TSLOT`; nested notifications return at :177 |

### `TwapObserver.onAfterSwap(PoolId poolId, BalanceDelta, uint24, uint256, bytes calldata)`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | The pinned hook of `poolId` (`_pools[poolId].hook`, :105), revert ignored by the hook |
| Parameters | `poolId` (protocol-derived), others unused |
| Call chain | `→ TwapObserver._due() → TwapObserver._record() → FactoryHook.observe()` |
| State modified | `_rings[poolId][slot]`, `_pools[poolId]` when due |
| Value flow | None |
| Reentrancy guard | no (only call is the view `observe` on the caller) |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| WthCorrector | `setExecutor(address newExecutor)` | `newExecutor` (any, zero pauses) | `executor`. Instant, no timelock, affects every bound pool. Gate: `BCTokenFactory.owner()` read live at :134 |
| WthCorrector | `recoverERC20(address token, address to, uint256 amount)` | `token`, `to` (non-zero), `amount` | ERC-20 balance of the corrector. Refused while `LOCK_TSLOT` is set. Gate: `BCTokenFactory.owner()` at :141 |

---

## Initialization

One-time binding calls, made by the hook inside the pool's deploy transaction (`FactoryHook.registerPool`,
out of scope, under its `REGISTER_LOCK_TSLOT`). A revert fails the whole pool deploy.

| Contract | Function | Gate | State Modified |
|----------|----------|------|----------------|
| TwapObserver | `onRegisterObserver(PoolId poolId, bytes config)` | `_registerPool`: caller must be `liquidityManager().hook()` (`HookGated.sol:57`); once per pool (`G-1`) | `hookOf[poolId]`, `_pools[poolId]` (hook, interval, cardinality, cardinalityNext) |
| WthCorrector | `onRegisterCalculator(PoolId poolId, bytes config)` | first role: `_registerPool` (current hook); second role: pinned hook (`:212`); once per role (`G-30`) | `hookOf[poolId]`, `_bindings[poolId]` (coin, tickSpacing, lpShareBps, roles bit 1) |
| WthCorrector | `onRegisterObserver(PoolId poolId, bytes config)` | same as above | `_bindings[poolId]` (roles bit 2) |

Constructors: `TwapObserver(factory)` has no checks. `WthCorrector(...)` checks zero addresses (`G-19`) and gates (`G-20`). No proxy, no initializer.

---

## Views Read Inside Swaps (reference)

| Contract | Function | Caller | Note |
|----------|----------|--------|------|
| WthCorrector | `quoteFee(...)` | Hook fee chain, staticcall under `CALC_GAS_STIPEND` (50k) | Returns 0 inside the window for in-band opposite exact-input legs, else `previousFee` |
| WthCorrector | `onFeeChange`, `currentBand`, `bindingOf` | Hook / anyone | `onFeeChange` reverts unless the pinned hook calls |
| TwapObserver | `consult(poolId, secondsAgo)` | Any contract, for example a fee calculator | Binary search over up to 255 slots plus one `observe` call |
| TwapObserver | `poolState`, `observationAt`, `latestObservation`, `onFeeChange` | Anyone / hook | Ring inspection |
