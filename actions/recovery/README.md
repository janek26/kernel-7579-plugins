# Recovery Action

## High-Level Specification

The Recovery Action is a plugin for Kernel v3 accounts that implements a secure recovery mechanism with escape modes and timelocks. It is based on the Argent Account recovery mechanism and provides a way to recover access to an account when a validator is compromised or lost.

The Recovery Action allows both owners and guardians to initiate an "escape" process that, after a security period, enables them to replace a validator. This provides a balance between security and recoverability, ensuring that users can regain access to their accounts in case of key loss while maintaining protection against unauthorized access.

By default, the security period is set to 7 days, but it can be customized by the user with a minimum of 10 minutes. This timelock provides a window during which the escape can be cancelled or overridden, adding an additional layer of security. Additionally, a 12-hour cooldown period between escape attempts prevents spam attacks.

The system is asymmetric in favor of the owner, who can override an escape triggered by a guardian, but not vice versa. This design choice reflects the assumption that the owner is the primary controller of the account.

## Key Features

- **Dual-party recovery**: Both owners and guardians can initiate the recovery process
- **Timelock security**: A mandatory waiting period before recovery can be completed
- **Escape expiration**: Escapes expire if not completed within a certain timeframe
- **Override capability**: Owners can override guardian-initiated escapes
- **Cancellation**: Any active escape can be cancelled by either party
- **Anti-spam protection**: A mandatory cooldown period between escape attempts

## Actions and Permissions

| Action                   | Owner | Guardian | Comments                                           |
| ------------------------ | ----- | -------- | -------------------------------------------------- |
| Trigger Escape Owner     | X     |          | Initiates recovery process as owner                |
| Trigger Escape Guardian  |       | X        | Initiates recovery process as guardian             |
| Escape Owner             | X     |          | Completes owner-initiated escape after timelock    |
| Escape Guardian          |       | X        | Completes guardian-initiated escape after timelock |
| Cancel Escape            | X     | X        | Either party can cancel an active escape           |
| Override Guardian Escape | X     |          | Owner can override guardian-initiated escape       |
| Set Security Period      | X     | X        | Changes the timelock duration                      |

## Recovery Process

1. **Initiation**: Either the owner or guardian triggers an escape for a specific validator
2. **Waiting Period**: The security period (default 7 days) must elapse before proceeding
3. **Completion**: After the security period, the initiator can complete the escape
4. **Execution**: The validator is uninstalled and reinstalled with new recovery data

During the waiting period, the escape can be:

- Cancelled by either the owner or guardian
- Overridden by the owner (if initiated by a guardian)
- Replaced by a new escape (which resets the waiting period)

If the escape is not completed within twice the security period, it expires and becomes invalid.

## Implementation Details

The Recovery Action implements the recovery process through a state machine pattern:

1. An escape request is stored in the contract's state with:

   - Timestamp of initiation
   - Initiator address
   - Flag indicating if owner-initiated
   - Recovery data for reinstallation
   - Active status flag
   - Security period snapshot (to handle period changes)

2. Escape timestamps are tracked to enforce cooldown periods:

   - Last owner escape attempt
   - Last guardian escape attempt
   - Last owner trigger escape attempt
   - Last guardian trigger escape attempt

3. When completing an escape, the contract:
   - Verifies the escape is active and not expired
   - Confirms the caller is the initiator
   - Ensures the security period has elapsed
   - Uninstalls the validator
   - Reinstalls the validator with the provided recovery data

## Security Considerations

- The security period provides a window for detecting and responding to unauthorized recovery attempts
- Escapes expire after twice the security period to prevent lingering recovery requests
- Only the initiator can complete an escape
- Owner can override guardian-initiated escapes, providing asymmetric control
- Security period changes do not affect active escapes, which use their snapshot value
- A mandatory cooldown period (12 hours) between escape attempts prevents spam attacks
- Minimum security period (10 minutes) ensures a reasonable timelock

## Tests

The Recovery Action includes comprehensive tests that verify all aspects of its functionality:

### Security Period Tests

- `testSetSecurityPeriod`: Verifies that the security period can be updated
- `testCannotSetBelowMinSecurityPeriod`: Ensures the security period cannot be set below the minimum
- `testCanSetMinSecurityPeriod`: Verifies that the security period can be set to the minimum value

### Owner Escape Tests

- `testTriggerEscapeOwner`: Verifies owner can initiate an escape
- `testEscapeOwnerBeforeSecurityPeriod`: Ensures escapes cannot be completed before the security period
- `testEscapeOwnerAfterSecurityPeriod`: Verifies escapes can be completed after the security period
- `testEscapeOwnerAfterExpiration`: Ensures escapes expire after twice the security period
- `testCannotCompleteOwnerEscapeAsGuardian`: Verifies guardians cannot complete owner-initiated escapes

### Guardian Escape Tests

- `testTriggerEscapeGuardian`: Verifies guardian can initiate an escape
- `testEscapeGuardianBeforeSecurityPeriod`: Ensures escapes cannot be completed before the security period
- `testEscapeGuardianAfterSecurityPeriod`: Verifies escapes can be completed after the security period
- `testEscapeGuardianAfterExpiration`: Ensures escapes expire after twice the security period
- `testCannotCompleteGuardianEscapeAsOwner`: Verifies owners cannot complete guardian-initiated escapes

### Cancel Escape Tests

- `testCancelOwnerEscape`: Verifies owner can cancel an owner-initiated escape
- `testCancelGuardianEscape`: Verifies guardian can cancel a guardian-initiated escape
- `testCannotCancelNonExistentEscape`: Verifies non-existent escapes cannot be cancelled

### Override Guardian Escape Tests

- `testOverrideGuardianEscape`: Verifies owner can override guardian escapes
- `testCannotOverrideOwnerEscape`: Ensures guardian escapes cannot override owner escapes
- `testCannotOverrideNonExistentEscape`: Verifies non-existent escapes cannot be overridden

### Multiple Escapes Tests

- `testOverwriteExistingEscape`: Verifies new escapes overwrite existing ones

### Recovery Failure Tests

- `testRevertOnInstallFailure`: Ensures recovery fails if validator installation fails
- `testRevertOnUninstallFailure`: Ensures recovery fails if validator uninstallation fails

### Escape Status Tests

- `testEscapeStatusTransitions`: Verifies the correct transitions between escape states (None, NotReady, Ready, Expired)

### Escape Cooldown Tests

- `testCannotTriggerEscapeOwnerTooEarly`: Ensures owner cannot trigger escapes too frequently
- `testCannotTriggerEscapeGuardianTooEarly`: Ensures guardian cannot trigger escapes too frequently

### Edge Cases Tests

- `testCannotCompleteNonExistentEscapeOwner`: Verifies non-existent owner escapes cannot be completed
- `testCannotCompleteNonExistentEscapeGuardian`: Verifies non-existent guardian escapes cannot be completed
- `testCannotCompleteEscapeAsNonInitiator`: Ensures only the initiator can complete an escape
- `testSecurityPeriodChangeAffectsActiveEscape`: Verifies security period changes don't affect active escapes
- `testEscapeWithZeroAddress`: Tests behavior with zero address validator
- `testEscapeWithEmptyData`: Tests behavior with empty recovery data
- `testEscapeWithComplexData`: Tests behavior with complex recovery data
- `testInitializationState`: Verifies validator initialization state after recovery

## Integration with Kernel v3

The Recovery Action is designed to work with Kernel v3 accounts and integrates with the validator system. When an escape is completed, the action:

1. Calls `onUninstall` on the validator to remove it
2. Calls `onInstall` with the recovery data to reinstall it with new parameters

This allows for seamless recovery without requiring changes to the account's core structure.

## Usage

To use the Recovery Action in your Kernel v3 account:

1. Deploy the RecoveryAction contract
2. Install it as an action in your Kernel account
3. Configure permissions to allow it to interact with your validators
4. Set the security period if you want to customize it from the default 7 days

## Development

### Setup Development Environment

1. **Clone the repository with submodules**

```shell
$ git clone --recurse-submodules -j8 https://github.com/your-repo/kernel-7579-plugins.git
$ cd kernel-7579-plugins/actions/recovery
```

2. **Install Foundry**

If you don't have Foundry installed, you can install it by running:

```shell
$ curl -L https://foundry.paradigm.xyz | bash
$ foundryup
```

3. **Install dependencies**

The project uses git submodules for dependencies. If you didn't clone with `--recurse-submodules`, you can initialize them with:

```shell
$ git submodule update --init --recursive
```

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```
