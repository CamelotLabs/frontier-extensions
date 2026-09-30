// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";

/// @notice Test double for the partner executor: runs a scripted list of legs on the triggering
/// pool and on a plain v4 pool, pays the corrector in WETH or native ETH, and settles (or
/// deliberately leaves open) its PoolManager deltas. Every observation is recorded in transient
/// storage so the recording never distorts a gas measurement; a reverted correction rolls it back.
contract WthExecutorMock is IWthArbitrageExecutor {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    enum LimitMode {
        Explicit,
        BandLowerPlus,
        BandUpperMinus
    }

    enum PayMode {
        None,
        Weth,
        Native
    }

    struct Leg {
        bool frontier;
        bool zeroForOne;
        int256 amountSpecified;
        LimitMode limitMode;
        uint160 limitValue;
    }

    uint256 public constant REC_CALLS = 0;
    uint256 public constant REC_GAS = 1;
    uint256 public constant REC_LOWER = 2;
    uint256 public constant REC_UPPER = 3;
    uint256 public constant REC_POST_PRICE = 4;
    uint256 public constant REC_FG0_BEFORE = 5;
    uint256 public constant REC_FG0_AFTER = 6;
    uint256 public constant REC_FG1_BEFORE = 7;
    uint256 public constant REC_FG1_AFTER = 8;
    uint256 public constant REC_FEE = 9;
    uint256 public constant REC_CALLER = 10;
    uint256 public constant REC_REBATE = 11;
    uint256 public constant REC_SPLIT_CREATOR = 12;
    uint256 public constant REC_SPLIT_TRADER_BPS = 13;
    uint256 public constant REC_SPLIT_CREATOR_BPS = 14;
    uint256 public constant REC_SPLIT_TRIGGER_BPS = 15;
    uint256 public constant REC_POOL_ID = 16;
    uint256 public constant REC_LEG_GAS = 32;

    error Boom();

    IPoolManager public immutable poolManager;
    IWETH public immutable weth;
    address public immutable corrector;

    PoolKey public plainKey;
    Leg[] public legs;
    PayMode public payMode;
    uint256 public payAmount;
    bool public leaveOpen;
    bool public shouldRevert;

    constructor(IPoolManager _poolManager, IWETH _weth, address _corrector) {
        poolManager = _poolManager;
        weth = _weth;
        corrector = _corrector;
    }

    receive() external payable {}

    function setPlainKey(PoolKey calldata key) external {
        plainKey = key;
    }

    function setLegs(Leg[] calldata newLegs) external {
        delete legs;
        for (uint256 i; i < newLegs.length; ++i) {
            legs.push(newLegs[i]);
        }
    }

    function setPay(PayMode mode, uint256 amount) external {
        payMode = mode;
        payAmount = amount;
    }

    function setLeaveOpen(bool value) external {
        leaveOpen = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function rec(uint256 index) external view returns (uint256 value) {
        bytes32 slot = keccak256(abi.encode("rec", index));
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function executeArbitrage(PoolKey calldata triggeringPool, address rebateRecipient, ProfitSplit calldata split)
        external
        returns (uint256)
    {
        uint256 gasStart = gasleft();
        if (shouldRevert) revert Boom();

        _recordCall(triggeringPool.toId(), rebateRecipient, split);
        _runLegs(triggeringPool);

        if (payMode == PayMode.Native) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, corrector, payAmount);

        if (!leaveOpen) {
            _settle(CurrencyLibrary.ADDRESS_ZERO);
            _settle(triggeringPool.currency1);
        }

        if (payMode == PayMode.Weth) {
            weth.deposit{value: payAmount}();
            weth.transfer(corrector, payAmount);
        }

        _rec(REC_GAS, gasStart - gasleft());
        return payAmount;
    }

    function _recordCall(PoolId poolId, address rebateRecipient, ProfitSplit calldata split) internal {
        _rec(REC_CALLS, _get(REC_CALLS) + 1);
        _rec(REC_CALLER, uint160(msg.sender));
        _rec(REC_REBATE, uint160(rebateRecipient));
        _rec(REC_SPLIT_CREATOR, uint160(split.creator));
        _rec(REC_SPLIT_TRADER_BPS, split.traderBps);
        _rec(REC_SPLIT_CREATOR_BPS, split.creatorBps);
        _rec(REC_SPLIT_TRIGGER_BPS, split.triggerPoolBps);
        _rec(REC_POOL_ID, uint256(PoolId.unwrap(poolId)));

        (uint160 lower, uint160 upper) = IWthCorrector(corrector).currentBand(poolId);
        _rec(REC_LOWER, lower);
        _rec(REC_UPPER, upper);
        (uint160 post,,,) = poolManager.getSlot0(poolId);
        _rec(REC_POST_PRICE, post);
    }

    function _runLegs(PoolKey calldata triggeringPool) internal {
        uint256 count = legs.length;
        for (uint256 i; i < count; ++i) {
            Leg memory leg = legs[i];
            PoolKey memory key = plainKey;
            if (leg.frontier) key = triggeringPool;
            _runLeg(key, leg, i);
        }
    }

    function _runLeg(PoolKey memory key, Leg memory leg, uint256 index) internal {
        PoolId poolId = key.toId();
        uint160 limit = leg.limitValue;
        if (leg.limitMode == LimitMode.BandLowerPlus) limit += uint160(_get(REC_LOWER));
        else if (leg.limitMode == LimitMode.BandUpperMinus) limit = uint160(_get(REC_UPPER)) - limit;

        if (leg.frontier) {
            (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(poolId);
            _rec(REC_FG0_BEFORE, fg0);
            _rec(REC_FG1_BEFORE, fg1);
        }
        uint256 gasLeg = gasleft();
        poolManager.swap(
            key,
            SwapParams({zeroForOne: leg.zeroForOne, amountSpecified: leg.amountSpecified, sqrtPriceLimitX96: limit}),
            ""
        );
        _rec(REC_LEG_GAS + index, gasLeg - gasleft());
        if (leg.frontier) {
            (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthGlobals(poolId);
            _rec(REC_FG0_AFTER, fg0);
            _rec(REC_FG1_AFTER, fg1);
            _rec(REC_FEE, IFactoryHook(address(key.hooks)).getCurrentFee(poolId));
        }
    }

    /// @dev Zeroes this contract's delta on `currency` from its own holdings, or takes a credit.
    function _settle(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            if (currency.isAddressZero()) {
                poolManager.sync(currency);
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                IERC20(Currency.unwrap(currency)).transfer(address(poolManager), owed);
                poolManager.settle();
            }
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }

    function _rec(uint256 index, uint256 value) internal {
        bytes32 slot = keccak256(abi.encode("rec", index));
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _get(uint256 index) internal view returns (uint256 value) {
        bytes32 slot = keccak256(abi.encode("rec", index));
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
