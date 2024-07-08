// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HooksFrontrun} from "./middleware/HooksFrontrun.sol";
import {MiddlewareProtect} from "../contracts/middleware/MiddlewareProtect.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {console} from "../../../lib/forge-std/src/console.sol";
import {HooksRevert} from "./middleware/HooksRevert.sol";
import {HooksOutOfGas} from "./middleware/HooksOutOfGas.sol";
import {MiddlewareProtectFactory} from "./../contracts/middleware/MiddlewareProtectFactory.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {HooksReturnDeltas} from "./middleware/HooksReturnDeltas.sol";
import {HooksDoNothing} from "./middleware/HooksDoNothing.sol";

contract MiddlewareProtectFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    address constant TREASURY = address(0x1234567890123456789012345678901234567890);
    uint128 private constant TOTAL_BIPS = 10000;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    PoolId id;

    MiddlewareProtectFactory factory;
    HooksDoNothing hooksDoNothing;
    HooksFrontrun hooksFrontrun;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        factory = new MiddlewareProtectFactory(manager);
        hooksDoNothing = new HooksDoNothing(manager, address(factory));

        hooksFrontrun = HooksFrontrun(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)));
        vm.record();
        HooksFrontrun impl = new HooksFrontrun(manager, address(factory));
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(hooksFrontrun), address(impl).code);
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hooksFrontrun), slot, vm.load(address(impl), slot));
            }
        }

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function testRevertOnIncorrectFlags() public {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(hooksDoNothing))
        );
        address implementation = address(hooksDoNothing);
        vm.expectRevert(abi.encodePacked(bytes16(Hooks.HookAddressNotValid.selector), hookAddress));
        factory.createMiddleware(implementation, salt);
    }

    function testRevertOnIncorrectFlagsMined() public {
        address implementation = address(hooksDoNothing);
        vm.expectRevert(); // HookAddressNotValid
        factory.createMiddleware(implementation, bytes32("who needs to mine a salt?"));
    }

    function testRevertOnDeltas() public {
        HooksReturnDeltas hooksReturnDeltas = new HooksReturnDeltas(manager, address(factory));
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(hooksReturnDeltas))
        );
        address implementation = address(hooksReturnDeltas);
        console.log(hookAddress);
        vm.expectRevert(abi.encodePacked(bytes16(MiddlewareProtect.HookPermissionForbidden.selector), hookAddress));
        factory.createMiddleware(implementation, salt);
    }

    function testFrontrun() public {
        return;
        (PoolKey memory key,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 100, SQRT_PRICE_1_1, ZERO_BYTES);
        BalanceDelta swapDelta = swap(key, true, 0.001 ether, ZERO_BYTES);

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hooksFrontrun)), 100, SQRT_PRICE_1_1, ZERO_BYTES
        );
        BalanceDelta swapDelta2 = swap(key, true, 0.001 ether, ZERO_BYTES);

        // while both swaps are in the same pool, the second swap is more expensive
        assertEq(swapDelta.amount1(), swapDelta2.amount1());
        assertTrue(abs(swapDelta.amount0()) < abs(swapDelta2.amount0()));
        assertTrue(manager.balanceOf(address(hooksFrontrun), CurrencyLibrary.toId(key.currency0)) > 0);
    }

    function testRevertOnFrontrun() public {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(factory),
            flags,
            type(MiddlewareProtect).creationCode,
            abi.encode(address(manager), address(hooksFrontrun))
        );
        address implementation = address(hooksFrontrun);
        address hookAddressCreated = factory.createMiddleware(implementation, salt);
        assertEq(hookAddressCreated, hookAddress);
        MiddlewareProtect middlewareProtect = MiddlewareProtect(payable(hookAddress));

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(middlewareProtect)), 100, SQRT_PRICE_1_1, ZERO_BYTES
        );
        vm.expectRevert(MiddlewareProtect.ActionBetweenHook.selector);
        swap(key, true, 0.001 ether, ZERO_BYTES);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
