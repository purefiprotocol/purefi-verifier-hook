// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PureFiBaseRouter} from './PureFiBaseRouter.sol';

import {IHooks} from 'v4-core/interfaces/IHooks.sol';
import {IPoolManager} from 'v4-core/interfaces/IPoolManager.sol';
import {Hooks} from 'v4-core/libraries/Hooks.sol';
import {BalanceDelta} from 'v4-core/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from 'v4-core/types/Currency.sol';
import {PoolKey} from 'v4-core/types/PoolKey.sol';

import {PureFiHookWhitelist} from './PureFiHookWhitelist.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPureFiVerifier, PureFiData} from '@purefi-sdk-solidity-v5/interfaces/IPureFiVerifier.sol';
import '@purefi-sdk-solidity-v5/libraries/CustomRevert.sol';
import '@purefi-sdk-solidity-v5/libraries/PureFiDataLibrary.sol';

contract PureFiSwapRouter is PureFiBaseRouter {
    using Hooks for IHooks;
    using PureFiDataLibrary for bytes;
    using CustomRevert for bytes4;

    function initialize(IPoolManager _poolManager, IPureFiVerifier _verifier, PureFiHookWhitelist _whitelist)
        external
        initializer
    {
        __PureFiBaseRouter_init(_poolManager, _verifier, _whitelist, _msgSender());
    }

    error NoSwapOccurred();
    error UnexpectedPackageType();
    error WrongToken();
    error PackageToken0AmountMismatch();

    struct CallbackData {
        address sender;
        TestSettings testSettings;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    modifier purifiedSwap(IPoolManager.SwapParams memory params, bytes calldata purefidata) {
        _validatePureFiData(params, purefidata);
        _;
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        TestSettings memory testSettings,
        bytes calldata hookData
    ) external payable purifiedSwap(params, hookData) returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, testSettings, key, params, hookData))), (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (,, int256 deltaBefore0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaBefore1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(deltaBefore0 == 0, 'deltaBefore0 is not equal to 0');
        require(deltaBefore1 == 0, 'deltaBefore1 is not equal to 0');

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        (,, int256 deltaAfter0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 deltaAfter1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if (data.params.zeroForOne) {
            if (data.params.amountSpecified < 0) {
                // exact input, 0 for 1
                require(
                    deltaAfter0 >= data.params.amountSpecified,
                    'deltaAfter0 is not greater than or equal to data.params.amountSpecified'
                );
                require(delta.amount0() == deltaAfter0, 'delta.amount0() is not equal to deltaAfter0');
                require(deltaAfter1 >= 0, 'deltaAfter1 is not greater than or equal to 0');
            } else {
                // exact output, 0 for 1
                require(deltaAfter0 <= 0, 'deltaAfter0 is not less than or equal to zero');
                require(delta.amount1() == deltaAfter1, 'delta.amount1() is not equal to deltaAfter1');
                require(
                    deltaAfter1 <= data.params.amountSpecified,
                    'deltaAfter1 is not less than or equal to data.params.amountSpecified'
                );
            }
        } else {
            if (data.params.amountSpecified < 0) {
                // exact input, 1 for 0
                require(
                    deltaAfter1 >= data.params.amountSpecified,
                    'deltaAfter1 is not greater than or equal to data.params.amountSpecified'
                );
                require(delta.amount1() == deltaAfter1, 'delta.amount1() is not equal to deltaAfter1');
                require(deltaAfter0 >= 0, 'deltaAfter0 is not greater than or equal to 0');
            } else {
                // exact output, 1 for 0
                require(deltaAfter1 <= 0, 'deltaAfter1 is not less than or equal to 0');
                require(delta.amount0() == deltaAfter0, 'delta.amount0() is not equal to deltaAfter0');
                require(
                    deltaAfter0 <= data.params.amountSpecified,
                    'deltaAfter0 is not less than or equal to data.params.amountSpecified'
                );
            }
        }

        if (deltaAfter0 < 0) {
            settle(data.key.currency0, manager, data.sender, uint256(-deltaAfter0), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter1 < 0) {
            settle(data.key.currency1, manager, data.sender, uint256(-deltaAfter1), data.testSettings.settleUsingBurn);
        }
        if (deltaAfter0 > 0) {
            take(data.key.currency0, manager, data.sender, uint256(deltaAfter0), data.testSettings.takeClaims);
        }
        if (deltaAfter1 > 0) {
            take(data.key.currency1, manager, data.sender, uint256(deltaAfter1), data.testSettings.takeClaims);
        }

        return abi.encode(delta);
    }

    function _validatePureFiData(IPoolManager.SwapParams memory, bytes calldata _payload) internal {
        verifier.validatePayload(_payload);
        PureFiData calldata pureFiData;

        assembly ("memory-safe") {
            pureFiData := _payload.offset
        }
        // authorized MM
        if (pureFiData.package.getPackageType() == 0) {
            return;
        }
    }
}
