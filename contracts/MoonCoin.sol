// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";

interface IMoonMinter {
    function moon() external view returns (address);
}

/// @notice Fixed-cap ERC20 with an atomic, one-time premint and an irreversible MasterChef handoff.
contract MoonCoin is ERC20, ERC20Capped, ERC20Burnable {
    uint256 public constant MAX_SUPPLY = 100_000_000_000_000 ether;
    uint256 public constant PREMINT_SUPPLY = 10_000_000 ether;
    uint256 public constant TEAM_ALLOCATION = 1_000_000 ether;
    uint256 public constant LIQUIDITY_ALLOCATION = 1_000_000 ether;
    uint256 public constant TREASURY_ALLOCATION = 3_000_000 ether;
    uint256 public constant RESERVE_ALLOCATION = 5_000_000 ether;

    address public immutable bootstrapAuthority;
    address public minter;
    bool public premintCompleted;

    error UnauthorizedBootstrap(address caller);
    error UnauthorizedMinter(address caller);
    error PremintAlreadyCompleted();
    error PremintRequired();
    error MinterAlreadyFinalized();
    error InvalidAddress(address account);
    error InvalidMinter(address candidate);

    event PremintCompleted(address indexed team, address indexed liquidity, address indexed treasury, address reserve);
    event MinterFinalized(address indexed minter);
    event EmissionMinted(address indexed recipient, uint256 amount);

    constructor() ERC20("MoonCoin", "MOON") ERC20Capped(MAX_SUPPLY) {
        bootstrapAuthority = msg.sender;
    }

    modifier onlyBootstrap() {
        if (msg.sender != bootstrapAuthority) revert UnauthorizedBootstrap(msg.sender);
        _;
    }

    /// @notice Mints all four fixed allocations atomically; the team allocation has no vesting.
    function premint(address team, address liquidity, address treasury, address reserve) external onlyBootstrap {
        if (premintCompleted) revert PremintAlreadyCompleted();
        if (team == address(0)) revert InvalidAddress(team);
        if (liquidity == address(0)) revert InvalidAddress(liquidity);
        if (treasury == address(0)) revert InvalidAddress(treasury);
        if (reserve == address(0)) revert InvalidAddress(reserve);

        premintCompleted = true;
        _mint(team, TEAM_ALLOCATION);
        _mint(liquidity, LIQUIDITY_ALLOCATION);
        _mint(treasury, TREASURY_ALLOCATION);
        _mint(reserve, RESERVE_ALLOCATION);
        emit PremintCompleted(team, liquidity, treasury, reserve);
    }

    /// @notice Finalizes the sole future minter. No owner, rotation or additional minter exists.
    /// @dev Matching moon() prevents wiring errors; bytecode verification of the candidate is also required.
    function finalizeMinter(address candidate) external onlyBootstrap {
        if (!premintCompleted) revert PremintRequired();
        if (minter != address(0)) revert MinterAlreadyFinalized();
        if (candidate.code.length == 0) revert InvalidMinter(candidate);
        try IMoonMinter(candidate).moon() returns (address configuredToken) {
            if (configuredToken != address(this)) revert InvalidMinter(candidate);
        } catch {
            revert InvalidMinter(candidate);
        }
        minter = candidate;
        emit MinterFinalized(candidate);
    }

    function mint(address recipient, uint256 amount) external {
        if (msg.sender != minter) revert UnauthorizedMinter(msg.sender);
        _mint(recipient, amount);
        emit EmissionMinted(recipient, amount);
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Capped) {
        super._update(from, to, amount);
    }
}
