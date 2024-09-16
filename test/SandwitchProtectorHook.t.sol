// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {SandwitchProtectorHook} from "../src/SandwitchProtectorHook.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import './TestHelpers.sol';

contract SandwitchProtectorHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    SandwitchProtectorHook hook;
    PoolId id;
    uint24 private baseFee = 100; // using lowest UniswapV3 tier fee for simplicity

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_DONATE_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG
            )
        );
        deployCodeTo("SandwitchProtectorHook.sol", abi.encode(manager, baseFee), hookAddress);
        hook = SandwitchProtectorHook(hookAddress);

        (key, id) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
    }

    function test_no_sandwich_default_behavior(bool zeroForOne) public {
        uint256 amountIn = 100e18;

        IPoolManager.ModifyLiquidityParams memory params = LIQUIDITY_PARAMS;
        params.liquidityDelta = 1e8 * 1e18;
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        assertEq(uint256(hook.currentFeeForTrade(id, true)), uint256(baseFee));
        assertEq(uint256(hook.currentFeeForTrade(id, false)), uint256(baseFee));

        (uint256 tokensSold, uint256 tokensBought) = makeSwap(zeroForOne, -int256(amountIn));

        assertEq(tokensSold, amountIn);
        assertApproxEqAbs(tokensBought, amountIn * 9999 / 10000, 1e16);
    }

    function test_normal_distribution_pool_zero_for_one_amount_in() public {
        test_normal_distribution_pool_amount_in(true);
    }

    function test_normal_distribution_pool_one_for_zero_amount_in() public {
        test_normal_distribution_pool_amount_in(false);
    }

    function test_normal_distribution_pool_zero_for_one_amount_out() public {
        test_normal_distribution_pool_amount_out(true);
    }

    function test_normal_distribution_pool_one_for_zero_amount_out() public {
        test_normal_distribution_pool_amount_out(false);
    }


    function test_sandwich_unprofitable_three_deposits() public {
        int256 liquidityToAdd = 1e5 * 1e18;

        IPoolManager.ModifyLiquidityParams memory params = LIQUIDITY_PARAMS;
        params.liquidityDelta = liquidityToAdd;
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);

        uint256 goodRateLiquidityBalance0 = key.currency0.balanceOf(address(manager));

        uint256 amountIn = goodRateLiquidityBalance0 / 100;

        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower: params.tickLower * 100, tickUpper: params.tickLower,liquidityDelta: params.liquidityDelta / 1000, salt: bytes32(uint256(1))}), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower: params.tickUpper, tickUpper: params.tickUpper * 100,liquidityDelta: params.liquidityDelta / 1000, salt: bytes32(uint256(2))}), ZERO_BYTES);

        //     bad rate     good rate      bad rate
        // [--------------][=========][-----------------]

        // sanwitcher buys all the good rate liquidity, pushing the price to the bad rate
        (uint256 tokensSoldSanwitcher, uint256 tokensBoughtSandwitcher) = makeSwap(true, -int256(goodRateLiquidityBalance0));
        // victim makes a swap from the new price, suffers from the price movement
        makeSwap(true, -int256(amountIn));
        // sanwitcher makes a swap in the opposite direction to profit from the price movement, using amount of tokens he bought previously
        (, uint256 tokensBoughtSandwitcherAfterSwap) = makeSwap(false, -int256(tokensBoughtSandwitcher));
        assertLt(tokensBoughtSandwitcherAfterSwap, tokensSoldSanwitcher); // sanwitcher should not profit
    }

    function test_fuzzy_sandwich_unprofitable(TestParams[] memory liquidityWithinPool, uint8 percentageOfTotalLiquidity) public {
        vm.assume(liquidityWithinPool.length > 1);
        vm.assume(percentageOfTotalLiquidity > 0);
        vm.assume(percentageOfTotalLiquidity < 80); // 80% of the entire pool is already a huge investment

        bool zeroForOneVictimSwap = true; // currencies are symmetrical, so withouth loss of generality we can assume that currency0 is the one that is being sold

        for (uint i = 0; i < liquidityWithinPool.length; i++) {
            TestParams memory testParam = liquidityWithinPool[i];
            int24 tickRange = int24(uint24(bound(testParam.tickRangeInSpacings, 1, 100))) * key.tickSpacing;
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -tickRange, 
                tickUpper: tickRange,
                liquidityDelta: int256(bound(uint256(testParam.liquidityRelativeParam), 1, 255) * 1e18),
                salt: bytes32(uint256(i))
            });

            modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
        }

        uint256 totalPoolLiquidity = key.currency0.balanceOf(address(manager));
        uint256 amountInSandwitcher = totalPoolLiquidity * percentageOfTotalLiquidity / 100;
        uint256 amountIn = amountInSandwitcher / 100;

        // sanwitcher makes a swap in the same direction as user to move the price
        (uint256 tokensSoldSanwitcher, uint256 tokensBoughtSandwitcher) = makeSwap(zeroForOneVictimSwap, -int256(amountInSandwitcher));
        // victim makes a swap from the new price, suffers from the price movement
        makeSwap(zeroForOneVictimSwap, -int256(amountIn));
        // sanwitcher makes a swap in the opposite direction to profit from the price movement, using amount of tokens he bought previously
        (, uint256 tokensBoughtSandwitcherAfterSwap) = makeSwap(!zeroForOneVictimSwap, -int256(tokensBoughtSandwitcher));
        assertLt(tokensBoughtSandwitcherAfterSwap, tokensSoldSanwitcher); // sanwitcher should not profit
    }

    function test_normal_distribution_pool_amount_in(bool zeroForOneVictimSwap) private {
        uint256 percentageOfTotalLiquidity = 25;

        IPoolManager.ModifyLiquidityParams[132] memory distribution = TestHelpers.getNormallyDistributedTicks();
        for (uint i = 0; i < distribution.length; i++) {
            modifyLiquidityRouter.modifyLiquidity(key, distribution[i], ZERO_BYTES);
        }

        uint256 totalPoolLiquidity = key.currency0.balanceOf(address(manager));

        uint256 amountInSandwitcher = totalPoolLiquidity * percentageOfTotalLiquidity / 100;

        uint256 amountIn = amountInSandwitcher / 100;
        // sanwitcher makes a swap in the same direction as user to move the price
        (uint256 tokensSoldSanwitcher, uint256 tokensBoughtSandwitcher) = makeSwap(zeroForOneVictimSwap, -int256(amountInSandwitcher));
        // victim makes a swap from the new price, suffers from the price movement
        makeSwap(zeroForOneVictimSwap, -int256(amountIn));
        // sanwitcher makes a swap in the opposite direction to profit from the price movement, using amount of tokens he bought previously
        (, uint256 tokensBoughtSandwitcherAfterSwap) = makeSwap(!zeroForOneVictimSwap, -int256(tokensBoughtSandwitcher));
        assertLt(tokensBoughtSandwitcherAfterSwap, tokensSoldSanwitcher); // sanwitcher should not profit
    }

    function test_normal_distribution_pool_amount_out(bool zeroForOneVictimSwap) private {
        uint256 percentageOfTotalLiquidity = 25;

        IPoolManager.ModifyLiquidityParams[132] memory distribution = TestHelpers.getNormallyDistributedTicks();
        for (uint i = 0; i < distribution.length; i++) {
            modifyLiquidityRouter.modifyLiquidity(key, distribution[i], ZERO_BYTES);
        }

        uint256 totalPoolLiquidity = key.currency0.balanceOf(address(manager));

        uint256 amountOutSandwitcher = totalPoolLiquidity * percentageOfTotalLiquidity / 100;

        uint256 amountOut = amountOutSandwitcher / 100;
        // sanwitcher makes a swap in the same direction as user to move the price
        (uint256 tokensSoldSanwitcher, uint256 tokensBoughtSandwitcher) = makeSwap(zeroForOneVictimSwap, int256(amountOutSandwitcher));
        // victim makes a swap from the new price, suffers from the price movement
        makeSwap(zeroForOneVictimSwap, int256(amountOut));
        // sanwitcher makes a swap in the opposite direction to profit from the price movement, using amount of tokens he bought previously
        (uint256 tokensSoldSandwitcherAfterSwap, ) = makeSwap(!zeroForOneVictimSwap, int256(tokensSoldSanwitcher));
        assertGt(tokensSoldSandwitcherAfterSwap, tokensBoughtSandwitcher); // sanwitcher should not profit
    }

    function makeSwap(bool zeroForOne, int256 amountSpecified) private returns (uint256 tokensSold, uint256 tokensBought) {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint balanceOfTokenABefore = key.currency0.balanceOfSelf();
        uint balanceOfTokenBBefore = key.currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );
        uint balanceOfTokenAAfter = key.currency0.balanceOfSelf();
        uint balanceOfTokenBAfter = key.currency1.balanceOfSelf();
        return zeroForOne
            ? (balanceOfTokenABefore - balanceOfTokenAAfter, balanceOfTokenBAfter - balanceOfTokenBBefore)
            : (balanceOfTokenBBefore - balanceOfTokenBAfter, balanceOfTokenAAfter - balanceOfTokenABefore);
    }

    struct TestParams {
        uint8 tickRangeInSpacings;
        uint8 liquidityRelativeParam;
    }
}
