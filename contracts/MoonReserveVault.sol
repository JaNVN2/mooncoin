// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MoonCoin} from "./MoonCoin.sol";

/// @notice Dedicated promotional reserve; every release requires a timelocked campaign.
/// @dev campaignHash identifies the public announcement; publication must be checked operationally.
///      A recipient can subsequently transfer its tokens, so this contract only blocks direct Chef funding.
contract MoonReserveVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    MoonCoin public immutable moon;
    address public immutable timelock;
    uint256 public totalReleased;

    error UnauthorizedTimelock(address caller);
    error InvalidContract(address account);
    error InvalidRecipient(address recipient);
    error InvalidCampaign();
    error ZeroAmount();
    error MinterNotFinalized();

    event CampaignReleased(bytes32 indexed campaignHash, address indexed recipient, uint256 amount);

    constructor(MoonCoin moon_, address timelock_) {
        if (address(moon_).code.length == 0) revert InvalidContract(address(moon_));
        if (timelock_.code.length == 0) revert InvalidContract(timelock_);
        moon = moon_;
        timelock = timelock_;
    }

    function release(address recipient, uint256 amount, bytes32 campaignHash) external nonReentrant {
        if (msg.sender != timelock) revert UnauthorizedTimelock(msg.sender);
        address chef = moon.minter();
        if (chef == address(0)) revert MinterNotFinalized();
        if (recipient == address(0) || recipient == address(this) || recipient == chef) {
            revert InvalidRecipient(recipient);
        }
        if (amount == 0) revert ZeroAmount();
        if (campaignHash == bytes32(0)) revert InvalidCampaign();

        totalReleased += amount;
        emit CampaignReleased(campaignHash, recipient, amount);
        IERC20(address(moon)).safeTransfer(recipient, amount);
    }
}
