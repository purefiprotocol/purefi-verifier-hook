// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from 'v4-core/types/Currency.sol';

import {IPoolManager} from 'v4-core/interfaces/IPoolManager.sol';
import {IUnlockCallback} from 'v4-core/interfaces/callback/IUnlockCallback.sol';

import {StateLibrary} from 'v4-core/libraries/StateLibrary.sol';
import {TransientStateLibrary} from 'v4-core/libraries/TransientStateLibrary.sol';

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PureFiHookWhitelist} from './PureFiHookWhitelist.sol';
import '@purefi-sdk-solidity-v5/interfaces/IPureFiVerifier.sol';
import '@purefi-sdk-solidity-v5/libraries/PureFiDataLibrary.sol';

abstract contract PureFiBaseRouter is IUnlockCallback, OwnableUpgradeable {
    using PureFiDataLibrary for bytes;
    using CustomRevert for bytes4;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public manager;
    IPureFiVerifier public verifier;
    PureFiHookWhitelist internal whitelist;

    // Packed array of booleans
    mapping(uint32 => bool) public ruleIdRegistry;

    error UnexpectedRule();
    error WrongPackageFrom();

    event RuleIdSettled(uint32 id, bool isActive);

    function __PureFiBaseRouter_init(
        IPoolManager _poolManager,
        IPureFiVerifier _verifier,
        PureFiHookWhitelist _whitelist,
        address owner
    ) internal onlyInitializing {
        manager = _poolManager;
        verifier = _verifier;
        whitelist = _whitelist;
        __Ownable_init_unchained(owner);
    }

    // Hook checks: rule, from (=msg.sender), token, amount
    // Verifier checks: package length, issuer/signature, AML gracetime, session, to (=hook)

    modifier purified(bytes calldata purefidata) {
        verifier.validatePayload(purefidata);
        _;
    }

    function setRuleId(uint32 ruleId, bool mode) external onlyOwner {
        ruleIdRegistry[ruleId] = mode;
        emit RuleIdSettled(ruleId, mode);
    }

    function _fetchBalances(Currency currency, address user, address deltaHolder)
        internal
        view
        returns (uint256 userBalance, uint256 poolBalance, int256 delta)
    {
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(manager));
        delta = manager.currencyDelta(deltaHolder, currency);
    }

    function _validatePureFiData(bytes calldata purefidata) internal virtual {
        if (whitelist.isAuthorized(_msgSender())) {
            return;
        }
        verifier.validatePayload(purefidata);

        if (!ruleIdRegistry[uint32(purefidata.getRule())]) {
            UnexpectedRule.selector.revertWith();
        }
        if (purefidata.getFrom() != _msgSender()) {
            WrongPackageFrom.selector.revertWith();
        }
    }

    /// @notice Settle (pay) a currency to the PoolManager
    /// @param currency Currency to settle
    /// @param _manager IPoolManager to settle to
    /// @param payer Address of the payer, the token sender
    /// @param amount Amount to send
    /// @param burn If true, burn the ERC-6909 token, otherwise ERC20-transfer to the PoolManager
    function settle(Currency currency, IPoolManager _manager, address payer, uint256 amount, bool burn) internal {
        // for native currencies or burns, calling sync is not required
        // short circuit for ERC-6909 burns to support ERC-6909-wrapped native tokens
        if (burn) {
            _manager.burn(payer, currency.toId(), amount);
        } else if (currency.isAddressZero()) {
            _manager.settle{value: amount}();
        } else {
            _manager.sync(currency);
            if (payer != address(this)) {
                IERC20(Currency.unwrap(currency)).transferFrom(payer, address(_manager), amount);
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(_manager), amount);
            }
            _manager.settle();
        }
    }

    /// @notice Take (receive) a currency from the PoolManager
    /// @param currency Currency to take
    /// @param _manager IPoolManager to take from
    /// @param recipient Address of the recipient, the token receiver
    /// @param amount Amount to receive
    /// @param claims If true, mint the ERC-6909 token, otherwise ERC20-transfer from the PoolManager to recipient
    function take(Currency currency, IPoolManager _manager, address recipient, uint256 amount, bool claims) internal {
        claims ? _manager.mint(recipient, currency.toId(), amount) : _manager.take(currency, recipient, amount);
    }
}
