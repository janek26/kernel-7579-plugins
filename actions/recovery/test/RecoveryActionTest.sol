// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/RecoveryAction.sol";
import {IValidator} from "kernel/interfaces/IERC7579Modules.sol";
import {PackedUserOperation} from "kernel/interfaces/PackedUserOperation.sol";

// Mock validator to test the recovery action
contract MockValidator is IValidator {
    bool public uninstallCalled;
    bool public installCalled;
    bytes public lastInstallData;
    address public lastCaller;

    // Track if initialized for each account
    mapping(address => bool) public initialized;

    // Implementation of required IValidator functions
    function onInstall(bytes calldata data) external payable override {
        installCalled = true;
        lastInstallData = data;
        lastCaller = msg.sender;
        initialized[msg.sender] = true;
    }

    function onUninstall(bytes calldata) external payable override {
        uninstallCalled = true;
        lastCaller = msg.sender;
        initialized[msg.sender] = false;
    }

    // Other required interface functions with minimal implementations
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == 1; // Assuming 1 is for validator type
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return initialized[smartAccount];
    }

    function validateUserOp(PackedUserOperation calldata, bytes32) external payable override returns (uint256) {
        return 0; // Success
    }

    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0x1626ba7e; // Magic value for valid signature
    }

    // Reset the mock for testing
    function reset() external {
        uninstallCalled = false;
        installCalled = false;
        lastInstallData = "";
    }
}

// Mock validator that reverts on install
contract RevertingValidator is IValidator {
    error InstallFailed();
    error UninstallFailed();

    bool public shouldRevertOnInstall;
    bool public shouldRevertOnUninstall;

    constructor(bool _shouldRevertOnInstall, bool _shouldRevertOnUninstall) {
        shouldRevertOnInstall = _shouldRevertOnInstall;
        shouldRevertOnUninstall = _shouldRevertOnUninstall;
    }

    function onInstall(bytes calldata) external payable override {
        if (shouldRevertOnInstall) {
            revert InstallFailed();
        }
    }

    function onUninstall(bytes calldata) external payable override {
        if (shouldRevertOnUninstall) {
            revert UninstallFailed();
        }
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == 1;
    }

    function isInitialized(address) external pure override returns (bool) {
        return false;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32) external payable override returns (uint256) {
        return 0;
    }

    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure override returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract RecoveryActionTest is Test {
    RecoveryAction public recoveryAction;
    MockValidator public mockValidator;
    address public owner;
    address public guardian;
    uint256 public constant DEFAULT_SECURITY_PERIOD = 7 days;
    bytes public testData;

    event EscapeTriggered(address indexed validator, address initiator, bool isOwnerInitiated);
    event EscapeCompleted(address indexed validator, address initiator, bool isOwnerInitiated);
    event EscapeCancelled(address indexed validator);
    event EscapeOverridden(address indexed validator);
    event SecurityPeriodChanged(uint256 newSecurityPeriod);

    function setUp() external {
        recoveryAction = new RecoveryAction();
        mockValidator = new MockValidator();
        owner = makeAddr("Owner");
        guardian = makeAddr("Guardian");
        testData = abi.encode("new validator data");
    }

    // Helper function to advance time
    function _advanceTime(uint256 time) internal {
        vm.warp(block.timestamp + time);
    }

    // Helper function to check escape request state
    function _checkEscapeRequest(
        address validator,
        bool expectedActive,
        address expectedInitiator,
        bool expectedIsOwnerInitiated
    ) internal view {
        (, address initiator, bool isOwnerInitiated,, bool active,) = recoveryAction.escapeRequests(validator);

        assertEq(active, expectedActive, "Escape active state mismatch");
        if (expectedActive) {
            assertEq(initiator, expectedInitiator, "Escape initiator mismatch");
            assertEq(isOwnerInitiated, expectedIsOwnerInitiated, "Escape isOwnerInitiated mismatch");
        }
    }

    // ==================== Security Period Tests ====================

    function testSetSecurityPeriod() external {
        uint256 newPeriod = 14 days;

        vm.expectEmit(true, true, true, true);
        emit SecurityPeriodChanged(newPeriod);

        recoveryAction.setSecurityPeriod(newPeriod);
        assertEq(recoveryAction.securityPeriod(), newPeriod, "Security period not updated");
    }

    function testCannotSetZeroSecurityPeriod() external {
        vm.expectRevert(RecoveryAction.InvalidSecurityPeriod.selector);
        recoveryAction.setSecurityPeriod(0);
    }

    // ==================== Owner Escape Tests ====================

    function testTriggerEscapeOwner() external {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit EscapeTriggered(address(mockValidator), owner, true);

        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);
        vm.stopPrank();

        _checkEscapeRequest(address(mockValidator), true, owner, true);
    }

    function testEscapeOwnerBeforeSecurityPeriod() external {
        // Trigger escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Try to complete before security period
        vm.prank(owner);
        vm.expectRevert(RecoveryAction.SecurityPeriodNotElapsed.selector);
        recoveryAction.escapeOwner(address(mockValidator));

        // Validator should not be called
        assertFalse(mockValidator.uninstallCalled(), "onUninstall should not be called");
        assertFalse(mockValidator.installCalled(), "onInstall should not be called");
    }

    function testEscapeOwnerAfterSecurityPeriod() external {
        // Trigger escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Complete escape
        vm.expectEmit(true, true, true, true);
        emit EscapeCompleted(address(mockValidator), owner, true);

        vm.prank(owner);
        recoveryAction.escapeOwner(address(mockValidator));

        // Validator should be called
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastInstallData(), testData, "Install data mismatch");

        // Escape request should be cleared
        _checkEscapeRequest(address(mockValidator), false, address(0), false);
    }

    function testEscapeOwnerAfterExpiration() external {
        // Trigger escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Advance time past expiration (2 * security period)
        _advanceTime(2 * DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete after expiration
        vm.prank(owner);
        vm.expectRevert(RecoveryAction.EscapeExpired.selector);
        recoveryAction.escapeOwner(address(mockValidator));
    }

    function testCannotCompleteOwnerEscapeAsGuardian() external {
        // Trigger owner escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete as guardian using escapeGuardian
        vm.prank(guardian);
        vm.expectRevert(RecoveryAction.NotEscapeInitiator.selector);
        recoveryAction.escapeGuardian(address(mockValidator));
    }

    // ==================== Guardian Escape Tests ====================

    function testTriggerEscapeGuardian() external {
        vm.startPrank(guardian);

        vm.expectEmit(true, true, true, true);
        emit EscapeTriggered(address(mockValidator), guardian, false);

        recoveryAction.triggerEscapeGuardian(address(mockValidator), testData);
        vm.stopPrank();

        _checkEscapeRequest(address(mockValidator), true, guardian, false);
    }

    function testEscapeGuardianBeforeSecurityPeriod() external {
        // Trigger escape
        vm.prank(guardian);
        recoveryAction.triggerEscapeGuardian(address(mockValidator), testData);

        // Try to complete before security period
        vm.prank(guardian);
        vm.expectRevert(RecoveryAction.SecurityPeriodNotElapsed.selector);
        recoveryAction.escapeGuardian(address(mockValidator));

        // Validator should not be called
        assertFalse(mockValidator.uninstallCalled(), "onUninstall should not be called");
        assertFalse(mockValidator.installCalled(), "onInstall should not be called");
    }

    function testEscapeGuardianAfterSecurityPeriod() external {
        // Trigger escape
        vm.prank(guardian);
        recoveryAction.triggerEscapeGuardian(address(mockValidator), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Complete escape
        vm.expectEmit(true, true, true, true);
        emit EscapeCompleted(address(mockValidator), guardian, false);

        vm.prank(guardian);
        recoveryAction.escapeGuardian(address(mockValidator));

        // Validator should be called
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastInstallData(), testData, "Install data mismatch");

        // Escape request should be cleared
        _checkEscapeRequest(address(mockValidator), false, address(0), false);
    }

    function testEscapeGuardianAfterExpiration() external {
        // Trigger escape
        vm.prank(guardian);
        recoveryAction.triggerEscapeGuardian(address(mockValidator), testData);

        // Advance time past expiration (2 * security period)
        _advanceTime(2 * DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete after expiration
        vm.prank(guardian);
        vm.expectRevert(RecoveryAction.EscapeExpired.selector);
        recoveryAction.escapeGuardian(address(mockValidator));
    }

    function testCannotCompleteGuardianEscapeAsOwner() external {
        // Trigger guardian escape
        vm.prank(guardian);
        recoveryAction.triggerEscapeGuardian(address(mockValidator), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete as owner using escapeOwner
        vm.prank(owner);
        vm.expectRevert(RecoveryAction.NotEscapeInitiator.selector);
        recoveryAction.escapeOwner(address(mockValidator));
    }

    // ==================== Cancel Escape Tests ====================

    function testCancelOwnerEscape() external {
        // Trigger owner escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Cancel escape
        vm.expectEmit(true, true, true, true);
        emit EscapeCancelled(address(mockValidator));

        vm.prank(owner);
        recoveryAction.cancelEscape(address(mockValidator));

        // Escape request should be cleared
        _checkEscapeRequest(address(mockValidator), false, address(0), false);
    }

    function testCancelGuardianEscape() external {
        // Trigger guardian escape
        vm.prank(guardian);
        recoveryAction.triggerEscapeGuardian(address(mockValidator), testData);

        // Cancel escape
        vm.expectEmit(true, true, true, true);
        emit EscapeCancelled(address(mockValidator));

        vm.prank(guardian);
        recoveryAction.cancelEscape(address(mockValidator));

        // Escape request should be cleared
        _checkEscapeRequest(address(mockValidator), false, address(0), false);
    }

    function testCancelEscapeByAnyParty() external {
        // Trigger owner escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Cancel escape by guardian
        vm.prank(guardian);
        recoveryAction.cancelEscape(address(mockValidator));

        // Escape request should be cleared
        _checkEscapeRequest(address(mockValidator), false, address(0), false);
    }

    function testCannotCancelNonExistentEscape() external {
        vm.expectRevert(RecoveryAction.NoActiveEscape.selector);
        recoveryAction.cancelEscape(address(mockValidator));
    }

    // ==================== Override Guardian Escape Tests ====================

    function testOverrideGuardianEscape() external {
        // Trigger guardian escape
        vm.prank(guardian);
        recoveryAction.triggerEscapeGuardian(address(mockValidator), testData);

        // Override escape
        vm.expectEmit(true, true, true, true);
        emit EscapeOverridden(address(mockValidator));

        vm.prank(owner);
        recoveryAction.overrideGuardianEscape(address(mockValidator));

        // Escape request should be cleared
        _checkEscapeRequest(address(mockValidator), false, address(0), false);
    }

    function testCannotOverrideOwnerEscape() external {
        // Trigger owner escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Try to override owner escape
        vm.prank(guardian);
        vm.expectRevert(RecoveryAction.CannotOverrideOwnerEscape.selector);
        recoveryAction.overrideGuardianEscape(address(mockValidator));
    }

    function testCannotOverrideNonExistentEscape() external {
        vm.expectRevert(RecoveryAction.NoActiveEscape.selector);
        recoveryAction.overrideGuardianEscape(address(mockValidator));
    }

    // ==================== Multiple Escapes Tests ====================

    function testOverwriteExistingEscape() external {
        // Trigger owner escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Overwrite with guardian escape
        bytes memory newData = abi.encode("newer validator data");
        vm.prank(guardian);
        recoveryAction.triggerEscapeGuardian(address(mockValidator), newData);

        // Check that the escape was overwritten
        _checkEscapeRequest(address(mockValidator), true, guardian, false);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Complete escape
        vm.prank(guardian);
        recoveryAction.escapeGuardian(address(mockValidator));

        // Validator should be called with new data
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastInstallData(), newData, "Install data mismatch");
    }

    // ==================== Recovery Failure Tests ====================

    function testRevertOnInstallFailure() external {
        RevertingValidator revertingValidator = new RevertingValidator(true, false);

        // Trigger escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(revertingValidator), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete escape
        vm.prank(owner);
        vm.expectRevert(RevertingValidator.InstallFailed.selector);
        recoveryAction.escapeOwner(address(revertingValidator));
    }

    function testRevertOnUninstallFailure() external {
        RevertingValidator revertingValidator = new RevertingValidator(false, true);

        // Trigger escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(revertingValidator), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete escape
        vm.prank(owner);
        vm.expectRevert(RevertingValidator.UninstallFailed.selector);
        recoveryAction.escapeOwner(address(revertingValidator));
    }

    // ==================== Edge Cases Tests ====================

    function testCannotCompleteNonExistentEscapeOwner() external {
        vm.prank(owner);
        vm.expectRevert(RecoveryAction.NoActiveEscape.selector);
        recoveryAction.escapeOwner(address(mockValidator));
    }

    function testCannotCompleteNonExistentEscapeGuardian() external {
        vm.prank(guardian);
        vm.expectRevert(RecoveryAction.NoActiveEscape.selector);
        recoveryAction.escapeGuardian(address(mockValidator));
    }

    function testCannotCompleteEscapeAsNonInitiator() external {
        // Trigger owner escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete as a different address
        address randomUser = makeAddr("RandomUser");
        vm.prank(randomUser);
        vm.expectRevert(RecoveryAction.NotEscapeInitiator.selector);
        recoveryAction.escapeOwner(address(mockValidator));
    }

    function testSecurityPeriodChangeAffectsActiveEscape() external {
        // Trigger owner escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Change security period to a shorter value
        uint256 newPeriod = 1 days;
        recoveryAction.setSecurityPeriod(newPeriod);

        // Advance time past new security period but not past original
        _advanceTime(newPeriod + 1);

        // Try to complete escape - should still use the original security period
        vm.prank(owner);
        vm.expectRevert(RecoveryAction.SecurityPeriodNotElapsed.selector);
        recoveryAction.escapeOwner(address(mockValidator));

        // Advance time to pass the original security period
        _advanceTime(DEFAULT_SECURITY_PERIOD - newPeriod);

        // Now it should work
        vm.prank(owner);
        recoveryAction.escapeOwner(address(mockValidator));

        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
    }

    function testEscapeWithZeroAddress() external {
        // Trigger escape with zero address validator
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(0), testData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Try to complete escape
        vm.prank(owner);
        vm.expectRevert(); // Should revert when trying to call a function on address(0)
        recoveryAction.escapeOwner(address(0));
    }

    function testEscapeWithEmptyData() external {
        bytes memory emptyData = "";

        // Trigger escape with empty data
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), emptyData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Complete escape
        vm.prank(owner);
        recoveryAction.escapeOwner(address(mockValidator));

        // Validator should be called with empty data
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastInstallData(), emptyData, "Install data should be empty");
    }

    function testEscapeWithComplexData(bytes memory complexData) external {
        vm.assume(complexData.length > 0 && complexData.length < 1000); // Reasonable size for test

        mockValidator.reset();

        // Trigger escape with complex data
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), complexData);

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Complete escape
        vm.prank(owner);
        recoveryAction.escapeOwner(address(mockValidator));

        // Validator should be called with complex data
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastInstallData(), complexData, "Install data mismatch");
    }

    function testInitializationState() external {
        // Trigger escape
        vm.prank(owner);
        recoveryAction.triggerEscapeOwner(address(mockValidator), testData);

        // Check initial state
        assertFalse(mockValidator.isInitialized(address(recoveryAction)), "Should not be initialized initially");

        // Advance time past security period
        _advanceTime(DEFAULT_SECURITY_PERIOD + 1);

        // Complete escape
        vm.prank(owner);
        recoveryAction.escapeOwner(address(mockValidator));

        // After recovery, the validator should be initialized for the recovery action
        assertTrue(mockValidator.isInitialized(address(recoveryAction)), "Should be initialized after recovery");
    }
}
