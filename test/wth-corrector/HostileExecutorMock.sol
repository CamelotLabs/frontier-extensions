// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";
import {IWETH} from "frontier/interfaces/IWETH.sol";

import {IWthArbitrageExecutor} from "contracts/wth-corrector/IWthArbitrageExecutor.sol";
import {IWthCorrector} from "contracts/wth-corrector/IWthCorrector.sol";

/// @notice Test double for a hostile or buggy partner executor: one scripted misbehaviour per
/// `Mode`, records in storage (gas is not measured here), and a minimal router for the executor's
/// own transactions outside a correction.
contract HostileExecutorMock is IWthArbitrageExecutor, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    enum Mode {
        Idle,
        StaleSync,
        InBandSell,
        PayCoin,
        PayNative,
        RecoverDuring,
        Jit,
        BurnGasThenPay
    }

    enum Op {
        Buy,
        Sell,
        RemoveLiquidity
    }

    IPoolManager public immutable pm;
    IWETH public immutable weth;
    address public immutable corrector;

    Mode public mode;
    uint256 public payWeth;
    uint256 public coinAmount;
    uint128 public jitMultiplier;
    uint256 public sellAmount;
    uint256 public keepGas;

    uint256 public calls;
    uint256 public gasAtEntry;
    uint24 public legFee;
    uint256 public coinSold;
    uint256 public ethGot;
    uint256 public fg1Before;
    uint256 public fg1After;
    int24 public jitLower;
    int24 public jitUpper;
    uint128 public jitLiquidity;
    int128 public jitFees0;

    constructor(IPoolManager _pm, IWETH _weth, address _corrector) {
        pm = _pm;
        weth = _weth;
        corrector = _corrector;
    }

    receive() external payable {}

    function set(Mode _mode, uint256 _payWeth) external {
        mode = _mode;
        payWeth = _payWeth;
    }

    function setCoinAmount(uint256 amount) external {
        coinAmount = amount;
    }

    function setSellAmount(uint256 amount) external {
        sellAmount = amount;
    }

    function setJitMultiplier(uint128 m) external {
        jitMultiplier = m;
    }

    function setKeepGas(uint256 amount) external {
        keepGas = amount;
    }

    // ------------------------------------------------------------------ inside a correction

    function executeArbitrage(PoolKey calldata key, address, ProfitSplit calldata) external returns (uint256) {
        gasAtEntry = gasleft();
        ++calls;
        PoolId id = key.toId();

        if (mode == Mode.StaleSync) {
            pm.sync(key.currency1);
        } else if (mode == Mode.InBandSell) {
            (, uint160 upper) = IWthCorrector(corrector).currentBand(id);
            _sellLeg(key, sellAmount, upper - 1);
            _settle(key.currency0);
            _settle(key.currency1);
        } else if (mode == Mode.PayCoin) {
            IERC20(Currency.unwrap(key.currency1)).transfer(corrector, coinAmount);
        } else if (mode == Mode.RecoverDuring) {
            IWthCorrector(corrector).recoverERC20(Currency.unwrap(key.currency1), address(this), coinAmount);
        } else if (mode == Mode.PayNative) {
            (bool sent,) = corrector.call{value: payWeth}("");
            require(sent, "native refused");
            return 0;
        } else if (mode == Mode.Jit) {
            _addJit(key, id);
            _settle(key.currency0);
            _settle(key.currency1);
        } else if (mode == Mode.BurnGasThenPay) {
            while (gasleft() > keepGas) {
                assembly ("memory-safe") {
                    pop(keccak256(0, 0))
                }
            }
        }

        if (payWeth != 0) {
            weth.deposit{value: payWeth}();
            weth.transfer(corrector, payWeth);
        }
        return 0;
    }

    // ------------------------------------------------------------------ own transactions

    function buy(PoolKey memory key, uint256 ethIn) external {
        pm.unlock(abi.encode(Op.Buy, key, ethIn, uint160(0)));
    }

    function sell(PoolKey memory key, uint256 coinIn, uint160 limit) external {
        pm.unlock(abi.encode(Op.Sell, key, coinIn, limit));
    }

    function removeLiquidity(PoolKey memory key) external {
        pm.unlock(abi.encode(Op.RemoveLiquidity, key, uint256(0), uint160(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (Op op, PoolKey memory key, uint256 amount, uint160 limit) = abi.decode(data, (Op, PoolKey, uint256, uint160));
        if (op == Op.Buy) {
            pm.swap(
                key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
        } else if (op == Op.Sell) {
            _sellLeg(key, amount, limit);
        } else {
            (, BalanceDelta fees) = pm.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: jitLower,
                    tickUpper: jitUpper,
                    liquidityDelta: -int256(uint256(jitLiquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            jitFees0 = fees.amount0();
        }
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    // ------------------------------------------------------------------ internals

    /// @dev Opposite, exact-input coin leg on the Frontier pool up to `limit`; records the applied fee.
    function _sellLeg(PoolKey memory key, uint256 coinIn, uint160 limit) internal {
        PoolId id = key.toId();
        (, fg1Before) = pm.getFeeGrowthGlobals(id);
        BalanceDelta d = pm.swap(
            key, SwapParams({zeroForOne: false, amountSpecified: -int256(coinIn), sqrtPriceLimitX96: limit}), ""
        );
        (, fg1After) = pm.getFeeGrowthGlobals(id);
        coinSold = uint256(uint128(-d.amount1()));
        ethGot = uint256(uint128(d.amount0()));
        legFee = IFactoryHook(address(key.hooks)).getCurrentFee(id);
    }

    /// @dev A one-spacing-wide position around the current tick, `jitMultiplier` times the pool's
    /// active liquidity, added inside the correction.
    function _addJit(PoolKey memory key, PoolId id) internal {
        (, int24 tick,,) = pm.getSlot0(id);
        int24 spacing = key.tickSpacing;
        int24 lower = tick / spacing * spacing;
        if (tick < 0 && tick % spacing != 0) lower -= spacing;
        int24 upper = lower + spacing;
        uint128 liquidity = pm.getLiquidity(id) * jitMultiplier;

        pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        jitLower = lower;
        jitUpper = upper;
        jitLiquidity = liquidity;
    }

    /// @dev Zeroes this contract's delta on `currency` from its own holdings, or takes a credit.
    function _settle(Currency currency) internal {
        int256 delta = pm.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            pm.sync(currency);
            if (currency.isAddressZero()) {
                pm.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(pm), owed);
                pm.settle();
            }
        } else if (delta > 0) {
            pm.take(currency, address(this), uint256(delta));
        }
    }
}
