// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import {ERC20} from "../tokens/ERC20.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {MathUtils} from "../libraries/MathUtils.sol";

contract RewardTracker is ERC20, ReentrancyGuard, IRewardTracker, OwnableRoles {
    using SafeTransferLib for IERC20;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using MathUtils for uint256;

    address private immutable WETH;
    address private immutable USDC;

    uint128 public constant PRECISION = 1e30;

    bool public isInitialized;

    address public distributor;

    address public depositToken;

    uint256 public totalDepositSupply;

    uint256 public cumulativeWethRewardPerToken;
    uint256 public cumulativeUsdcRewardPerToken;

    mapping(address account => StakeData) private stakeData;

    mapping(address account => EnumerableSetLib.Bytes32Set) private lockKeys;

    mapping(bytes32 key => LockData) public lockData;

    mapping(address account => uint256 amount) public lockedAmounts;

    bool public inPrivateStakingMode;
    bool public inPrivateClaimingMode;
    mapping(address => bool) public isHandler;

    constructor(address _depositToken, address _weth, address _usdc, string memory _name, string memory _symbol)
        ERC20(_name, _symbol, 18)
    {
        _initializeOwner(msg.sender);
        depositToken = _depositToken;
        WETH = _weth;
        USDC = _usdc;
        name = _name;
        symbol = _symbol;
    }

    /**
     * =========================================== Setter Functions ===========================================
     */
    function initialize(address _distributor, address _marketFactory, address _positionManager, address _router)
        external
        onlyOwner
    {
        if (isInitialized) revert RewardTracker_AlreadyInitialized();
        isInitialized = true;
        distributor = _distributor;
        grantRoles(_marketFactory, _ROLE_0);
        isHandler[_positionManager] = true;
        isHandler[_router] = true;
    }

    function setInPrivateStakingMode(bool _inPrivateStakingMode) external onlyOwner {
        inPrivateStakingMode = _inPrivateStakingMode;
    }

    function setInPrivateClaimingMode(bool _inPrivateClaimingMode) external onlyOwner {
        inPrivateClaimingMode = _inPrivateClaimingMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyOwner {
        isHandler[_handler] = _isActive;
    }

    /**
     * =========================================== Token Functions ===========================================
     */
    /// @dev Transfers don't transfer stake data. The original user will still earn the rewards.
    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        // Get the transferrable amount and ensure they have enough
        uint256 transferrableAmount = _getAvailableBalance(msg.sender);
        if (transferrableAmount < amount) revert RewardTracker_AmountExceedsBalance();

        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        // Get the transferrable amount and ensure they have enough
        uint256 transferrableAmount = _getAvailableBalance(from);
        if (transferrableAmount < amount) revert RewardTracker_AmountExceedsBalance();

        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /**
     * =========================================== Core Functions ===========================================
     */
    function stake(uint256 _amount, uint40 _stakeDuration) external nonReentrant {
        if (inPrivateStakingMode) revert RewardTracker_ActionDisbaled();

        _stake(msg.sender, msg.sender, _amount);
        if (_stakeDuration > 0) {
            _lock(msg.sender, _amount, _stakeDuration);
        }
    }

    function stakeForAccount(address _fundingAccount, address _account, uint256 _amount, uint40 _stakeDuration)
        external
        nonReentrant
    {
        _validateHandler();

        _stake(_fundingAccount, _account, _amount);
        if (_stakeDuration > 0) {
            _lock(_account, _amount, _stakeDuration);
        }
    }

    function unstake(uint256 _amount, bytes32[] calldata _lockKeys) external nonReentrant {
        if (inPrivateStakingMode) revert RewardTracker_ActionDisbaled();

        if (_lockKeys.length > 0) {
            _unlock(msg.sender, _lockKeys);
        }
        _unstake(msg.sender, _amount, msg.sender);
    }

    /// @dev No optional unlock for unstaking for another account.
    function unstakeForAccount(address _account, uint256 _amount, address _receiver) external nonReentrant {
        _validateHandler();
        _unstake(_account, _amount, _receiver);
    }

    function updateRewards() external nonReentrant {
        _updateRewards(address(0));
    }

    function extendLockDuration(bytes32 _lockKey, uint40 _timeToExtend) external nonReentrant {
        LockData storage position = lockData[_lockKey];
        if (position.owner != msg.sender) revert RewardTracker_Forbidden();
        position.unlockDate += _timeToExtend;
    }

    function lock(uint256 _amount, uint40 _lockDuration) external nonReentrant {
        if (_amount > _getAvailableBalance(msg.sender)) revert RewardTracker_AmountExceedsBalance();
        if (_lockDuration == 0) revert RewardTracker_InvalidAmount();
        _lock(msg.sender, _amount, _lockDuration);
    }

    function unlock(bytes32[] calldata _lockKeys) external nonReentrant {
        _unlock(msg.sender, _lockKeys);
    }

    function claim(address _receiver) external nonReentrant returns (uint256 wethAmount, uint256 usdcAmount) {
        if (inPrivateClaimingMode) revert RewardTracker_ActionDisbaled();
        return _claim(msg.sender, _receiver);
    }

    function claimForAccount(address _account, address _receiver)
        external
        nonReentrant
        returns (uint256 wethAmount, uint256 usdcAmount)
    {
        _validateHandler();
        return _claim(_account, _receiver);
    }

    /**
     * =========================================== Getter Functions ===========================================
     */
    function tokensPerInterval() external view returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval) {
        (wethTokensPerInterval, usdcTokensPerInterval) = IFeeDistributor(distributor).tokensPerInterval(depositToken);
    }

    function claimable(address _account) public view returns (uint256 wethAmount, uint256 usdcAmount) {
        StakeData storage userStake = stakeData[_account];

        uint256 stakedAmount = userStake.stakedAmount;

        if (stakedAmount == 0) {
            return (userStake.claimableWethReward, userStake.claimableUsdcReward);
        }

        uint256 supply = totalSupply;
        (uint256 pendingWeth, uint256 pendingUsdc) = IFeeDistributor(distributor).pendingRewards(depositToken);

        uint256 nextCumulativeWethPerToken = cumulativeWethRewardPerToken + pendingWeth.mulDiv(PRECISION, supply);
        uint256 nextCumulativeUsdcPerToken = cumulativeUsdcRewardPerToken + pendingUsdc.mulDiv(PRECISION, supply);

        wethAmount = userStake.claimableWethReward
            + stakedAmount.mulDiv(nextCumulativeWethPerToken - userStake.prevCumulativeWethPerToken, PRECISION);

        usdcAmount = userStake.claimableUsdcReward
            + stakedAmount.mulDiv(nextCumulativeUsdcPerToken - userStake.prevCumulativeUsdcPerToken, PRECISION);
    }

    function getStakeData(address _account) external view returns (StakeData memory) {
        return stakeData[_account];
    }

    function getLockData(bytes32 _lockKey) external view returns (LockData memory) {
        return lockData[_lockKey];
    }

    function getRemainingLockTime(bytes32 _lockKey) external view returns (uint256) {
        LockData storage position = lockData[_lockKey];
        if (position.unlockDate > _blockTimestamp()) {
            return position.unlockDate - _blockTimestamp();
        }
        return 0;
    }

    function getActiveLocks(address _account) external view returns (LockData[] memory) {
        uint256 length = lockKeys[_account].length();
        LockData[] memory positions = new LockData[](length);
        for (uint256 i = 0; i < length;) {
            positions[i] = lockData[lockKeys[_account].at(i)];
            unchecked {
                ++i;
            }
        }
        return positions;
    }

    function getLockAtIndex(address _account, uint256 _index) external view returns (LockData memory) {
        return lockData[lockKeys[_account].at(_index)];
    }

    function getLockKeyAtIndex(address _account, uint256 _index) external view returns (bytes32) {
        return lockKeys[_account].at(_index);
    }

    /**
     * =========================================== Internal Functions ===========================================
     */
    function _claim(address _account, address _receiver) private returns (uint256 wethAmount, uint256 usdcAmount) {
        _updateRewards(_account);

        StakeData storage userStake = stakeData[_account];

        wethAmount = userStake.claimableWethReward;
        usdcAmount = userStake.claimableUsdcReward;

        userStake.claimableWethReward = 0;
        userStake.claimableUsdcReward = 0;

        if (wethAmount > 0) IERC20(WETH).safeTransfer(_receiver, wethAmount);
        if (usdcAmount > 0) IERC20(USDC).safeTransfer(_receiver, usdcAmount);

        emit Claim(_receiver, wethAmount, usdcAmount);
    }

    function _validateHandler() private view {
        if (!isHandler[msg.sender]) revert RewardTracker_Forbidden();
    }

    function _stake(address _fundingAccount, address _account, uint256 _amount) private {
        if (_amount == 0) revert RewardTracker_InvalidAmount();

        IERC20(depositToken).safeTransferFrom(_fundingAccount, address(this), _amount);

        _updateRewards(_account);

        StakeData storage userStake = stakeData[_account];

        userStake.stakedAmount += _amount;
        userStake.depositBalance += _amount;
        totalDepositSupply += _amount;

        _mint(_account, _amount);
    }

    /// @notice While locked, tokens become non-transferrable, and users can't unstake.
    /// A user can still claim rewards while their tokens are locked.
    function _lock(address _account, uint256 _amount, uint40 _lockDuration) private {
        LockData memory position = LockData({
            depositAmount: _amount,
            lockedAt: _blockTimestamp(),
            unlockDate: _blockTimestamp() + _lockDuration,
            owner: _account
        });

        bytes32 key = _generateLockKey(_account, position.unlockDate);
        if (lockKeys[_account].contains(key)) revert RewardTracker_PositionAlreadyExists();

        lockKeys[_account].add(key);
        lockData[key] = position;
        lockedAmounts[_account] += _amount;

        emit LiquidityLocked(_account, _amount, position.unlockDate, key);
    }

    function _unstake(address _account, uint256 _amount, address _receiver) private {
        if (_amount == 0) revert RewardTracker_InvalidAmount();

        if (_getAvailableBalance(_account) < _amount) revert RewardTracker_AmountExceedsBalance();

        _updateRewards(_account);

        StakeData storage userStake = stakeData[_account];

        uint256 stakedAmount = userStake.stakedAmount;
        if (stakedAmount < _amount) revert RewardTracker_AmountExceedsStake();

        userStake.stakedAmount = stakedAmount - _amount;

        uint256 depositBalance = userStake.depositBalance;
        if (depositBalance < _amount) revert RewardTracker_AmountExceedsBalance();

        userStake.depositBalance = depositBalance - _amount;
        totalDepositSupply -= _amount;

        _burn(_account, _amount);

        IERC20(depositToken).safeTransfer(_receiver, _amount);
    }

    function _unlock(address _account, bytes32[] calldata _lockKeys) private {
        uint256 totalAmount;
        uint256 len = _lockKeys.length;
        for (uint256 i = 0; i < len;) {
            LockData storage position = lockData[_lockKeys[i]];
            if (position.unlockDate > _blockTimestamp()) revert RewardTracker_Forbidden();
            if (position.owner != _account) revert RewardTracker_Forbidden();
            totalAmount += position.depositAmount;

            delete lockData[_lockKeys[i]];
            lockKeys[_account].remove(_lockKeys[i]);
            unchecked {
                ++i;
            }
        }
        lockedAmounts[_account] -= totalAmount;

        emit LiquidityUnlocked(_account, totalAmount, _lockKeys);
    }

    function _updateRewards(address _account) private {
        (uint256 wethReward, uint256 usdcReward) = IFeeDistributor(distributor).distribute(depositToken);

        uint256 supply = totalSupply;

        uint256 _cumulativeWethRewardPerToken = cumulativeWethRewardPerToken;
        uint256 _cumulativeUsdcRewardPerToken = cumulativeUsdcRewardPerToken;

        if (supply > 0) {
            if (wethReward > 0) {
                _cumulativeWethRewardPerToken = _cumulativeWethRewardPerToken + wethReward.mulDiv(PRECISION, supply);
                cumulativeWethRewardPerToken = _cumulativeWethRewardPerToken;
            }
            if (usdcReward > 0) {
                _cumulativeUsdcRewardPerToken = _cumulativeUsdcRewardPerToken + usdcReward.mulDiv(PRECISION, supply);
                cumulativeUsdcRewardPerToken = _cumulativeUsdcRewardPerToken;
            }
        }

        // cumulativeRewardPerToken can only increase
        // so if cumulativeRewardPerToken is zero, it means there are no rewards yet
        if (_cumulativeWethRewardPerToken == 0 && _cumulativeUsdcRewardPerToken == 0) {
            return;
        }

        if (_account != address(0)) {
            _updateRewardsForAccount(_account, _cumulativeWethRewardPerToken, _cumulativeUsdcRewardPerToken);
        }
    }

    /// @dev private function to prevent STD Err
    function _updateRewardsForAccount(
        address _account,
        uint256 _cumulativeWethRewardPerToken,
        uint256 _cumulativeUsdcRewardPerToken
    ) private {
        StakeData storage userStake = stakeData[_account];

        uint256 stakedAmount = userStake.stakedAmount;

        uint256 userWethReward =
            stakedAmount.mulDiv(_cumulativeWethRewardPerToken - userStake.prevCumulativeWethPerToken, PRECISION);
        uint256 _claimableWethReward = userStake.claimableWethReward + userWethReward;

        uint256 userUsdcReward =
            stakedAmount.mulDiv(_cumulativeUsdcRewardPerToken - userStake.prevCumulativeUsdcPerToken, PRECISION);
        uint256 _claimableUsdcReward = userStake.claimableUsdcReward + userUsdcReward;

        userStake.claimableWethReward = _claimableWethReward;
        userStake.prevCumulativeWethPerToken = _cumulativeWethRewardPerToken;

        userStake.claimableUsdcReward = _claimableUsdcReward;
        userStake.prevCumulativeUsdcPerToken = _cumulativeUsdcRewardPerToken;

        if (userStake.stakedAmount > 0) {
            if (_claimableWethReward > 0) {
                uint256 nextCumulativeReward = userStake.cumulativeWethRewards + userWethReward;

                userStake.averageStakedAmount = userStake.averageStakedAmount.mulDiv(
                    userStake.cumulativeWethRewards, nextCumulativeReward
                ) + stakedAmount.mulDiv(userWethReward, nextCumulativeReward);

                userStake.cumulativeWethRewards = nextCumulativeReward;
            }
            if (_claimableUsdcReward > 0) {
                uint256 nextCumulativeReward = userStake.cumulativeUsdcRewards + userUsdcReward;

                userStake.averageStakedAmount = userStake.averageStakedAmount.mulDiv(
                    userStake.cumulativeUsdcRewards, nextCumulativeReward
                ) + stakedAmount.mulDiv(userUsdcReward, nextCumulativeReward);

                userStake.cumulativeUsdcRewards = nextCumulativeReward;
            }
        }
    }

    function _blockTimestamp() private view returns (uint40) {
        return uint40(block.timestamp);
    }

    function _getAvailableBalance(address _account) private view returns (uint256) {
        return balanceOf[_account] - lockedAmounts[_account];
    }

    function _generateLockKey(address _account, uint40 _unlockDate) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _unlockDate));
    }
}
