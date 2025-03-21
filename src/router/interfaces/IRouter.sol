// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MarketId} from "../../types/MarketId.sol";
import {Position} from "../../positions/Position.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";

interface IRouter {
    /**
     * @dev Events
     */
    event DepositRequestCreated(
        bytes32 indexed marketId, bytes32 indexed requestKey, address owner, address tokenIn, uint256 amountIn
    );
    event WithdrawalRequestCreated(
        bytes32 indexed marketId, bytes32 indexed requestKey, address owner, address tokenOut, uint256 amountOut
    );
    event PositionRequestCreated(bytes32 indexed marketId, bytes32 indexed requestKey, bool _isLimit);
    event PriceUpdateRequested(bytes32 indexed requestKey, string[] tickers, address indexed requester);
    event StopLossCreated(bytes32 indexed marketId, bytes32 indexed requestKey, bytes32 indexed stopLossKey);
    event TakeProfitCreated(bytes32 indexed marketId, bytes32 indexed requestKey, bytes32 indexed takeProfitKey);

    /**
     * @dev External Functions
     */
    function createDeposit(
        MarketId _id,
        address _owner,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _executionFee,
        uint40 _stakeDuration,
        bool _shouldWrap
    ) external payable returns (bytes32 requestKey);

    function createWithdrawal(
        MarketId _id,
        address _owner,
        address _tokenOut,
        uint256 _marketTokenAmountIn,
        uint256 _executionFee,
        bool _shouldUnwrap
    ) external payable returns (bytes32 requestKey);

    function createPositionRequest(
        MarketId _id,
        Position.Input memory _trade,
        Position.Conditionals calldata _conditionals
    ) external payable returns (bytes32 orderKey);

    function requestExecutionPricing(MarketId _id) external payable returns (bytes32 priceRequestKey);

    function requestExecutionData(MarketId _id, bytes32 _key) external payable;

    function requestPricingForAsset(string calldata _ticker) external payable returns (bytes32 priceRequestKey);

    function updateConfig(address _marketFactory, address _positionManager) external;

    function updatePriceFeed(IPriceFeed _priceFeed) external;

    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable;
}
