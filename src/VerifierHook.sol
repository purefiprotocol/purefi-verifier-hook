// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import '../src/PureFiHookWhitelist.sol';

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@purefi-sdk-solidity-v5/interfaces/IPureFiVerifier.sol';
import '@purefi-sdk-solidity-v5/libraries/PureFiDataLibrary.sol';
import {IPoolManager} from 'v4-core/interfaces/IPoolManager.sol';
import {Hooks} from 'v4-core/libraries/Hooks.sol';
import 'v4-core/types/BalanceDelta.sol';
import {BalanceDelta} from 'v4-core/types/BalanceDelta.sol';
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from 'v4-core/types/BeforeSwapDelta.sol';
import {Currency, CurrencyLibrary} from 'v4-core/types/Currency.sol';
import {PoolId, PoolIdLibrary} from 'v4-core/types/PoolId.sol';
import {PoolKey} from 'v4-core/types/PoolKey.sol';
import {BaseHook} from 'v4-periphery/src/base/hooks/BaseHook.sol';

contract VerifierHook is BaseHook, AccessControl {
    using PureFiDataLibrary for bytes;
    using CustomRevert for bytes4;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for *;
    // Use the CurrencyLibrary for the Currency struct
    using CurrencyLibrary for Currency;

    IPureFiVerifier public immutable verifier;
    PureFiHookWhitelist public immutable whitelist;

    mapping(address => bool) private routersWhitelist;
    mapping(uint32 => bool) public ruleId;

    bytes32 public constant ISSUER = keccak256('ISSUER');
    bytes32 public constant MARKET_MAKER = keccak256('MARKET_MAKER');
    bytes32 public constant ROUTER = keccak256('ROUTER');
    bytes32 public constant QUOTER = keccak256('QUOTER');

    event RouterWhitelisted(address);
    event RouterDelisted(address);

    error WrongPackageNumberError();
    error WrongTokenError();
    error PackageToken0AmountMismatchError();
    error WrongSenderError();
    error BalanceDeltaExceedsToken0AmountError();
    error BalanceDeltaExceedsToken1AmountError();
    error WrongAmountSpecifiedExactInputError(uint160 input, uint160 packageAmount);
    error UnexpectedPackageRuleError(uint160 specified);
    error WrongAmountSpecifiedExactOutputError(uint160 input, uint160 packageAmount);

    constructor(IPoolManager _poolManager, IPureFiVerifier _verifier, PureFiHookWhitelist _whitelist, address _owner)
        BaseHook(_poolManager)
    {
        verifier = _verifier;
        whitelist = _whitelist;
        _grantRole(DEFAULT_ADMIN_ROLE, address(_whitelist));
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    }

    modifier purified(bytes calldata _payload, address sender) {
        if (!hasRole(ROUTER, sender) && !hasRole(QUOTER, sender)) {
            _validatePureFiData(_payload, sender);
        }
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata _payload
    ) external view override purified(_payload, sender) returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function version() public pure returns (uint32) {
        // 000.000.000 - Major.minor.internal
        return 1_000_001;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata _payload
    ) external view override purified(_payload, sender) returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @dev No purified modifier, _validatePureFiData is called as a regular function
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata _payload
    ) external view override returns (bytes4, BeforeSwapDelta, uint24) {
        if (!hasRole(QUOTER, sender) && params.amountSpecified < 0) {
            PureFiData calldata pureFiData;

            assembly ("memory-safe") {
                pureFiData := _payload.offset
            }

            IERC20 tokenToSwap =
                IERC20(params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1));

            uint256 amountToSwap =
                uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);

            (address packageToken, uint256 packageInputAmount) = pureFiData.package.getTokenData0();

            if (packageToken != address(tokenToSwap)) {
                WrongTokenError.selector.revertWith();
            }

            if (packageInputAmount < amountToSwap) {
                PackageToken0AmountMismatchError.selector.revertWith();
            }
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata _payload
    ) external view override returns (bytes4, int128) {
        if (params.amountSpecified > 0 && !hasRole(QUOTER, sender)) {
            PureFiData calldata pureFiData;

            assembly ("memory-safe") {
                pureFiData := _payload.offset
            }

            int128 inputTokenAmount;
            address inputToken;
            if (params.zeroForOne) {
                inputTokenAmount = delta.amount0();
                inputToken = address(Currency.unwrap(key.currency0));
            } else {
                inputTokenAmount = delta.amount1();
                inputToken = address(Currency.unwrap(key.currency1));
            }

            uint256 amountToSwap = uint128(inputTokenAmount > 0 ? inputTokenAmount : -inputTokenAmount);

            (address inputTokenPackage, uint256 inputAmountPackage) = pureFiData.package.getTokenData0();

            if (inputTokenPackage != inputToken) {
                WrongTokenError.selector.revertWith();
            }

            if (inputAmountPackage < amountToSwap) {
                WrongAmountSpecifiedExactOutputError.selector.revertWith(
                    uint160(amountToSwap), uint160(inputAmountPackage)
                );
            }
        }

        return (this.afterSwap.selector, 0);
    }

    function beforeDonate(address sender, PoolKey calldata, uint256, uint256, bytes calldata _payload)
        external
        view
        override
        purified(_payload, sender)
        returns (bytes4)
    {
        return BaseHook.beforeDonate.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata _payload
    ) external view override returns (bytes4, BalanceDelta) {
        if (!hasRole(QUOTER, sender)) {
            PureFiData calldata pureFiData;

            assembly ("memory-safe") {
                pureFiData := _payload.offset
            }

            (address token0, uint256 token0Amount) = pureFiData.package.getTokenData0();

            if (token0 != address(Currency.unwrap(key.currency0))) {
                WrongTokenError.selector.revertWith();
            }

            if (token0Amount.toInt128() < -delta.amount0()) {
                BalanceDeltaExceedsToken0AmountError.selector.revertWith();
            }

            (address token1, uint256 token1Amount) = pureFiData.package.getTokenData1();

            if (token1 != address(Currency.unwrap(key.currency1))) {
                WrongTokenError.selector.revertWith();
            }

            if (token1Amount.toInt128() < -delta.amount1()) {
                BalanceDeltaExceedsToken1AmountError.selector.revertWith();
            }
        }

        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata _payload
    ) external view override returns (bytes4, BalanceDelta) {
        if (!hasRole(QUOTER, sender)) {
            PureFiData calldata pureFiData;

            assembly ("memory-safe") {
                pureFiData := _payload.offset
            }

            (address token0, uint256 token0Amount) = pureFiData.package.getTokenData0();

            if (token0 != address(Currency.unwrap(key.currency0))) {
                WrongTokenError.selector.revertWith();
            }

            if (token0Amount.toInt128() < delta.amount0()) {
                BalanceDeltaExceedsToken0AmountError.selector.revertWith();
            }

            (address token1, uint256 token1Amount) = pureFiData.package.getTokenData1();

            if (token1 != address(Currency.unwrap(key.currency1))) {
                WrongTokenError.selector.revertWith();
            }

            if (token1Amount.toInt128() < delta.amount1()) {
                BalanceDeltaExceedsToken1AmountError.selector.revertWith();
            }
        }

        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }

    // Hook checks: rule, from (=msg.sender), token, amount
    // Verifier checks: package length, issuer/signature, AML gracetime, session, to (=hook)
    /// @dev in order to handle txs which are stolen from the mempool and sent from the different EOA other than real MM.
    /// @dev ABI encoding and ecrecover will not help (even signed data can be seen in mempool and stolen).
    /// @dev tx.origin can be the solution, but it needs to be verified by auditors and has its own corner cases with MEVs and Account Abstractions.
    function _validatePureFiData(bytes calldata _payload, address sender) internal view {
        //verifier.validatePayload(purefidata);
        PureFiData calldata pureFiData;

        assembly ("memory-safe") {
            pureFiData := _payload.offset
        }

        if (whitelist.isAuthorized(pureFiData.package.getFrom())) {
            return;
        }

        if (!ruleId[uint32(pureFiData.package.getRule())]) {
            UnexpectedPackageRuleError.selector.revertWith(uint160(pureFiData.package.getFrom()));
        }

        if (pureFiData.package.getFrom() != sender) {
            WrongSenderError.selector.revertWith();
        }
    }

    function setExpectedRuleId(uint256[] calldata ruleIds, bool isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < ruleIds.length; i++) {
            ruleId[uint32(ruleIds[i])] = isActive;
        }
    }
}
