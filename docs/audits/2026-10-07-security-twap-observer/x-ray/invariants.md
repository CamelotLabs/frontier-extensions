# Invariant Map

> Frontier Extensions | `da5dce3` (`feat/twap-observer`) | 41 guards | 36 inferred (27 I, 6 X, 3 E) | 13 not enforced onchain

Scope: `contracts/twap-observer/TwapObserver.sol`, `contracts/wth-corrector/WthCorrector.sol`. Lines in
`lib/extension-kit/contracts/HookGated.sol` and `lib/extension-kit/lib/factory-hook/v1.1/src/` are out of scope.
They are cited only where an in-scope assumption depends on them, and are marked "(out of scope)".

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs are anchor targets from x-ray.md attack surfaces.

### TwapObserver

#### G-1
`if (_pools[poolId].hook != address(0)) revert PoolAlreadyBound(poolId);` · `TwapObserver.sol:73` · makes the binding write-once, so the interval and the ring of a pool can never be reset

#### G-2
`if (config.length != CONFIG_BYTES) revert InvalidConfig();` · `TwapObserver.sol:78` · accepts only the empty config or one 64-byte `(interval, cardinality)` pair, so a malformed config fails the pool deploy

#### G-3
`if (rawInterval < MIN_INTERVAL || rawInterval > MAX_INTERVAL) revert InvalidConfig();` · `TwapObserver.sol:80` · keeps the record cadence in [1 minute, 1 day], which also makes the `uint32` cast at :83 safe

#### G-4
`if (rawCardinality < MIN_CARDINALITY || rawCardinality > MAX_CARDINALITY) revert InvalidConfig();` · `TwapObserver.sol:81` · keeps the ring size in [2, 255], so the `uint8` cast at :84 is safe and the ring keeps at least two points

#### G-5
`if (msg.sender != state.hook) revert NotPoolHook(msg.sender);` · `TwapObserver.sol:105` · only the pinned hook of the pool can push a recording through the notification path

#### G-6
`if (!_due(state)) return;` · `TwapObserver.sol:106` · rate-limits the notification path to one recording per `interval`, so the cheap no-op path is the common one

#### G-7
`if (msg.sender != _pools[poolId].hook) revert NotPoolHook(msg.sender);` · `TwapObserver.sol:112` · rejects fee-change notifications from anything but the pinned hook

#### G-8
`if (state.hook == address(0)) revert PoolNotBound(poolId);` · `TwapObserver.sol:120` · the open `record` path works only on a pool the hook bound

#### G-9
`if (!IBCToken(IExtensionHost(state.hook).poolCoin(poolId)).isLPd()) revert PoolNotGraduated(poolId);` · `TwapObserver.sol:122` · keeps the pre-graduation oracle (not a market price) out of the ring on the open path

#### G-10
`if (state.hook == address(0)) revert PoolNotBound(poolId);` · `TwapObserver.sol:130` · ring growth applies only to a bound pool, so nobody can pre-write slots of a future pool id

#### G-11
`if (cardinalityNext <= previous || cardinalityNext > MAX_CARDINALITY)` · `TwapObserver.sol:132` · makes `cardinalityNext` strictly grow and stay under the fixed array size of 255

#### G-12
`if (state.count == 0 || secondsAgo > block.timestamp) revert NotEnoughHistory(poolId, secondsAgo);` · `TwapObserver.sol:155` · `consult` never reads an empty ring and never computes a negative target

#### G-13
`if (average < type(int24).min || average > type(int24).max) revert AverageTickOutOfRange(average);` · `TwapObserver.sol:169` · makes the `int24` cast of the average safe whatever the hook returns

#### G-14
`if (index >= state.count) revert ObservationOutOfRange(poolId, index);` · `TwapObserver.sol:183` · `observationAt` never exposes a placeholder or an unwritten slot

#### G-15
`if (block.timestamp > type(uint32).max) revert TimestampOverflow();` · `TwapObserver.sol:199` · stops recordings instead of a silent wrap of the stored timestamp

#### G-16
`if (state.newest == state.cardinality - 1 && state.cardinalityNext > state.cardinality)` · `TwapObserver.sol:209` · applies a pending growth only when ring order and slot order coincide, so no kept observation is reordered

#### G-17
`if (oldest.timestamp > target) revert NotEnoughHistory(poolId, secondsAgo);` · `TwapObserver.sol:245` · `consult` refuses a window that reaches before the oldest kept observation

#### G-18
`if (msg.sender != current) revert NotCurrentHook(msg.sender);` · `HookGated.sol:57` (out of scope) · only the hook that the liquidity manager names now can register a pool, so predictable pool ids cannot be claimed early

### WthCorrector

#### G-19
`if (factory == address(0) || address(poolManager) == address(0) || weth == address(0))` · `WthCorrector.sol:117` · the immutables that every correction uses cannot be zero

#### G-20
`if (minCorrectionGas <= TAIL_RESERVE || minPaymentWei == 0) revert InvalidGates();` · `WthCorrector.sol:120` · a correction always starts with more gas than the tail reserve, and a zero payment never settles

#### G-21
`if (_tload(LOCK_TSLOT) == 0) revert EthNotAccepted();` · `WthCorrector.sol:129` · native ETH enters through `receive` only during a correction, so the counted ETH delta is the payment

#### G-22
`if (msg.sender != IBCTokenFactory(BC_TOKEN_FACTORY).owner()) revert OnlyFactoryOwner();` · `WthCorrector.sol:134` · only the protocol admin can change or pause the executor

#### G-23
`if (msg.sender != IBCTokenFactory(BC_TOKEN_FACTORY).owner()) revert OnlyFactoryOwner();` · `WthCorrector.sol:141` · only the protocol admin can move tokens the corrector holds

#### G-24
`if (_tload(LOCK_TSLOT) != 0) revert CorrectionInProgress();` · `WthCorrector.sol:143` · token recovery cannot run inside a correction and change the WETH balance that `_correct` measures

#### G-25
`if (_tload(WINDOW_TSLOT) != uint256(PoolId.unwrap(poolId)) || executor == address(0))` · `WthCorrector.sol:164` · the discount applies only to the pool whose correction window is open, and never while corrections are paused

#### G-26
`if (params.amountSpecified >= 0 || params.zeroForOne == (_tload(DIRECTION_TSLOT) != 0)) return previousFee;` · `WthCorrector.sol:167` · only exact-input legs opposite to the user's swap can get the discount

#### G-27
`if (limit <= _tload(LOWER_TSLOT) || limit >= _tload(UPPER_TSLOT)) return previousFee;` · `WthCorrector.sol:169` · the discounted leg must stop at a price strictly inside the band the user's swap opened

#### G-28
`if (target == address(0) || _tload(LOCK_TSLOT) != 0 || gasleft() < MIN_CORRECTION_GAS) return;` · `WthCorrector.sol:177` · skips the correction when paused, when nested inside a correction, or when gas is short

#### G-29
`if (received < MIN_PAYMENT_WEI) revert PaymentTooLow(received);` · `WthCorrector.sol:183` · an unpaid or underpaid correction unwinds all executor legs with it

#### G-30
`if (binding.roles & role != 0) revert RoleAlreadyBound();` · `WthCorrector.sol:215` · each role binds once per pool

#### G-31
`if (lpShareBps < MIN_LP_SHARE_BPS || lpShareBps > MAX_BPS) revert InvalidShares();` · `WthCorrector.sol:218` · the creator cannot set the LP share under 25 % or over 100 %

#### G-32
`if (binding.roles != 0 && binding.lpShareBps != lpShareBps) revert InvalidPoolConfig();` · `WthCorrector.sol:219` · both role configs must carry the same LP share

#### G-33
`if (coin == address(0) || PoolId.unwrap(_poolKey(coin, tickSpacing, hook).toId()) != PoolId.unwrap(poolId))` · `WthCorrector.sol:221` · the stored coin and tick spacing must rebuild the exact pool key, which fixes the key that `donate` and the executor receive

#### G-34
`if (coinWord != uint256(uint160(coin)) || registeredWord != 1) revert PoolStateUnavailable();` · `WthCorrector.sol:225` · checks at bind time that the raw `getPoolState` prefix read matches the hook layout for words 0 and 1

#### G-35
`if (!ok) revert ExecutorCallFailed();` · `WthCorrector.sol:245` · a reverted executor call unwinds the whole correction

#### G-36
`if (_deltaDigest(msg.sender, binding.coin) != digest) revert DeltaSnapshotChanged();` · `WthCorrector.sol:246` · the executor must leave the six digested PoolManager transient slots as it found them

#### G-37
`if (lower >= upper) (lower, upper) = (0, 0);` · `WthCorrector.sol:284` · an inverted band becomes empty, so no limit can fall inside it

#### G-38
`ok := and(ok, iszero(lt(returndatasize(), size)))` · `WthCorrector.sol:312` · a short `getPoolState` answer reverts (`:317`) instead of a read of stale memory

#### G-39
`lpAmount != 0 && (POOL_MANAGER.getLiquidity(poolId) == 0 || POOL_MANAGER.exttload(CurrencyReserves.CURRENCY_SLOT) != 0)` · `WthCorrector.sol:347` · skips the donation when `donate` or a native `settle` would revert, and sends the LP share to the fee recipient

#### G-40
`if (!IWETH(WETH).transfer(to, amount)) revert TransferFailed();` · `WthCorrector.sol:372` · a refused WETH transfer unwinds the correction instead of a silent loss

#### G-41
`if (msg.sender != hookOf[poolId]) revert NotPoolHook(msg.sender);` · `WthCorrector.sol:388` · notifications and the second role bind come only from the hook pinned for the pool

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Bound` · Onchain: **Yes**

> For every bound pool, `interval` is in [60, 86400] seconds and never changes.

**Derivation**: guard-lift: `G-3` + write sites of `_pools[poolId]`: `TwapObserver.sol:87` (guarded or default 300), `:223` (writes back the same `interval` read at :104/:119), `:144` (writes `cardinalityNext` only)

**If violated**: the record cadence and the guaranteed reach `(cardinality - 1) * interval` change under consumers

---

#### I-2

`Bound` · Onchain: **Yes**

> For every bound pool, `cardinality` is in [2, 255].

**Derivation**: guard-lift: `G-4` + write sites of `cardinality`: `TwapObserver.sol:87` (guarded or default 16), `:210` (takes `cardinalityNext`, bounded by `G-11`)

**If violated**: `_slot` modulo arithmetic at :265 and the fixed 255-slot array go out of step

---

#### I-3

`Bound` · Onchain: **Yes**

> `cardinality <= cardinalityNext <= MAX_CARDINALITY`, and neither value decreases.

**Derivation**: NatSpec: `TwapObserver.sol:27` "INVARIANT: `count <= cardinality <= cardinalityNext <= MAX_CARDINALITY`; none of the three ever decreases." Confirmed by write sites: `cardinalityNext` at :87 (equals `cardinality`) and :144 (strict increase by `G-11`), `cardinality` at :210 (only when `cardinalityNext > cardinality`, by `G-16`)

**If violated**: a growth could apply backward and drop kept observations

---

#### I-4

`Bound` · Onchain: **Yes**

> `count <= cardinality`, and `count` never decreases.

**Derivation**: guard-lift: `if (state.count < state.cardinality) ++state.count;` `TwapObserver.sol:221` + write sites of `count`: :87 (zero at bind), :221 (only increment). `cardinality` never decreases (`I-3`)

**If violated**: `_slot` at :265 would compute an index that wraps into unwritten or placeholder slots

---

#### I-5

`StateMachine` · Onchain: **Yes**

> While `count < cardinality`, the oldest observation is in slot 0 and `newest == count - 1`.

**Derivation**: Δ-pair: `TwapObserver.sol:220` ↔ `TwapObserver.sol:221` (`newest` and `count` both advance by one per recording until full). A growth at :210 runs only when `newest == cardinality - 1`, which under this invariant means the ring is full

**If violated**: a growth could apply while the ring wraps, and the oldest position in `_slot` would point at the wrong slot

---

#### I-6

`Temporal` · Onchain: **Yes**

> Stored timestamps increase strictly from the oldest to the newest observation, at least `interval` apart, and `lastTimestamp` is the newest one.

**Derivation**: temporal: `block.timestamp >= uint256(state.lastTimestamp) + state.interval` `TwapObserver.sol:230`, checked at :106 and :121 before the only recording write :216, then updated at :222 (checked-then-updated). NatSpec :30-31 states the same

**If violated**: the binary search at :252-256 returns a wrong observation and `span` loses its meaning

---

#### I-7

`StateMachine` · Onchain: **Yes**

> Only the `count` positions from the oldest observation are read, and each holds a recording, never a placeholder.

**Derivation**: NatSpec: `TwapObserver.sol:28-29` "only the `count` positions from the oldest observation are read, and each holds a recording, never a placeholder." Confirmed: every read goes through `_slot(state, i)` with `i < count` (:184, :244, :254, :257) or `newest` (:190, :242). Placeholders sit only in slots >= `cardinality` until a recording overwrites them (`I-8`)

**If violated**: a timestamp of 1 enters the search and `consult` reports a span from 1970

---

#### I-8

`Bound` · Onchain: **Yes**

> `increaseCardinality` never overwrites a slot that holds a recording.

**Derivation**: guard-lift: `G-11` + write sites of `_rings[poolId]`: :141 writes slots in [`previous`, `cardinalityNext`) with `previous` = old `cardinalityNext` >= `cardinality` (`I-3`), and :216 writes slot < `cardinality` only

**If violated**: anyone could erase kept history for the price of the storage writes

---

#### I-9

`StateMachine` · Onchain: **Yes**

> The hook of a bound pool is set once and equals `hookOf[poolId]`.

**Derivation**: Δ-pair: `HookGated.sol:58` (out of scope) ↔ `TwapObserver.sol:87`, in the same call. `G-1` blocks a second bind. `:223` writes back the same `hook`

**If violated**: a different hook could push recordings for the pool

---

#### I-10

`Temporal` · Onchain: **Yes**

> `consult(poolId, secondsAgo)` returns `span >= secondsAgo` or reverts.

**Derivation**: NatSpec: `TwapObserver.sol:32` "INVARIANT: `consult(poolId, secondsAgo)` returns `span >= secondsAgo` or reverts." Confirmed: the chosen observation has `timestamp <= target = block.timestamp - secondsAgo` (:242, :245, :254), and `span = block.timestamp - past.timestamp` (:163)

**If violated**: a consumer reads an average over a shorter window than it asked for

---

#### I-11

`Bound` · Onchain: **No**

> `span` exceeds `secondsAgo` by less than one recording gap.

**Derivation**: NatSpec: `ITwapObserver.sol:160-162` "`span` exceeds `secondsAgo` by less than the gap between the chosen observation and the next one (or than the age of the newest one when that is chosen)". Gap: no upper bound on that gap or on the newest observation's age. `_search` returns the newest at :242 whatever its age, and recordings stop while the pool is idle

**If violated**: a consumer that does not check `span` reads an average over a much longer window than `secondsAgo`

---

#### I-12

`Bound` · Onchain: **Yes**

> For every bound pool, `lpShareBps` is in [2500, 10000].

**Derivation**: guard-lift: `G-31` + write sites of `binding.lpShareBps`: `WthCorrector.sol:229` only

**If violated**: the LP share of a payment could be below the stated floor at the split itself

---

#### I-13

`StateMachine` · Onchain: **Yes**

> Each role bit binds once per pool, and `coin`, `tickSpacing` and `lpShareBps` are the same for both roles.

**Derivation**: edge: `roles & role == 0@L215 → roles |= role@L230`, no path clears a bit. `G-32` fixes `lpShareBps`, `G-33` fixes `coin` and `tickSpacing` through the pool id hash

**If violated**: the two roles of one pool could carry different keys or shares

---

#### I-14

`StateMachine` · Onchain: **No**

> Corrections run only on pools that bound the corrector in both roles.

**Derivation**: NatSpec: `IWthCorrector.sol:12-13` "bound on a pool as its last fee calculator and as an after-swap observer". Gap: `onAfterSwap` at `WthCorrector.sol:174-187` checks `hookOf` (`G-41`) but never reads `binding.roles`. An observer-only binding runs corrections without `quoteFee` in the fee chain

**If violated**: executor legs on that pool pay the normal fee, and the payment math differs from the documented design

---

#### I-15

`StateMachine` · Onchain: **No**

> The corrector is the last fee calculator and the last after-swap observer of each pool it serves.

**Derivation**: NatSpec: `WthCorrector.sol:35-36` "one singleton bound on a pool as its last fee calculator and as an after-swap observer". Gap: `_bind` at :209-231 does not read the hook's calculator or observer lists. The order is a creator choice at launch

**If violated**: a later calculator can reprice the discounted legs, and an earlier observer that swaps moves the band and `referenceTick` (`X-5`)

---

#### I-16

`Conservation` · Onchain: **Yes**

> For every settled correction, `lpAmount + recipientAmount == received`.

**Derivation**: Δ-pair: `WthCorrector.sol:364` ↔ `WthCorrector.sol:365` (`recipientAmount = received - lpAmount`, then paid)

**If violated**: part of each payment stays in the corrector or the payout overdraws it

---

#### I-17

`Conservation` · Onchain: **Yes**

> After a settled correction, the corrector's WETH plus ETH holdings equal its holdings before the executor call.

**Derivation**: Δ-pair: `WthCorrector.sol:355` ↔ `:356-359` (WETH unwrapped equals ETH settled) and `:358` ↔ `:362` (leftover ETH wrapped), with `:365` paying `received - lpAmount` in WETH. The two cases `nativeHeld >= lpAmount` and `nativeHeld < lpAmount` both net to zero

**If violated**: value accumulates in the corrector between transactions

---

#### I-18

`Conservation` · Onchain: **No**

> Every wei of native ETH the corrector holds can leave it.

**Derivation**: guard-lift: `G-21` + enumeration of native inflows and outflows. Outflows exist only at :359 and :362, and only for ETH counted during a correction. ETH that arrives without `receive` (a `SELFDESTRUCT` payout or a block reward) has no outflow. `recoverERC20` (:140) covers ERC-20 only. Aderyn H-2 flags the same contract

**If violated**: force-sent ETH stays in the corrector

---

#### I-19

`Temporal` · Onchain: **Yes**

> `receive` accepts ETH only while the transient lock is set, and the lock is set only inside `onAfterSwap`.

**Derivation**: edge: `LOCK@L178 = 1 → LOCK@L186 = 0`. A revert of `onAfterSwap` also reverts the transient write (EIP-1153). `G-21` reads the lock

**If violated**: stray ETH could inflate `nativeReceived` in a later correction

---

#### I-20

`Temporal` · Onchain: **Yes**

> The correction window (`WINDOW_TSLOT`) is open only for the duration of the executor call.

**Derivation**: edge: `WINDOW@L287 = poolId → WINDOW@L244 = 0`, with no check between the call at :243 and the clear at :244

**If violated**: `quoteFee` could discount swaps after the executor returns

---

#### I-21

`Bound` · Onchain: **Yes**

> Every settled correction carries a payment of at least `MIN_PAYMENT_WEI`, counted in WETH and native ETH together.

**Derivation**: guard-lift: `G-29` + the only payout call site :184 after it

**If violated**: corrections that pay dust would still run and cost the swapper gas

---

#### I-22

`Bound` · Onchain: **Yes**

> The six digested PoolManager transient slots are equal before and after the executor call.

**Derivation**: guard-lift: `G-36` + digest slots `WthCorrector.sol:323-329`: nonzero delta count, hook deltas on ETH and coin, corrector deltas on ETH and coin, synced currency

**If violated**: the hook's or the corrector's settlement would be wrong at the end of the user's unlock

---

#### I-23

`Bound` · Onchain: **No**

> The executor leaves every PoolManager delta of other parties unchanged, so the user's swap always completes.

**Derivation**: guard-lift: `G-36` + enumeration of the digest slots (`I-22`). Gap: the swapper's (router's) deltas and the executor's own per-currency deltas are not in the digest. They enter only through the nonzero delta count, which a pair of changes can keep equal

**If violated**: the outer unlock can end with an unsettled currency even though the digest check passed

---

#### I-24

`Bound` · Onchain: **No**

> A discounted leg only reverses part of the user's own price move.

**Derivation**: guard-lift: `G-26`, `G-27` + the inputs of `quoteFee` (:159-171). Gap: only the leg's price limit is checked. The leg's start price, its size and the identity of the swapper are not. Any swap that reaches the pool while the window is open (`I-20`) and meets `G-26`/`G-27` gets the floor fee

**If violated**: volume the user's swap did not cause trades at the protocol floor fee against the pool's LPs

---

#### I-25

`Bound` · Onchain: **No**

> LPs receive at least `MIN_LP_SHARE_BPS` of every payment.

**Derivation**: guard-lift: `G-31` + write sites of `lpAmount`: :346 (computed from `lpShareBps`), :351 (set to zero by `G-39` when in-range liquidity is zero or a currency is synced on the PoolManager). NatSpec `IWthCorrector.sol:27` "Share of every payment donated to the pool's LPs"

**If violated**: the fee recipient receives the full payment of that correction

---

#### I-26

`Bound` · Onchain: **Yes**

> The stored band satisfies `lower < upper`, or both are zero.

**Derivation**: guard-lift: `G-37` + write sites of `LOWER_TSLOT`/`UPPER_TSLOT`: :288-289 only

**If violated**: `G-27` could accept every limit

---

#### I-27

`Bound` · Onchain: **Yes**

> `WINDOW_TSLOT`, `LOCK_TSLOT` and the band are transient, so no correction state persists across transactions.

**Derivation**: edge: all writes go through `_tstore` (:399-403) on `bytes32` constants :71-83. `_bindings` (:227-230) and `executor` (:136) are the only persistent writes

**If violated**: a later transaction could see an open window

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

Onchain: **No**

> TwapObserver is notified on every due swap of the pools it serves.

**Caller side**: `TwapObserver.sol:103-107`: recordings on the swap path depend on the notification. `README.md` states "On every swap, if at least `interval` seconds passed ... `onAfterSwap` stores".

**Callee side**: `WthCorrector.sol:177`, `:264-268`: when listed before TwapObserver on the same pool, the corrector forwards `gasleft() - TAIL_RESERVE` to the executor out of the hook's shared 600k observer budget (`FactoryHook.sol:615-627`, `:636-643`, out of scope)

**If violated**: due recordings are skipped until the next due swap or an open `record` call

---

#### X-2

Onchain: **Yes**

> `FactoryHook.observe` returns a tick cumulative that is continuous in time, so the difference of two readings is the integral of the truncated tick between them.

**Caller side**: `TwapObserver.sol:160`, `:198`: `consult` subtracts a stored reading from the current one and divides by the elapsed seconds

**Callee side**: `FactoryHook.sol:377-382` (out of scope): the same formula `tickCumulative + truncatedTick * (now - lastSwapTimestamp)` that `_updateVolatility` accrues at `:730`. `_checkpointSwap` (`:747-763`) moves `truncatedTick` at most `MAX_ABS_TICK_MOVE` from the tick the second opened at

**If violated**: the average no longer describes the truncated tick path

---

#### X-3

Onchain: **No**

> The hook that binds a TwapObserver pool implements `IFactoryHook.observe`.

**Caller side**: `TwapObserver.sol:160`, `:198`: every recording and every `consult` call `observe`

**Callee side**: `HookGated.sol:56-58` (out of scope): the bind accepts any address that `liquidityManager().hook()` names. `observe` is not part of `IExtensionHost`. Test `test_audit_hookWithoutObserveBindsThenStaysDead` shows the bind succeeds and recording stays dead

**If violated**: a future hook generation without `observe` binds pools that can never record

---

#### X-4

Onchain: **Yes**

> `onAfterSwap` of TwapObserver runs only on graduated pools.

**Caller side**: `TwapObserver.sol:100` "Runs on graduated pools only (the hook blocks swaps before), so no graduation check here."

**Callee side**: `FactoryHook.sol:464` (out of scope): `if (!IBCToken(state.coin).isLPd()) revert NotLPd();` in `_beforeSwap`

**If violated**: pre-graduation oracle readings enter the ring

---

#### X-5

Onchain: **No**

> At `onAfterSwap` time, the hook's `referenceTick` is the pre-swap tick of the user's swap.

**Caller side**: `WthCorrector.sol:276-277`, `:294-297`: the band edge is `referenceTick` moved one tick toward the post-swap price

**Callee side**: `FactoryHook.sol:733` (out of scope): `_updateVolatility` writes `referenceTick` at every `beforeSwap`, nested swaps included. An observer listed before the corrector that swaps on the same pool rewrites it (`I-15`)

**If violated**: the band is computed from another swap's pre-swap tick

---

#### X-6

Onchain: **No**

> The raw `getPoolState` prefix read finds `referenceTick` in head word 3 for every hook generation the corrector binds.

**Caller side**: `WthCorrector.sol:301-318`: reads words 0, 1 and 3 raw, with `int24(word)` at :296 (Aderyn H-1)

**Callee side**: `IFactoryHook.sol:106-110` (out of scope) for v1.1 puts `referenceTick` fourth. The bind check `G-34` validates words 0 and 1 only

**If violated**: a hook generation with another head layout binds and the band uses the wrong word

---

## 4. Economic Invariants

#### E-1

Onchain: **Yes**

> A `consult` average over `span` seconds moves by at most `MAX_ABS_TICK_MOVE` ticks per second of manipulation, weighted by the share of `span` it lasts.

**Follows from**: `X-2` + `I-6` + `I-10`

**If violated**: a short-window TWAP is cheap to move for a few seconds of price pressure

---

#### E-2

Onchain: **No**

> The value of each correction reaches the pool's LPs and the coin's fee recipient in the share the creator bound at launch.

**Follows from**: `I-16` + `I-25` + `I-23`

**If violated**: the LP share moves to the fee recipient, or part of the value never settles

---

#### E-3

Onchain: **No**

> LPs trade at the protocol floor fee only against the executor's reversal of the user's own move.

**Follows from**: `I-24` + `I-15` + `X-5`

**If violated**: floor-fee volume against LPs exceeds what the user's swap opened
