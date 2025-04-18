// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IValidator} from "kernel/interfaces/IERC7579Modules.sol";

/**
 * @title RecoveryAction
 * @notice Implements a recovery mechanism with escape modes and timelocks
 * @dev Based on Argent Account recovery mechanism
 */
contract RecoveryAction {
    // Events
    event EscapeTriggered(address indexed validator, address initiator, bool isOwnerInitiated);
    event EscapeCompleted(address indexed validator, address initiator, bool isOwnerInitiated);
    event EscapeCancelled(address indexed validator);
    event EscapeOverridden(address indexed validator);
    event SecurityPeriodChanged(uint256 newSecurityPeriod);

    // Errors
    error NoActiveEscape();
    error SecurityPeriodNotElapsed();
    error EscapeExpired();
    error NotEscapeInitiator();
    error CannotOverrideOwnerEscape();
    error InvalidSecurityPeriod();
    error NotOwnerOrGuardian();
    error RequiresOwnerAndGuardianApproval();

    // State variables
    uint256 public securityPeriod = 7 days; // Default security period is 7 days

    struct EscapeRequest {
        uint256 timestamp;
        address initiator;
        bool isOwnerInitiated;
        bytes recoveryData;
        bool active;
        uint256 securityPeriodSnapshot;
    }

    // Mapping from validator address to escape request
    mapping(address => EscapeRequest) public escapeRequests;

    // Mapping to track cancel approvals (validator => role => approved)
    // role: true = owner, false = guardian
    mapping(address => mapping(bool => bool)) public cancelApprovals;

    /**
     * @notice Set the security period for escapes
     * @param _securityPeriod New security period in seconds
     */
    function setSecurityPeriod(uint256 _securityPeriod) external {
        if (_securityPeriod == 0) revert InvalidSecurityPeriod();
        securityPeriod = _securityPeriod;
        emit SecurityPeriodChanged(_securityPeriod);
    }

    /**
     * @notice Trigger an escape as the owner
     * @param _validator Address of the validator
     * @param _data Recovery data to be used when escape is completed
     */
    function triggerEscapeOwner(address _validator, bytes calldata _data) external {
        escapeRequests[_validator] = EscapeRequest({
            timestamp: block.timestamp,
            initiator: msg.sender,
            isOwnerInitiated: true,
            recoveryData: _data,
            active: true,
            securityPeriodSnapshot: securityPeriod
        });

        // Reset any cancel approvals for this validator
        cancelApprovals[_validator][true] = false;
        cancelApprovals[_validator][false] = false;

        emit EscapeTriggered(_validator, msg.sender, true);
    }

    /**
     * @notice Trigger an escape as the guardian
     * @param _validator Address of the validator
     * @param _data Recovery data to be used when escape is completed
     */
    function triggerEscapeGuardian(address _validator, bytes calldata _data) external {
        escapeRequests[_validator] = EscapeRequest({
            timestamp: block.timestamp,
            initiator: msg.sender,
            isOwnerInitiated: false,
            recoveryData: _data,
            active: true,
            securityPeriodSnapshot: securityPeriod
        });

        // Reset any cancel approvals for this validator
        cancelApprovals[_validator][true] = false;
        cancelApprovals[_validator][false] = false;

        emit EscapeTriggered(_validator, msg.sender, false);
    }

    /**
     * @notice Complete an owner-initiated escape after security period
     * @param _validator Address of the validator
     */
    function escapeOwner(address _validator) external {
        EscapeRequest storage request = escapeRequests[_validator];

        if (!request.active) revert NoActiveEscape();
        if (!request.isOwnerInitiated) revert NotEscapeInitiator();
        if (msg.sender != request.initiator) revert NotEscapeInitiator();
        if (!_isSecurityPeriodElapsed(_validator)) revert SecurityPeriodNotElapsed();
        if (_isEscapeExpired(_validator)) revert EscapeExpired();

        bytes memory recoveryData = request.recoveryData;
        address initiator = request.initiator;
        bool isOwnerInitiated = request.isOwnerInitiated;

        // Clear the escape request
        delete escapeRequests[_validator];

        // Execute the recovery
        _executeRecovery(_validator, recoveryData);

        emit EscapeCompleted(_validator, initiator, isOwnerInitiated);
    }

    /**
     * @notice Complete a guardian-initiated escape after security period
     * @param _validator Address of the validator
     */
    function escapeGuardian(address _validator) external {
        EscapeRequest storage request = escapeRequests[_validator];

        if (!request.active) revert NoActiveEscape();
        if (request.isOwnerInitiated) revert NotEscapeInitiator();
        if (msg.sender != request.initiator) revert NotEscapeInitiator();
        if (!_isSecurityPeriodElapsed(_validator)) revert SecurityPeriodNotElapsed();
        if (_isEscapeExpired(_validator)) revert EscapeExpired();

        bytes memory recoveryData = request.recoveryData;
        address initiator = request.initiator;
        bool isOwnerInitiated = request.isOwnerInitiated;

        // Clear the escape request
        delete escapeRequests[_validator];

        // Execute the recovery
        _executeRecovery(_validator, recoveryData);

        emit EscapeCompleted(_validator, initiator, isOwnerInitiated);
    }

    /**
     * @notice Approve cancellation of an escape (requires both owner and guardian approval)
     * @param _validator Address of the validator
     */
    function approveCancelEscape(address _validator) external {
        EscapeRequest storage request = escapeRequests[_validator];
        
        if (!request.active) revert NoActiveEscape();
        
        // Determine if caller is owner or guardian based on the escape request
        bool isCallerOwner;
        
        if (request.isOwnerInitiated) {
            // If owner initiated, the initiator is the owner
            isCallerOwner = (msg.sender == request.initiator);
        } else {
            // If guardian initiated, the initiator is the guardian
            isCallerOwner = (msg.sender != request.initiator);
        }
        
        // Record the approval
        cancelApprovals[_validator][isCallerOwner] = true;
        
        // If both owner and guardian have approved, cancel the escape
        if (cancelApprovals[_validator][true] && cancelApprovals[_validator][false]) {
            // Clear the escape request
            delete escapeRequests[_validator];
            
            // Clear the approvals
            cancelApprovals[_validator][true] = false;
            cancelApprovals[_validator][false] = false;
            
            emit EscapeCancelled(_validator);
        }
    }

    /**
     * @notice Override a guardian-initiated escape (owner only)
     * @param _validator Address of the validator
     */
    function overrideGuardianEscape(address _validator) external {
        EscapeRequest storage request = escapeRequests[_validator];

        if (!request.active) revert NoActiveEscape();
        if (request.isOwnerInitiated) revert CannotOverrideOwnerEscape();

        // Clear the escape request
        delete escapeRequests[_validator];

        emit EscapeOverridden(_validator);
    }

    /**
     * @notice Check if the security period has elapsed for an escape
     * @param _validator Address of the validator
     * @return True if security period has elapsed
     */
    function _isSecurityPeriodElapsed(address _validator) internal view returns (bool) {
        EscapeRequest storage request = escapeRequests[_validator];
        return block.timestamp >= request.timestamp + request.securityPeriodSnapshot;
    }

    /**
     * @notice Check if an escape has expired (another security period after it became active)
     * @param _validator Address of the validator
     * @return True if escape has expired
     */
    function _isEscapeExpired(address _validator) internal view returns (bool) {
        EscapeRequest storage request = escapeRequests[_validator];
        return block.timestamp > request.timestamp + (2 * request.securityPeriodSnapshot);
    }

    /**
     * @notice Execute the recovery by uninstalling and reinstalling the validator
     * @param _validator Address of the validator
     * @param _data Recovery data to be used for installation
     */
    function _executeRecovery(address _validator, bytes memory _data) internal {
        IValidator(_validator).onUninstall(hex"");
        IValidator(_validator).onInstall(_data);
    }
}
