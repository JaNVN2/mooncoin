// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal, permissionless constant-product AMM for a single MOON / native-ETH pair.
/// @dev The pool contract is itself the ERC20 LP token, mirroring UniswapV2Pair. No admin,
///      fee-switch or pause exists; reserves are cached and only advance via _sync() so a
///      bare ETH/token donation cannot move price until a real interaction occurs.
contract MoonEthPool is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant FEE_NUMERATOR = 975;
    uint256 public constant FEE_DENOMINATOR = 1000;
    address public constant BURN_ADDRESS = address(0xdead);

    IERC20 public immutable moon;

    uint256 public reserveMoon;
    uint256 public reserveEth;

    error InvalidToken(address token);
    error InvalidRecipient(address recipient);
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error EthTransferFailed();

    event Mint(address indexed sender, uint256 moonIn, uint256 ethIn, uint256 liquidity);
    event Burn(address indexed sender, uint256 moonOut, uint256 ethOut, uint256 liquidity, address indexed to);
    event Swap(
        address indexed sender, uint256 moonIn, uint256 ethIn, uint256 moonOut, uint256 ethOut, address indexed to
    );
    event Sync(uint256 reserveMoon, uint256 reserveEth);

    constructor(IERC20 moon_) ERC20("MOON/ETH LP", "MOON-ETH-LP") {
        if (address(moon_).code.length == 0) revert InvalidToken(address(moon_));
        moon = moon_;
    }

    /// @notice Adds liquidity at the pool's current ratio (or seeds it, on the first call).
    /// @dev Excess ETH beyond the amount actually used is refunded to the caller.
    function addLiquidity(uint256 moonDesired, uint256 moonMin, uint256 ethMin, address to)
        external
        payable
        nonReentrant
        returns (uint256 moonUsed, uint256 ethUsed, uint256 liquidity)
    {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (moonDesired == 0 || msg.value == 0) revert InsufficientInputAmount();

        uint256 cachedMoon = reserveMoon;
        uint256 cachedEth = reserveEth;

        if (cachedMoon == 0 && cachedEth == 0) {
            moonUsed = moonDesired;
            ethUsed = msg.value;
        } else {
            uint256 ethOptimal = Math.mulDiv(moonDesired, cachedEth, cachedMoon);
            if (ethOptimal <= msg.value) {
                if (ethOptimal < ethMin) revert SlippageExceeded();
                moonUsed = moonDesired;
                ethUsed = ethOptimal;
            } else {
                uint256 moonOptimal = Math.mulDiv(msg.value, cachedMoon, cachedEth);
                if (moonOptimal < moonMin || moonOptimal > moonDesired) revert SlippageExceeded();
                moonUsed = moonOptimal;
                ethUsed = msg.value;
            }
        }

        moon.safeTransferFrom(msg.sender, address(this), moonUsed);

        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(moonUsed * ethUsed) - MINIMUM_LIQUIDITY;
            _mint(BURN_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(Math.mulDiv(moonUsed, supply, cachedMoon), Math.mulDiv(ethUsed, supply, cachedEth));
        }
        if (liquidity == 0) revert InsufficientLiquidity();
        _mint(to, liquidity);

        if (msg.value > ethUsed) _sendEth(msg.sender, msg.value - ethUsed);

        _sync();
        emit Mint(msg.sender, moonUsed, ethUsed, liquidity);
    }

    /// @notice Burns LP shares for a proportional slice of both reserves.
    function removeLiquidity(uint256 liquidity, uint256 moonMin, uint256 ethMin, address to)
        external
        nonReentrant
        returns (uint256 moonOut, uint256 ethOut)
    {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (liquidity == 0) revert InsufficientLiquidity();

        uint256 supply = totalSupply();
        moonOut = Math.mulDiv(liquidity, reserveMoon, supply);
        ethOut = Math.mulDiv(liquidity, reserveEth, supply);
        if (moonOut == 0 || ethOut == 0) revert InsufficientLiquidity();
        if (moonOut < moonMin || ethOut < ethMin) revert SlippageExceeded();

        _burn(msg.sender, liquidity);
        moon.safeTransfer(to, moonOut);
        _sendEth(to, ethOut);

        _sync();
        emit Burn(msg.sender, moonOut, ethOut, liquidity, to);
    }

    /// @notice Swaps exact native ETH for MOON, at the constant-product price minus the 2.5% fee.
    function swapExactEthForMoon(uint256 moonMinOut, address to)
        external
        payable
        nonReentrant
        returns (uint256 moonOut)
    {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (msg.value == 0) revert InsufficientInputAmount();
        uint256 cachedMoon = reserveMoon;
        uint256 cachedEth = reserveEth;
        if (cachedMoon == 0 || cachedEth == 0) revert InsufficientLiquidity();

        uint256 ethInWithFee = msg.value * FEE_NUMERATOR;
        moonOut = Math.mulDiv(ethInWithFee, cachedMoon, cachedEth * FEE_DENOMINATOR + ethInWithFee);
        if (moonOut == 0) revert InsufficientOutputAmount();
        if (moonOut < moonMinOut) revert SlippageExceeded();

        moon.safeTransfer(to, moonOut);
        _sync();
        emit Swap(msg.sender, 0, msg.value, moonOut, 0, to);
    }

    /// @notice Swaps an exact amount of MOON for native ETH, at the constant-product price minus the 2.5% fee.
    function swapExactMoonForEth(uint256 moonIn, uint256 ethMinOut, address to)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (moonIn == 0) revert InsufficientInputAmount();
        uint256 cachedMoon = reserveMoon;
        uint256 cachedEth = reserveEth;
        if (cachedMoon == 0 || cachedEth == 0) revert InsufficientLiquidity();

        moon.safeTransferFrom(msg.sender, address(this), moonIn);
        uint256 moonInWithFee = moonIn * FEE_NUMERATOR;
        ethOut = Math.mulDiv(moonInWithFee, cachedEth, cachedMoon * FEE_DENOMINATOR + moonInWithFee);
        if (ethOut == 0) revert InsufficientOutputAmount();
        if (ethOut < ethMinOut) revert SlippageExceeded();

        _sendEth(to, ethOut);
        _sync();
        emit Swap(msg.sender, moonIn, 0, 0, ethOut, to);
    }

    function getReserves() external view returns (uint256 reserveMoon_, uint256 reserveEth_) {
        return (reserveMoon, reserveEth);
    }

    function _sync() private {
        reserveMoon = moon.balanceOf(address(this));
        reserveEth = address(this).balance;
        emit Sync(reserveMoon, reserveEth);
    }

    function _sendEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = to.call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }
}
