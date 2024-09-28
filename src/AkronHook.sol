// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BaseHook} from "./base/hooks/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {UniswapV4ERC20} from "./libraries/UniswapV4ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract AkronHook is BaseHook, Ownable {
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using TransferHelper for IERC20Minimal;
    using SafeCast for uint256;
    
    /// @notice Thrown when trying to interact with a non-initialized pool
    error FeeNotDefault();
    error TickSpacingNotDefault();
    error SwapFeeBipsTooLarge();
    error MultipleZeroForOneSwapNotAllowedPerBlock();
    error MultipleOneForZeroSwapNotAllowedPerBlock();

    IPoolManager internal immutable manager;


    struct PoolState {
        uint256 zeroForOneBlockNumber;
        uint256 oneForZeroBlockNumber;
        address liquidityToken;
        uint128 swapFeeBips;
    }
    
    // poolStates[poolId] => AkronHook.PoolState
    mapping(PoolId => PoolState) public poolStates;

    constructor(address _manager) Ownable(msg.sender) {
        manager = IPoolManager(_manager);
    }

    modifier onlyManager() {
        require(msg.sender == address(manager));
        _;
    }

    /// @notice Checks default values and deploys liquidity token for full range liquidity providers
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (key.fee != 0) revert FeeNotDefault();
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();
        string memory tokenSymbol = string(
            abi.encodePacked(
                "Akron-",
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(), 
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol()
            )
        );
        poolStates[key.toId()].liquidityToken = address(new UniswapV4ERC20(tokenSymbol, tokenSymbol));
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Mints liquidity token to full range liquidity providers 
    function beforeAddLiquidity(
        address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata
    ) external override onlyManager returns (bytes4) {
        if (params.tickLower == -887220 && params.tickUpper == 887220)
            UniswapV4ERC20(poolStates[key.toId()].liquidityToken).mint(sender, uint256(params.liquidityDelta));
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Burns liquidity token from full range liquidity providers 
    function beforeRemoveLiquidity(
        address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata
    ) external override onlyManager returns (bytes4) {
        if (params.tickLower == -887220 && params.tickUpper == 887220) 
            UniswapV4ERC20(poolStates[key.toId()].liquidityToken).burn(sender, uint256(-params.liquidityDelta));
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Reverts if the swap is not the first zeroForOne or oneForZero swap of the block.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        uint256 blockNumber = block.number;

        if (params.zeroForOne) {
            if (poolStates[poolId].zeroForOneBlockNumber == blockNumber) 
                revert MultipleZeroForOneSwapNotAllowedPerBlock();
            poolStates[poolId].zeroForOneBlockNumber = blockNumber;
        } else {
            if (poolStates[poolId].oneForZeroBlockNumber == blockNumber) 
                revert MultipleOneForZeroSwapNotAllowedPerBlock();
            poolStates[poolId].oneForZeroBlockNumber = blockNumber;
        }
        
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    struct StepComputations {
        bool specifiedTokenIs0;
        uint256 sqrtPriceX96;
        uint256 oldSwapAmount;
        uint256 newSwapAmount;
        uint256 feeAmount;
        uint256 hookFeeAmount;
        Currency feeCurrency;
    }

    /// @notice From the total dynamic swap fee, donates LP's swap fee and takes hook's swap fee.
    function afterSwap(
        address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata
    ) external override onlyManager returns (bytes4, int128) {
        StepComputations memory step;
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        step.sqrtPriceX96 = sqrtPriceX96;

        // dynamic swap fee will be in the unspecified token of the swap
        step.specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        
        if (step.specifiedTokenIs0) {
            step.oldSwapAmount = uint256(uint128(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));
            if (delta.amount0() < 0) {
                step.newSwapAmount = _mulDiv(uint256(uint128(-delta.amount0())), step.sqrtPriceX96, FixedPoint96.Q96, false);
                step.feeAmount = step.oldSwapAmount - step.newSwapAmount;
            } else {
                step.newSwapAmount = _mulDiv(uint256(uint128(delta.amount0())), step.sqrtPriceX96, FixedPoint96.Q96, true);
                step.feeAmount = step.newSwapAmount - step.oldSwapAmount;
            }
            step.feeCurrency = key.currency1;
        } else {
            step.oldSwapAmount = uint256(uint128(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
            if (delta.amount1() < 0) {
                step.newSwapAmount = _mulDiv(uint256(uint128(-delta.amount0())), FixedPoint96.Q96, step.sqrtPriceX96, false);
                step.feeAmount = step.oldSwapAmount - step.newSwapAmount;
            } else {
                step.newSwapAmount = _mulDiv(uint256(uint128(delta.amount1())), FixedPoint96.Q96, step.sqrtPriceX96, true);
                step.feeAmount = step.newSwapAmount - step.oldSwapAmount;
            }
            step.feeCurrency = key.currency1;
        }
        
        step.hookFeeAmount = step.feeAmount * poolStates[key.toId()].swapFeeBips / 10000;
        manager.donate(key, 0, step.feeAmount - step.hookFeeAmount, bytes(""));
        if (step.hookFeeAmount > 0) manager.take(step.feeCurrency , address(this), step.hookFeeAmount);

        return (IHooks.afterSwap.selector, step.feeAmount.toInt128());
    }

    /// @notice Sets hook swap fee bips.
    function setSwapFeeBips(PoolKey calldata key, uint8 bips) external onlyOwner{
        if (bips < 1000) revert SwapFeeBipsTooLarge(); // 10%
        poolStates[key.toId()].swapFeeBips = bips;
    }

    /// @notice Claims accrued hook swap fees.
    function claimTokens(Currency token, address to, uint256 amountRequested) external onlyOwner {
        IERC20Minimal(Currency.unwrap(token)).safeTransfer(to, amountRequested);
    }

    function _mulDiv(uint256 a, uint256 b, uint256 c, bool roundingUp) internal pure returns (uint256) {
        if (roundingUp) {
            return FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(a, b, c), b, c);
        } else {
            return FullMath.mulDiv(FullMath.mulDiv(a, b, c), b, c);
        }
    }
}
