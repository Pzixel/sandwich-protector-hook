// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract SandwitchProtectorHook is BaseHook {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct CurrenctData {
        uint64 blockNumber;
        int128 amountSoldInBlock;
        int128 lastTradeSize;
        int256 balance;
    }

    struct PoolData {
        CurrenctData currency0Data;
        CurrenctData currency1Data;
    }

    mapping(PoolId id => PoolData) private poolDataList;

    uint24 private immutable baseFee;

    constructor(IPoolManager poolManager, uint24 _baseFee) BaseHook(poolManager) {
        baseFee = _baseFee;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: true,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolData storage poolData = poolDataList[poolKey.toId()];
        poolData.currency0Data.balance -= delta.amount0();
        poolData.currency1Data.balance -= delta.amount1();
        return (this.afterAddLiquidity.selector, delta);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolData storage poolData = poolDataList[poolKey.toId()];
        poolData.currency0Data.balance -= delta.amount0();
        poolData.currency1Data.balance -= delta.amount1();
        return (this.afterRemoveLiquidity.selector, delta);
    }

    function beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = currentFeeForTrade(poolKey.toId(), params.zeroForOne);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata poolKey, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        PoolData storage poolData = poolDataList[poolKey.toId()];
        CurrenctData storage currency0Volume = poolData.currency0Data;
        CurrenctData storage currency1Volume = poolData.currency1Data;

        if (params.zeroForOne) {
            int128 amountSold = -delta.amount0();
            if (currency0Volume.blockNumber != block.number) {
                currency0Volume.blockNumber = uint64(block.number);
                currency0Volume.amountSoldInBlock = amountSold;
            } else {
                currency0Volume.amountSoldInBlock += amountSold;
            }
            currency0Volume.lastTradeSize = amountSold;
        } else {
            int128 amountSold = -delta.amount1();
            if (currency1Volume.blockNumber != block.number) {
                currency1Volume.blockNumber = uint64(block.number);
                currency1Volume.amountSoldInBlock = amountSold;
            } else {
                currency1Volume.amountSoldInBlock += amountSold;
            }
            currency1Volume.lastTradeSize = amountSold;
        }

        currency0Volume.balance -= delta.amount0();
        currency1Volume.balance -= delta.amount1();

        return (this.afterSwap.selector, 0);
    }

    function beforeDonate(
        address,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external override returns (bytes4) {
        PoolData storage poolData = poolDataList[key.toId()];
        poolData.currency0Data.balance += int256(amount0);
        poolData.currency1Data.balance += int256(amount1);
        return this.afterDonate.selector;
    }

    function currentFeeForTrade(PoolId poolId, bool zeroForOne) public view returns (uint24) {
        PoolData storage poolData = poolDataList[poolId];

        uint256 balance0 = uint256(poolData.currency0Data.balance);
        uint256 balance1 = uint256(poolData.currency1Data.balance);

        if (zeroForOne) {
            // 1 -> 0 user
            // 0 -> 1 sandwitch

            (uint256 a0, uint256 a1) = getCurrencyVolume(poolData.currency1Data);
            (uint256 b0, ) = getCurrencyVolume(poolData.currency0Data);

            uint256 extraFee = calculateExtraFee(a0, a1, b0, balance1, balance0);
            return uint24(Math.min(extraFee + baseFee, SwapMath.MAX_FEE_PIPS));
        } else {
            // 0 -> 1 user
            // 1 -> 0 sandwitch

            (uint256 a0, uint256 a1) = getCurrencyVolume(poolData.currency0Data);
            (uint256 b0, ) = getCurrencyVolume(poolData.currency1Data);

            uint256 extraFee = calculateExtraFee(a0, a1, b0, balance0, balance1);
            return uint24(Math.min(extraFee + baseFee, SwapMath.MAX_FEE_PIPS));
        }
    }

    function calculateExtraFee(uint256 a0, uint256 a1, uint256 b0, uint256 x, uint256 y) private pure returns (uint256) {
        uint256 x0 = x - (x * b0) / (y + b0);
        uint256 w = 10**18 - (a0 * 10**18) / (x0 + a0) - (a1 * 10**10)/(x0 + a0 + a1) + (a0 * a1 * 10**18) / ((x0 + a0) * (x0 + a0 + a1));
        uint256 inputMultiplierScaled = w * (x0 + a0) / (x0 + a1);
        uint256 extraFee = (10**18 - inputMultiplierScaled) / 10**12;
        return extraFee;
    }

    function getCurrencyVolume(CurrenctData storage volume) private view returns (uint256 c0, uint256 c1) {
        if (volume.blockNumber != block.number) {
            return (0, 0);
        }
        return (uint256(int256(volume.amountSoldInBlock - volume.lastTradeSize)), uint256(int256(volume.lastTradeSize)));
    }
}
