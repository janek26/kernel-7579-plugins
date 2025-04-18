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

    function validateUserOp(PackedUserOperation calldata, bytes32) 
        external payable override returns (uint256) {
        return 0; // Success
    }

    function isValidSignatureWithSender(address, bytes32, bytes calldata) 
        external pure override returns (bytes4) {
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

    function validateUserOp(PackedUserOperation calldata, bytes32) 
        external payable override returns (uint256) {
        return 0;
    }

    function isValidSignatureWithSender(address, bytes32, bytes calldata) 
        external pure override returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract RecoveryActionTest is Test {
    RecoveryAction public recoveryAction;
    MockValidator public mockValidator;
    address public user;

    function setUp() external {
        recoveryAction = new RecoveryAction();
        mockValidator = new MockValidator();
        user = makeAddr("User");
    }

    function testDoRecovery() external {
        bytes memory testData = abi.encode("new validator data");
        
        vm.startPrank(user);
        recoveryAction.doRecovery(address(mockValidator), testData);
        vm.stopPrank();
        
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastCaller(), address(recoveryAction), "Caller address mismatch");
        assertEq(mockValidator.lastInstallData(), testData, "Install data mismatch");
    }

    function testDoRecoveryWithEmptyData() external {
        bytes memory emptyData = "";
        
        vm.startPrank(user);
        recoveryAction.doRecovery(address(mockValidator), emptyData);
        vm.stopPrank();
        
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastInstallData(), emptyData, "Install data should be empty");
    }

    function testDoRecoveryWithComplexData(bytes memory complexData) external {
        vm.assume(complexData.length > 0 && complexData.length < 1000); // Reasonable size for test
        
        mockValidator.reset();
        
        vm.startPrank(user);
        recoveryAction.doRecovery(address(mockValidator), complexData);
        vm.stopPrank();
        
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastInstallData(), complexData, "Install data mismatch");
    }

    function testDoRecoveryFromDifferentCallers(address caller) external {
        vm.assume(caller != address(0));
        
        bytes memory testData = abi.encode("test data");
        mockValidator.reset();
        
        vm.startPrank(caller);
        recoveryAction.doRecovery(address(mockValidator), testData);
        vm.stopPrank();
        
        assertTrue(mockValidator.uninstallCalled(), "onUninstall was not called");
        assertTrue(mockValidator.installCalled(), "onInstall was not called");
        assertEq(mockValidator.lastCaller(), address(recoveryAction), "Caller should be the recovery action");
    }

    function testRevertOnInstallFailure() external {
        RevertingValidator revertingValidator = new RevertingValidator(true, false);
        bytes memory testData = abi.encode("test data");
        
        vm.startPrank(user);
        vm.expectRevert(RevertingValidator.InstallFailed.selector);
        recoveryAction.doRecovery(address(revertingValidator), testData);
        vm.stopPrank();
    }

    function testRevertOnUninstallFailure() external {
        RevertingValidator revertingValidator = new RevertingValidator(false, true);
        bytes memory testData = abi.encode("test data");
        
        vm.startPrank(user);
        vm.expectRevert(RevertingValidator.UninstallFailed.selector);
        recoveryAction.doRecovery(address(revertingValidator), testData);
        vm.stopPrank();
    }

    function testDoRecoveryWithZeroAddress() external {
        bytes memory testData = abi.encode("test data");
        
        vm.startPrank(user);
        vm.expectRevert(); // Should revert when trying to call a function on address(0)
        recoveryAction.doRecovery(address(0), testData);
        vm.stopPrank();
    }

    function testInitializationState() external {
        bytes memory testData = abi.encode("test data");
        
        // Check initial state
        assertFalse(mockValidator.isInitialized(address(recoveryAction)), "Should not be initialized initially");
        
        vm.startPrank(user);
        recoveryAction.doRecovery(address(mockValidator), testData);
        vm.stopPrank();
        
        // After recovery, the validator should be initialized for the recovery action
        assertTrue(mockValidator.isInitialized(address(recoveryAction)), "Should be initialized after recovery");
    }
}
