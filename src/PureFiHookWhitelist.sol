// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VerifierHook} from './VerifierHook.sol';
import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {IPureFiVerifier} from '@purefi-sdk-solidity-v5/interfaces/IPureFiVerifier.sol';
import {CustomRevert} from '@purefi-sdk-solidity-v5/libraries/CustomRevert.sol';

import {PureFiDataLibrary} from '@purefi-sdk-solidity-v5/libraries/PureFiDataLibrary.sol';

contract PureFiHookWhitelist is AccessControl, Initializable {
    using PureFiDataLibrary for bytes;
    using CustomRevert for bytes4;

    bytes32 public constant ISSUER = keccak256('ISSUER');
    bytes32 public constant MARKET_MAKER = keccak256('MARKET_MAKER');
    bytes32 public constant ROUTER = keccak256('ROUTER');
    bytes32 public constant QUOTER = keccak256('QUOTER');

    IPureFiVerifier public verifier;
    AccessControl public verifierHook;

    event AddressEnlisted(address);
    event AddressDelisted(address);
    event SettledVerifier(address);

    error WrongMessageSender(address);

    function initialize(IPureFiVerifier _verifier) external initializer {
        verifier = _verifier;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    modifier purified(bytes calldata purefidata) {
        _validatePureFiData(purefidata);
        _;
    }

    function setVerifierHook(address _verifierHook) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifierHook = AccessControl(_verifierHook);
        emit SettledVerifier(_verifierHook);
    }

    function isAuthorized(address requestedAddress) external view returns (bool) {
        return hasRole(MARKET_MAKER, requestedAddress) || hasRole(ROUTER, requestedAddress);
    }

    function enlistMe(bytes calldata purefidata) external purified(purefidata) {
        verifierHook.grantRole(MARKET_MAKER, _msgSender());
        emit AddressEnlisted(_msgSender());
    }

    function delistMe(bytes calldata purefidata) external purified(purefidata) {
        verifierHook.revokeRole(MARKET_MAKER, _msgSender());
        emit AddressDelisted(_msgSender());
    }

    function addRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifierHook.grantRole(ROUTER, router);
        emit AddressEnlisted(router);
    }

    function removeRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifierHook.revokeRole(ROUTER, router);
        emit AddressDelisted(router);
    }

    function addQuoter(address qouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifierHook.grantRole(QUOTER, qouter);
        emit AddressEnlisted(qouter);
    }

    function removeQuoter(address qouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifierHook.revokeRole(QUOTER, qouter);
        emit AddressDelisted(qouter);
    }

    function delist(address marketMaker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(ISSUER, _msgSender()));
        verifierHook.revokeRole(MARKET_MAKER, marketMaker);
        emit AddressDelisted(marketMaker);
    }

    function _validatePureFiData(bytes calldata purefidata) internal {
        verifier.validatePayload(purefidata);
        if (purefidata.getFrom() != _msgSender()) {
            WrongMessageSender.selector.revertWith(_msgSender());
        }
    }
}
