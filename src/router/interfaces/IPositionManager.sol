// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Position} from "../../positions/Position.sol";
import {IVault} from "../../markets/interfaces/IVault.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {MarketId} from "../../types/MarketId.sol";

interface IPositionManager {
    event ExecutePosition(bytes32 indexed marketId, bytes32 indexed _orderKey, uint256 _fee, uint256 _feeDiscount);
    event GasLimitsUpdated(
        uint256 indexed depositGasLimit, uint256 indexed withdrawalGasLimit, uint256 indexed positionGasLimit
    );
    event AdlExecuted(bytes32 indexed market, bytes32 indexed positionKey, uint256 sizeDelta, bool isLong);
    event AdlTargetRatioReached(bytes32 indexed market, int256 newFactor, bool isLong);
    event MarketRequestCancelled(bytes32 indexed _requestKey, address indexed _owner, address _token, uint256 _amount);
    event PositionManager_HoldingTokens(address indexed user, address indexed amount, address indexed token);
    event UserReferred(
        address indexed user,
        address indexed referrer,
        uint256 sizeDelta,
        uint256 affiliateRebate,
        bool isLongToken,
        bytes32 referralCode
    );

    error PositionManager_CancellationFailed();
    error PositionManager_InvalidMarket();
    error PositionManager_InvalidKey();
    error PositionManager_RequestDoesNotExist();
    error PositionManager_InsufficientDelay();

    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function averageDepositCost() external view returns (uint256);
    function averageWithdrawalCost() external view returns (uint256);
    function averagePositionCost() external view returns (uint256);
    function transferTokensForIncrease(
        IVault vault,
        address _collateralToken,
        uint256 _collateralDelta,
        uint256 _affiliateRebate,
        uint256 _feeForExecutor,
        address _executor
    ) external;
    function executePosition(MarketId _id, bytes32 _orderKey, bytes32 _requestKey, address _feeReceiver)
        external
        payable;

    function liquidatePosition(MarketId _id, bytes32 _positionKey, bytes32 _requestKey) external payable;
    function cancelMarketRequest(MarketId _id, bytes32 _requestKey) external;
    function executeDeposit(MarketId _id, bytes32 _key) external payable;
    function executeWithdrawal(MarketId _id, bytes32 _key) external payable;
}
