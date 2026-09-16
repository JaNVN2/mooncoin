// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MoonCoin} from "./MoonCoin.sol";
import {MoonTimelock} from "./MoonTimelock.sol";

/// @notice SmartCoin V1-inspired TVL emissions with a capped manual fallback.
/// @dev PID1 is an ERC20 integration boundary, NOT a Uniswap V3/V4 NFT adapter.
contract MoonMasterChef is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_EMISSION_RATE = 10 ether;
    uint256 public constant MAX_WITHDRAWAL_FEE_BPS = 700;
    uint256 public constant BPS = 10_000;
    uint256 public constant TOTAL_ALLOC_POINT = 1000;
    uint256 public constant ACC_PRECISION = 1e24;
    uint256 public constant USD_PRECISION = 1e18;
    uint256 public constant FIRST_TVL_STEP_USD = 50_000 ether;
    uint256 public constant FIRST_TIER_APR_BPS = 5_000;
    uint256 public constant TVL_STEP_USD = 100_000 ether;
    uint256 public constant MAX_APR_MULTIPLIER = 1024;
    uint256 public constant MAX_USD_PRICE = 1_000_000_000 ether;
    uint256 public constant MAX_VALUATION_AGE = 1 days;

    struct PoolInfo {
        IERC20 token;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accMoonPerShare;
        uint256 totalStaked;
    }

    struct UserInfo {
        uint256 amount;
        // Accumulator snapshot, not the traditional amount * accumulator reward debt.
        uint256 rewardDebt;
        uint256 unpaidRewards;
    }

    MoonCoin public immutable moon;
    address public immutable timelock;
    uint256 public immutable startTime;
    PoolInfo[2] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => mapping(address => uint256)) public rewardRemainder;
    mapping(address => uint256) public claimableBeneficiary;
    uint256 public beneficiaryReserve;
    uint256 public rewardReserve;
    uint256 public totalEmitted;
    uint256 public moonPerSecond;
    uint256 public devBps = 2000;
    uint256 public treasuryBps = 2000;
    uint256 public investorBps = 1000;
    uint256 public withdrawFeeBps = MAX_WITHDRAWAL_FEE_BPS;
    address public dev;
    address public treasury;
    address public investor;
    address public feeTreasury;
    address public guardian;
    address public emissionUpdater;
    uint256 public moonPriceUsd;
    uint256[2] public poolTokenPriceUsd;
    uint256 public valuationUpdatedAt;
    bool public automaticEmission;
    bool public paused;

    error Unauthorized();
    error InvalidAddress();
    error InvalidPool();
    error InvalidParameter();
    error DepositsAndHarvestsPaused();
    error MintNotFinalized();
    error InsufficientStake();
    error UnsupportedToken();
    error RewardAccountingDeficit();

    event PoolConfigured(uint256 indexed pid, address indexed token, uint256 points);
    event PoolUpdated(
        uint256 indexed pid, uint256 timestamp, uint256 grossReward, uint256 userReward, uint256 accumulator
    );
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 grossAmount, uint256 fee);
    event EmergencyWithdraw(
        address indexed user, uint256 indexed pid, uint256 grossAmount, uint256 fee, uint256 forfeited
    );
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event BeneficiaryAccrued(address indexed beneficiary, uint256 amount);
    event BeneficiaryClaimed(address indexed beneficiary, uint256 amount);
    event EmissionRateChanged(uint256 oldRate, uint256 newRate);
    event AutomaticEmissionChanged(bool enabled);
    event EmissionUpdaterChanged(address indexed previousUpdater, address indexed newUpdater);
    event ValuationUpdated(address indexed updater, uint256 moonPriceUsd, uint256 lpPriceUsd, uint256 timestamp);
    event SharesChanged(uint256 devBps, uint256 treasuryBps, uint256 investorBps);
    event WithdrawalFeeChanged(uint256 oldFee, uint256 newFee);
    event AllocationChanged(uint256 moonPoints, uint256 lpPoints);
    event BeneficiariesChanged(address dev, address treasury, address investor, address feeTreasury);
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event PauseChanged(address indexed caller, bool paused);

    constructor(
        MoonCoin moon_,
        IERC20 lpToken,
        address timelock_,
        address dev_,
        address treasury_,
        address investor_,
        address feeTreasury_,
        address guardian_,
        uint256 startTime_,
        address emissionUpdater_,
        bool automaticEmission_
    ) {
        if (
            address(moon_).code.length == 0 || address(lpToken).code.length == 0 || address(moon_) == address(lpToken)
                || timelock_.code.length == 0
        ) revert InvalidAddress();
        if (MoonTimelock(payable(timelock_)).getMinDelay() < 48 hours) revert InvalidParameter();
        moon = moon_;
        timelock = timelock_;
        _validRecipient(dev_);
        _validRecipient(treasury_);
        _validRecipient(investor_);
        _validRecipient(feeTreasury_);
        _validRecipient(guardian_);
        _validRecipient(emissionUpdater_);
        if (startTime_ < block.timestamp) revert InvalidParameter();
        dev = dev_;
        treasury = treasury_;
        investor = investor_;
        feeTreasury = feeTreasury_;
        guardian = guardian_;
        emissionUpdater = emissionUpdater_;
        automaticEmission = automaticEmission_;
        moonPerSecond = automaticEmission_ ? 0 : MAX_EMISSION_RATE;
        startTime = startTime_;
        poolInfo[0] = PoolInfo(IERC20(address(moon_)), 300, startTime_, 0, 0);
        poolInfo[1] = PoolInfo(lpToken, 700, startTime_, 0, 0);
        emit PoolConfigured(0, address(moon_), 300);
        emit PoolConfigured(1, address(lpToken), 700);
        emit BeneficiariesChanged(dev_, treasury_, investor_, feeTreasury_);
        emit GuardianChanged(address(0), guardian_);
        emit EmissionUpdaterChanged(address(0), emissionUpdater_);
        emit AutomaticEmissionChanged(automaticEmission_);
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert Unauthorized();
        _;
    }

    function poolLength() external pure returns (uint256) {
        return 2;
    }

    function totalAllocPoint() external pure returns (uint256) {
        return TOTAL_ALLOC_POINT;
    }

    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        _validPool(pid);
        if (paused) revert DepositsAndHarvestsPaused();
        if (moon.minter() != address(this)) revert MintNotFinalized();
        uint256 minted = _checkpoint();
        _settle(pid, msg.sender);
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        user.amount += amount;
        pool.totalStaked += amount;
        _recalculateEmission();
        _mintRewards(minted);
        if (amount != 0) {
            uint256 balanceBefore = pool.token.balanceOf(address(this));
            uint256 senderBefore = pool.token.balanceOf(msg.sender);
            pool.token.safeTransferFrom(msg.sender, address(this), amount);
            if (
                pool.token.balanceOf(address(this)) != balanceBefore + amount
                    || pool.token.balanceOf(msg.sender) != senderBefore - amount
            ) revert UnsupportedToken();
        }
        emit Deposit(msg.sender, pid, amount);
    }

    /// @notice Withdraw principal regardless of pause. Rewards remain claimable separately.
    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        _validPool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        if (amount > user.amount) revert InsufficientStake();
        uint256 minted = _checkpoint();
        _settle(pid, msg.sender);
        user.amount -= amount;
        poolInfo[pid].totalStaked -= amount;
        _recalculateEmission();
        _mintRewards(minted);
        uint256 fee = _returnPrincipal(pid, msg.sender, amount);
        emit Withdraw(msg.sender, pid, amount, fee);
    }

    /// @notice Exit while paused, forfeiting earned rewards. No reward/beneficiary transfer.
    /// @dev Bounded checkpoint calls only the immutable, capped MoonCoin, never an LP/rewarder.
    function emergencyWithdraw(uint256 pid) external nonReentrant {
        _validPool(pid);
        uint256 minted = _checkpoint();
        _settle(pid, msg.sender);
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        uint256 forfeited = user.unpaidRewards;
        user.amount = 0;
        user.unpaidRewards = 0;
        rewardRemainder[pid][msg.sender] = 0;
        poolInfo[pid].totalStaked -= amount;
        _recalculateEmission();
        _mintRewards(minted);
        // Forfeitures/accumulator dust remain in rewardReserve, never principal or re-emitted.
        uint256 fee = _returnPrincipal(pid, msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, fee, forfeited);
    }

    function harvest(uint256 pid) external nonReentrant {
        _validPool(pid);
        if (paused) revert DepositsAndHarvestsPaused();
        uint256 minted = _checkpoint();
        _settle(pid, msg.sender);
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.unpaidRewards;
        if (amount > rewardReserve) revert RewardAccountingDeficit();
        user.unpaidRewards = 0;
        rewardReserve -= amount;
        _mintRewards(minted);
        if (amount != 0) IERC20(address(moon)).safeTransfer(msg.sender, amount);
        emit Harvest(msg.sender, pid, amount);
    }

    function claimBeneficiary() external nonReentrant {
        uint256 amount = claimableBeneficiary[msg.sender];
        claimableBeneficiary[msg.sender] = 0;
        beneficiaryReserve -= amount;
        if (amount != 0) IERC20(address(moon)).safeTransfer(msg.sender, amount);
        emit BeneficiaryClaimed(msg.sender, amount);
    }

    function updatePools() external nonReentrant {
        _mintRewards(_checkpoint());
    }

    function pendingMoon(uint256 pid, address account) external view returns (uint256) {
        _validPool(pid);
        (uint256 r0, uint256 r1) = _nextRewards();
        PoolInfo storage pool = poolInfo[pid];
        uint256 accumulator = pool.accMoonPerShare;
        if (pool.totalStaked != 0) {
            uint256 gross = pid == 0 ? r0 : r1;
            uint256 users = gross - Math.mulDiv(gross, devBps, BPS) - Math.mulDiv(gross, treasuryBps, BPS)
                - Math.mulDiv(gross, investorBps, BPS);
            accumulator += Math.mulDiv(users, ACC_PRECISION, pool.totalStaked);
        }
        UserInfo storage user = userInfo[pid][account];
        uint256 delta = accumulator - user.rewardDebt;
        return user.unpaidRewards + Math.mulDiv(user.amount, delta, ACC_PRECISION)
            + (mulmod(user.amount, delta, ACC_PRECISION) + rewardRemainder[pid][account]) / ACC_PRECISION;
    }

    function setEmissionRate(uint256 rate) external nonReentrant onlyTimelock {
        if (rate > MAX_EMISSION_RATE) revert InvalidParameter();
        uint256 minted = _checkpoint();
        if (automaticEmission) {
            automaticEmission = false;
            emit AutomaticEmissionChanged(false);
        }
        emit EmissionRateChanged(moonPerSecond, rate);
        moonPerSecond = rate;
        _mintRewards(minted);
    }

    /// @notice Enables the TVL curve or returns to the timelocked manual rate.
    function setAutomaticEmission(bool enabled) external nonReentrant onlyTimelock {
        uint256 minted = _checkpoint();
        automaticEmission = enabled;
        emit AutomaticEmissionChanged(enabled);
        if (enabled) _recalculateEmission();
        _mintRewards(minted);
    }

    /// @notice Rotates the bounded price publisher without granting other protocol powers.
    function setEmissionUpdater(address updater) external nonReentrant onlyTimelock {
        _validRecipient(updater);
        emit EmissionUpdaterChanged(emissionUpdater, updater);
        emissionUpdater = updater;
    }

    /// @notice Publishes USD prices used with internal deposits to reproduce V1's TVL curve.
    /// @dev Prices use 18 decimals. The rate is always saturated at MAX_EMISSION_RATE.
    function updateValuation(uint256 moonPriceUsd_, uint256 lpPriceUsd_) external nonReentrant {
        if (msg.sender != emissionUpdater && msg.sender != timelock) revert Unauthorized();
        if (moonPriceUsd_ == 0 || lpPriceUsd_ == 0 || moonPriceUsd_ > MAX_USD_PRICE || lpPriceUsd_ > MAX_USD_PRICE) {
            revert InvalidParameter();
        }
        uint256 minted = _checkpoint();
        moonPriceUsd = moonPriceUsd_;
        poolTokenPriceUsd[0] = moonPriceUsd_;
        poolTokenPriceUsd[1] = lpPriceUsd_;
        valuationUpdatedAt = block.timestamp;
        emit ValuationUpdated(msg.sender, moonPriceUsd_, lpPriceUsd_, block.timestamp);
        _recalculateEmission();
        _mintRewards(minted);
    }

    function valuationIsFresh() public view returns (bool) {
        return valuationUpdatedAt != 0 && block.timestamp - valuationUpdatedAt <= MAX_VALUATION_AGE;
    }

    function effectiveMoonPerSecond() external view returns (uint256) {
        return automaticEmission && !valuationIsFresh() ? 0 : moonPerSecond;
    }

    function protocolTvlUsd() public view returns (uint256) {
        return poolTvlUsd(0) + poolTvlUsd(1);
    }

    function poolTvlUsd(uint256 pid) public view returns (uint256) {
        _validPool(pid);
        return Math.mulDiv(poolInfo[pid].totalStaked, poolTokenPriceUsd[pid], USD_PRECISION);
    }

    function targetAprBps() public view returns (uint256) {
        uint256 tvlUsd = protocolTvlUsd();
        if (tvlUsd < FIRST_TVL_STEP_USD) return 0;
        uint256 units = tvlUsd / TVL_STEP_USD;
        if (units == 0) return FIRST_TIER_APR_BPS;
        uint256 multiplier = 1;
        while (multiplier < MAX_APR_MULTIPLIER && multiplier * 2 <= units) multiplier *= 2;
        return multiplier * BPS;
    }

    function quotedAutomaticEmission() public view returns (uint256) {
        if (!valuationIsFresh() || moonPriceUsd == 0) return 0;
        uint256 tvlUsd = protocolTvlUsd();
        uint256 aprBps = targetAprBps();
        if (tvlUsd == 0 || aprBps == 0) return 0;

        uint256 userBps = BPS - devBps - treasuryBps - investorBps;
        uint256 factor = aprBps * USD_PRECISION;
        uint256 denominator = 365 days * userBps * moonPriceUsd;
        uint256 saturationTvl = Math.mulDiv(MAX_EMISSION_RATE, denominator, factor);
        if (tvlUsd >= saturationTvl) return MAX_EMISSION_RATE;
        return Math.mulDiv(tvlUsd, factor, denominator);
    }

    function setShares(uint256 dev_, uint256 treasury_, uint256 investor_) external nonReentrant onlyTimelock {
        if (dev_ > 2000 || treasury_ > 2000 || investor_ > 1000) revert InvalidParameter();
        uint256 minted = _checkpoint();
        devBps = dev_;
        treasuryBps = treasury_;
        investorBps = investor_;
        emit SharesChanged(dev_, treasury_, investor_);
        _recalculateEmission();
        _mintRewards(minted);
    }

    function setWithdrawalFee(uint256 fee) external nonReentrant onlyTimelock {
        if (fee > MAX_WITHDRAWAL_FEE_BPS) revert InvalidParameter();
        emit WithdrawalFeeChanged(withdrawFeeBps, fee);
        withdrawFeeBps = fee;
    }

    function setAllocPoints(uint256 moonPoints, uint256 lpPoints) external nonReentrant onlyTimelock {
        if (moonPoints > TOTAL_ALLOC_POINT || lpPoints != TOTAL_ALLOC_POINT - moonPoints) revert InvalidParameter();
        uint256 minted = _checkpoint();
        poolInfo[0].allocPoint = moonPoints;
        poolInfo[1].allocPoint = lpPoints;
        emit AllocationChanged(moonPoints, lpPoints);
        _recalculateEmission();
        _mintRewards(minted);
    }

    function setBeneficiaries(address dev_, address treasury_, address investor_, address feeTreasury_)
        external
        nonReentrant
        onlyTimelock
    {
        _validRecipient(dev_);
        _validRecipient(treasury_);
        _validRecipient(investor_);
        _validRecipient(feeTreasury_);
        uint256 minted = _checkpoint();
        dev = dev_;
        treasury = treasury_;
        investor = investor_;
        feeTreasury = feeTreasury_;
        emit BeneficiariesChanged(dev_, treasury_, investor_, feeTreasury_);
        _mintRewards(minted);
    }

    function setGuardian(address guardian_) external nonReentrant onlyTimelock {
        _validRecipient(guardian_);
        emit GuardianChanged(guardian, guardian_);
        guardian = guardian_;
    }

    function pause() external nonReentrant {
        if (msg.sender != guardian && msg.sender != timelock) revert Unauthorized();
        paused = true;
        emit PauseChanged(msg.sender, true);
    }

    function unpause() external nonReentrant onlyTimelock {
        paused = false;
        emit PauseChanged(msg.sender, false);
    }

    function _checkpoint() private returns (uint256 gross) {
        (uint256 r0, uint256 r1) = _nextRewards();
        gross = r0 + r1;
        // All accounting before mint; MoonCoin is immutable OZ ERC20 with no callback.
        _updatePool(0, r0);
        _updatePool(1, r1);
        totalEmitted += gross;
    }

    function _mintRewards(uint256 gross) private {
        if (gross != 0) moon.mint(address(this), gross);
    }

    function _recalculateEmission() private {
        if (!automaticEmission) return;
        uint256 nextRate = quotedAutomaticEmission();
        if (nextRate == moonPerSecond) return;
        emit EmissionRateChanged(moonPerSecond, nextRate);
        moonPerSecond = nextRate;
    }

    function _nextRewards() private view returns (uint256 r0, uint256 r1) {
        uint256 last = poolInfo[0].lastRewardTime;
        uint256 rewardUntil = block.timestamp;
        if (automaticEmission) {
            if (valuationUpdatedAt == 0) return (0, 0);
            uint256 valuationExpiry = valuationUpdatedAt > type(uint256).max - MAX_VALUATION_AGE
                ? type(uint256).max
                : valuationUpdatedAt + MAX_VALUATION_AGE;
            if (rewardUntil > valuationExpiry) rewardUntil = valuationExpiry;
        }
        if (rewardUntil <= last || moonPerSecond == 0) return (0, 0);
        uint256 available = moon.cap() - moon.totalSupply();
        if (available == 0) return (0, 0);
        // Saturate time before multiplication. 1000 * cap covers even a one-point pool.
        uint256 limit = moon.cap() * TOTAL_ALLOC_POINT;
        uint256 elapsed = rewardUntil - last;
        uint256 gross = elapsed > limit / moonPerSecond ? limit : elapsed * moonPerSecond;
        if (automaticEmission) {
            uint256 tvl0 = poolTvlUsd(0);
            uint256 tvl1 = poolTvlUsd(1);
            uint256 totalTvl = tvl0 + tvl1;
            if (totalTvl != 0) {
                r0 = Math.mulDiv(gross, tvl0, totalTvl);
                r1 = gross - r0;
            }
        } else {
            if (poolInfo[0].totalStaked != 0) r0 = Math.mulDiv(gross, poolInfo[0].allocPoint, TOTAL_ALLOC_POINT);
            if (poolInfo[1].totalStaked != 0) r1 = Math.mulDiv(gross, poolInfo[1].allocPoint, TOTAL_ALLOC_POINT);
        }
        uint256 total = r0 + r1;
        if (total > available) {
            r0 = Math.mulDiv(available, r0, total);
            r1 = available - r0;
        }
    }

    function _updatePool(uint256 pid, uint256 gross) private {
        PoolInfo storage pool = poolInfo[pid];
        if (block.timestamp <= pool.lastRewardTime) return;
        pool.lastRewardTime = block.timestamp;
        uint256 users = 0;
        if (gross != 0) {
            uint256 devReward = Math.mulDiv(gross, devBps, BPS);
            uint256 treasuryReward = Math.mulDiv(gross, treasuryBps, BPS);
            uint256 investorReward = Math.mulDiv(gross, investorBps, BPS);
            users = gross - devReward - treasuryReward - investorReward;
            _creditBeneficiary(dev, devReward);
            _creditBeneficiary(treasury, treasuryReward);
            _creditBeneficiary(investor, investorReward);
            rewardReserve += users;
            pool.accMoonPerShare += Math.mulDiv(users, ACC_PRECISION, pool.totalStaked);
        }
        emit PoolUpdated(pid, block.timestamp, gross, users, pool.accMoonPerShare);
    }

    function _creditBeneficiary(address account, uint256 amount) private {
        claimableBeneficiary[account] += amount;
        beneficiaryReserve += amount;
        emit BeneficiaryAccrued(account, amount);
    }

    function _settle(uint256 pid, address account) private {
        UserInfo storage user = userInfo[pid][account];
        uint256 accumulator = poolInfo[pid].accMoonPerShare;
        uint256 delta = accumulator - user.rewardDebt;
        uint256 remainder = mulmod(user.amount, delta, ACC_PRECISION) + rewardRemainder[pid][account];
        // Reuse the quotient for the carried remainder: deterministic fixed-point accounting.
        uint256 wholeRemainder = remainder / ACC_PRECISION;
        user.unpaidRewards += Math.mulDiv(user.amount, delta, ACC_PRECISION) + wholeRemainder;
        rewardRemainder[pid][account] = remainder - wholeRemainder * ACC_PRECISION;
        user.rewardDebt = accumulator;
    }

    function _returnPrincipal(uint256 pid, address account, uint256 amount) private returns (uint256 fee) {
        fee = Math.mulDiv(amount, withdrawFeeBps, BPS);
        IERC20 token = poolInfo[pid].token;
        _transferExact(token, account, amount - fee);
        _transferExact(token, feeTreasury, fee);
    }

    function _transferExact(IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeSelf = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) != beforeSelf - amount || token.balanceOf(to) != beforeRecipient + amount) {
            revert UnsupportedToken();
        }
    }

    function _validPool(uint256 pid) private pure {
        if (pid >= 2) revert InvalidPool();
    }

    function _validRecipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
    }
}
