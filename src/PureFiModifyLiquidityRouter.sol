// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import './PureFiBaseRouter.sol';

import {IHooks} from 'v4-core/interfaces/IHooks.sol';
import {IPoolManager} from 'v4-core/interfaces/IPoolManager.sol';
import {Hooks} from 'v4-core/libraries/Hooks.sol';
import {LPFeeLibrary} from 'v4-core/libraries/LPFeeLibrary.sol';
import {StateLibrary} from 'v4-core/libraries/StateLibrary.sol';
import {BalanceDelta} from 'v4-core/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from 'v4-core/types/Currency.sol';
import {PoolKey} from 'v4-core/types/PoolKey.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@purefi-sdk-solidity-v5/interfaces/IPureFiVerifier.sol';

contract PureFiModifyLiquidityRouter is PureFiBaseRouter {
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    function initialize(IPoolManager _poolManager, IPureFiVerifier _verifier, PureFiHookWhitelist _whitelist)
        external
        initializer
    {
        __PureFiBaseRouter_init(_poolManager, _verifier, _whitelist, _msgSender());
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) external payable returns (BalanceDelta delta) {
        delta = modifyLiquidity(key, params, hookData, false, false);
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData,
        bool settleUsingBurn,
        bool takeClaims
    ) public payable purified(hookData) returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, settleUsingBurn, takeClaims))),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (uint128 liquidityBefore,,) = manager.getPositionInfo(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (BalanceDelta delta,) = manager.modifyLiquidity(data.key, data.params, data.hookData);

        (uint128 liquidityAfter,,) = manager.getPositionInfo(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (,, int256 delta0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 delta1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(
            int128(liquidityBefore) + data.params.liquidityDelta == int128(liquidityAfter), 'liquidity change incorrect'
        );

        if (data.params.liquidityDelta < 0) {
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (data.params.liquidityDelta > 0) {
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }

        if (delta0 < 0) settle(data.key.currency0, manager, data.sender, uint256(-delta0), data.settleUsingBurn);
        if (delta1 < 0) settle(data.key.currency1, manager, data.sender, uint256(-delta1), data.settleUsingBurn);
        if (delta0 > 0) take(data.key.currency0, manager, data.sender, uint256(delta0), data.takeClaims);
        if (delta1 > 0) take(data.key.currency1, manager, data.sender, uint256(delta1), data.takeClaims);

        return abi.encode(delta);
    }
}
