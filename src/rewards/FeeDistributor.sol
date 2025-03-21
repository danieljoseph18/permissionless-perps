// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";

contract FeeDistributor is ReentrancyGuard, OwnableRoles {
    using SafeTransferLib for IERC20;

    error FeeDistributor_InvalidVault();
    error FeeDistributor_InvalidRewardTracker();

    event FeesAccumulated(address indexed vault, uint256 wethAmount, uint256 usdcAmount);
    event Distribute(address indexed vault, uint256 wethAmount, uint256 usdcAmount);

    struct FeeParams {
        uint256 wethAmount;
        uint256 usdcAmount;
        uint256 wethTokensPerInterval;
        uint256 usdcTokensPerInterval;
        uint256 lastUpdateTime;
        uint256 wethAccrued;
        uint256 usdcAccrued;
    }

    IMarketFactory public marketFactory;

    uint32 private constant SECONDS_PER_WEEK = 1 weeks;

    mapping(address => bool) public isRewardTracker;
    mapping(address => bool) public isVault;

    address public immutable weth;
    address public immutable usdc;

    mapping(address => FeeParams) public feeParamsForVault;

    constructor(address _marketFactory, address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        marketFactory = IMarketFactory(_marketFactory);
        weth = _weth;
        usdc = _usdc;
    }

    function addVault(address _vault) external onlyRoles(_ROLE_0) {
        isVault[_vault] = true;
    }

    function addRewardTracker(address _rewardTracker) external onlyRoles(_ROLE_0) {
        isRewardTracker[_rewardTracker] = true;
    }

    function accumulateFees(uint256 _wethAmount, uint256 _usdcAmount) external nonReentrant {
        address vault = msg.sender;
        if (!isVault[vault]) revert FeeDistributor_InvalidVault();

        IERC20(weth).safeTransferFrom(msg.sender, address(this), _wethAmount);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), _usdcAmount);

        FeeParams storage feeParams = feeParamsForVault[vault];

        _accrueRewards(feeParams);

        feeParams.wethAmount += _wethAmount;
        feeParams.usdcAmount += _usdcAmount;

        feeParams.wethTokensPerInterval = feeParams.wethAmount / SECONDS_PER_WEEK;
        feeParams.usdcTokensPerInterval = feeParams.usdcAmount / SECONDS_PER_WEEK;

        feeParams.lastUpdateTime = block.timestamp;

        emit FeesAccumulated(vault, _wethAmount, _usdcAmount);
    }

    function distribute(address _vault) external nonReentrant returns (uint256 wethAmount, uint256 usdcAmount) {
        if (!isRewardTracker[msg.sender]) revert FeeDistributor_InvalidRewardTracker();

        FeeParams storage feeParams = feeParamsForVault[_vault];

        _accrueRewards(feeParams);

        wethAmount = feeParams.wethAccrued;
        usdcAmount = feeParams.usdcAccrued;

        if (wethAmount == 0 && usdcAmount == 0) {
            return (0, 0);
        }

        feeParams.wethAccrued = 0;
        feeParams.usdcAccrued = 0;

        if (wethAmount > 0) IERC20(weth).safeTransfer(msg.sender, wethAmount);
        if (usdcAmount > 0) IERC20(usdc).safeTransfer(msg.sender, usdcAmount);

        emit Distribute(_vault, wethAmount, usdcAmount);
    }

    function pendingRewards(address _vault) public view returns (uint256 wethAmount, uint256 usdcAmount) {
        FeeParams memory feeParams = feeParamsForVault[_vault];
        uint256 timeElapsed = block.timestamp - feeParams.lastUpdateTime;

        uint256 cappedTimeElapsed = _min(timeElapsed, SECONDS_PER_WEEK);

        wethAmount =
            feeParams.wethAccrued + _min(feeParams.wethTokensPerInterval * cappedTimeElapsed, feeParams.wethAmount);
        usdcAmount =
            feeParams.usdcAccrued + _min(feeParams.usdcTokensPerInterval * cappedTimeElapsed, feeParams.usdcAmount);
    }

    function tokensPerInterval(address _vault)
        external
        view
        returns (uint256 wethTokensPerInterval, uint256 usdcTokensPerInterval)
    {
        FeeParams memory feeParams = feeParamsForVault[_vault];
        return (feeParams.wethTokensPerInterval, feeParams.usdcTokensPerInterval);
    }

    function _accrueRewards(FeeParams storage feeParams) internal {
        uint256 timeElapsed = block.timestamp - feeParams.lastUpdateTime;
        if (timeElapsed == 0) return;

        uint256 cappedTimeElapsed = _min(timeElapsed, SECONDS_PER_WEEK);

        uint256 wethReward = _min(feeParams.wethTokensPerInterval * cappedTimeElapsed, feeParams.wethAmount);
        uint256 usdcReward = _min(feeParams.usdcTokensPerInterval * cappedTimeElapsed, feeParams.usdcAmount);

        feeParams.wethAccrued += wethReward;
        feeParams.usdcAccrued += usdcReward;
        feeParams.wethAmount -= wethReward;
        feeParams.usdcAmount -= usdcReward;

        feeParams.lastUpdateTime = block.timestamp;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
