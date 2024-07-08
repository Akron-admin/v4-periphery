// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MiddlewareProtect} from "./MiddlewareProtect.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IBaseHook} from "../interfaces/IBaseHook.sol";
import {BaseMiddlewareFactory} from "./BaseMiddlewareFactory.sol";

contract MiddlewareProtectFactory is BaseMiddlewareFactory {
    constructor(IPoolManager _poolManager) BaseMiddlewareFactory(_poolManager) {}

    function _deployMiddleware(address implementation, bytes32 salt) internal override returns (address middleware) {
        return address(new MiddlewareProtect{salt: salt}(poolManager, IBaseHook(implementation)));
    }
}
