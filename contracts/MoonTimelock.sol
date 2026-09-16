// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

interface IMoonMultisigConfiguration {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory modules, address next);
}

/// @notice OpenZeppelin timelock with a permanent 48-hour floor and fixed multisig authority.
/// @dev The supplied multisig must be a verified Safe deployment; configuration introspection
///      cannot authenticate arbitrary bytecode or prove that the owners use separate devices.
contract MoonTimelock is TimelockController {
    uint256 public constant MINIMUM_DELAY = 48 hours;
    address private constant _SAFE_SENTINEL = address(1);
    address public immutable multisig;

    error InvalidMultisig(address candidate);
    error DelayBelowFloor(uint256 proposed);
    error FixedRole(bytes32 role, address account);

    constructor(address multisig_)
        TimelockController(MINIMUM_DELAY, _single(multisig_), _single(multisig_), address(0))
    {
        _validateMultisig(multisig_);
        multisig = multisig_;
    }

    /// @notice A scheduled operation may increase delay, but may never shorten it below 48 hours.
    function updateDelay(uint256 newDelay) public override {
        if (newDelay < MINIMUM_DELAY) revert DelayBelowFloor(newDelay);
        super.updateDelay(newDelay);
    }

    /// @notice Roles cannot be delegated to an EOA, opened to the public or assigned to another contract.
    /// @dev Signer rotation happens within the fixed Safe, preserving its required 2-of-3 policy.
    function grantRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        bool isAdmin = role == DEFAULT_ADMIN_ROLE && account == address(this);
        bool isOperator =
            (role == PROPOSER_ROLE || role == EXECUTOR_ROLE || role == CANCELLER_ROLE) && account == multisig;
        if (!isAdmin && !isOperator) revert FixedRole(role, account);
        super.grantRole(role, account);
    }

    /// @dev Changing the Safe threshold or owner count must never authorize a single signer here.
    ///      The Safe can restore its configuration independently; user withdrawals do not use this check.
    function _checkRole(bytes32 role, address account) internal view override {
        super._checkRole(role, account);
        if (role == PROPOSER_ROLE || role == EXECUTOR_ROLE || role == CANCELLER_ROLE) {
            _validateMultisig(multisig);
        }
    }

    function _validateMultisig(address candidate) private view {
        if (candidate.code.length == 0) revert InvalidMultisig(candidate);
        try IMoonMultisigConfiguration(candidate).getThreshold() returns (uint256 threshold) {
            if (threshold != 2) revert InvalidMultisig(candidate);
        } catch {
            revert InvalidMultisig(candidate);
        }
        try IMoonMultisigConfiguration(candidate).getOwners() returns (address[] memory owners) {
            if (owners.length != 3) revert InvalidMultisig(candidate);
            if (owners[0] == address(0) || owners[1] == address(0) || owners[2] == address(0)) {
                revert InvalidMultisig(candidate);
            }
            if (owners[0] == owners[1] || owners[0] == owners[2] || owners[1] == owners[2]) {
                revert InvalidMultisig(candidate);
            }
        } catch {
            revert InvalidMultisig(candidate);
        }
        // Safe modules may execute without the owner's signature threshold. None are allowed.
        try IMoonMultisigConfiguration(candidate).getModulesPaginated(_SAFE_SENTINEL, 1) returns (
            address[] memory modules, address next
        ) {
            if (modules.length != 0 || next != _SAFE_SENTINEL) revert InvalidMultisig(candidate);
        } catch {
            revert InvalidMultisig(candidate);
        }
    }

    function _single(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
