// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IValidator} from "kernel/interfaces/IERC7579Modules.sol";

/**
 * @title RecoveryAction
 * @notice Implements a recovery mechanism with escape modes and timelocks
 * @dev Based on Argent Account recovery mechanism
 */
contract RecoveryAction {
    // Constants
    uint256 public constant MIN_ESCAPE_SECURITY_PERIOD = 10 minutes;
    uint256 public constant TIME_BETWEEN_TWO_ESCAPES = 12 hours;
    
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
    error EscapeAttemptTooEarly();
    error InvalidEscapeType();

    // State variables
    uint256 public securityPeriod = 7 days; // Default security period is 7 days
    
    // Timestamps of last escape attempts
    mapping(address => uint256) public lastOwnerEscapeAttempt;
    mapping(address => uint256) public lastGuardianEscapeAttempt;
    mapping(address => uint256) public lastOwnerTriggerEscapeAttempt;
    mapping(address => uint256) public lastGuardianTriggerEscapeAttempt;

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
        if (_securityPeriod < MIN_ESCAPE_SECURITY_PERIOD) revert InvalidSecurityPeriod();
        
        // Get current escape if any, and its status
        EscapeRequest storage currentEscape = escapeRequests[address(0)]; // Using address(0) as a placeholder
        EscapeStatus currentStatus = EscapeStatus.None;
        
        if (currentEscape.active) {
            currentStatus = _getEscapeStatus(currentEscape.timestamp + currentEscape.securityPeriodSnapshot);
            
            // If there's an active escape that's ready, we can't change the security period
            if (currentStatus == EscapeStatus.Ready) {
                revert("Cannot change security period with active escape");
            }
            
            // If the escape is expired, clear it
            if (currentStatus == EscapeStatus.Expired) {
                delete escapeRequests[address(0)];
            }
        }
        
        securityPeriod = _securityPeriod;
        emit SecurityPeriodChanged(_securityPeriod);
    }
    
    /**
     * @notice Get the escape status based on the ready_at timestamp
     * @param _readyAt Timestamp when the escape becomes ready
     * @return Status of the escape
     */
    enum EscapeStatus {
        None,
        NotReady,
        Ready,
        Expired
    }
    
    function _getEscapeStatus(uint256 _readyAt) internal view returns (EscapeStatus) {
        if (_readyAt == 0) {
            return EscapeStatus.None;
        }
        
        if (block.timestamp < _readyAt) {
            return EscapeStatus.NotReady;
        }
        
        if (block.timestamp <= _readyAt + securityPeriod) {
            return EscapeStatus.Ready;
        }
        
        return EscapeStatus.Expired;
    }

    /**
     * @notice Trigger an escape as the owner
     * @param _validator Address of the validator
     * @param _data Recovery data to be used when escape is completed
     */
    function triggerEscapeOwner(address _validator, bytes calldata _data) external {
        // Check if enough time has passed since the last owner trigger escape attempt
        // Only check if there was a previous attempt (timestamp > 0)
        if (lastOwnerTriggerEscapeAttempt[_validator] > 0 && 
            block.timestamp < lastOwnerTriggerEscapeAttempt[_validator] + TIME_BETWEEN_TWO_ESCAPES) {
            revert EscapeAttemptTooEarly();
        }
        
        // Check if there's a guardian escape in progress
        EscapeRequest storage request = escapeRequests[_validator];
        if (request.active && !request.isOwnerInitiated) {
            // If there's a guardian escape, ensure it's expired before allowing owner escape
            if (_getEscapeStatus(request.timestamp + request.securityPeriodSnapshot) != EscapeStatus.Expired) {
                revert("Cannot override non-expired guardian escape");
            }
        }
        
        // Reset the escape
        delete escapeRequests[_validator];
        
        // Create new escape request
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
        
        // Update the last owner trigger escape attempt timestamp
        lastOwnerTriggerEscapeAttempt[_validator] = block.timestamp;

        emit EscapeTriggered(_validator, msg.sender, true);
    }

    /**
     * @notice Trigger an escape as the guardian
     * @param _validator Address of the validator
     * @param _data Recovery data to be used when escape is completed
     */
    function triggerEscapeGuardian(address _validator, bytes calldata _data) external {
        // Check if enough time has passed since the last guardian trigger escape attempt
        // Only check if there was a previous attempt (timestamp > 0)
        if (lastGuardianTriggerEscapeAttempt[_validator] > 0 && 
            block.timestamp < lastGuardianTriggerEscapeAttempt[_validator] + TIME_BETWEEN_TWO_ESCAPES) {
            revert EscapeAttemptTooEarly();
        }
        
        // Reset the escape
        delete escapeRequests[_validator];
        
        // Create new escape request
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
        
        // Update the last guardian trigger escape attempt timestamp
        lastGuardianTriggerEscapeAttempt[_validator] = block.timestamp;

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
        
        // Check escape status
        EscapeStatus status = _getEscapeStatus(request.timestamp + request.securityPeriodSnapshot);
        if (status == EscapeStatus.NotReady) revert SecurityPeriodNotElapsed();
        if (status == EscapeStatus.Expired) revert EscapeExpired();

        bytes memory recoveryData = request.recoveryData;
        address initiator = request.initiator;
        bool isOwnerInitiated = request.isOwnerInitiated;

        // Clear the escape request
        delete escapeRequests[_validator];
        
        // Update the last owner escape timestamp
        lastOwnerEscapeAttempt[_validator] = block.timestamp;

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
        
        // Check escape status
        EscapeStatus status = _getEscapeStatus(request.timestamp + request.securityPeriodSnapshot);
        if (status == EscapeStatus.NotReady) revert SecurityPeriodNotElapsed();
        if (status == EscapeStatus.Expired) revert EscapeExpired();

        bytes memory recoveryData = request.recoveryData;
        address initiator = request.initiator;
        bool isOwnerInitiated = request.isOwnerInitiated;

        // Clear the escape request
        delete escapeRequests[_validator];
        
        // Update the last guardian escape timestamp
        lastGuardianEscapeAttempt[_validator] = block.timestamp;

        // Execute the recovery
        _executeRecovery(_validator, recoveryData);

        emit EscapeCompleted(_validator, initiator, isOwnerInitiated);
    }

    /**
     * @notice Cancel an active escape
     * @param _validator Address of the validator
     */
    function cancelEscape(address _validator) external {
        EscapeRequest storage request = escapeRequests[_validator];
        
        if (!request.active) revert NoActiveEscape();
        
        // Check if the escape status is not None
        EscapeStatus status = _getEscapeStatus(request.timestamp + request.securityPeriodSnapshot);
        if (status == EscapeStatus.None) revert InvalidEscapeType();
        
        // Clear the escape request
        delete escapeRequests[_validator];
        
        // Reset escape timestamps
        _resetEscapeTimestamps(_validator);
        
        emit EscapeCancelled(_validator);
    }
    
    /**
     * @notice Reset escape timestamps for a validator
     * @param _validator Address of the validator
     */
    function _resetEscapeTimestamps(address _validator) internal {
        lastOwnerEscapeAttempt[_validator] = 0;
        lastGuardianEscapeAttempt[_validator] = 0;
        lastOwnerTriggerEscapeAttempt[_validator] = 0;
        lastGuardianTriggerEscapeAttempt[_validator] = 0;
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
     * @notice Execute the recovery by uninstalling and reinstalling the validator
     * @param _validator Address of the validator
     * @param _data Recovery data to be used for installation
     */
    function _executeRecovery(address _validator, bytes memory _data) internal {
        IValidator(_validator).onUninstall(hex"");
        IValidator(_validator).onInstall(_data);
    }
}
