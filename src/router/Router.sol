// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {Position} from "../positions/Position.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {Gas} from "../libraries/Gas.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {Units} from "../libraries/Units.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";
import {MarketId} from "../types/MarketId.sol";
import {Pool} from "../markets/Pool.sol";

/// @dev Needs Router role
// All user interactions should come through this contract
contract Router is ReentrancyGuard, OwnableRoles {
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IWETH;
    using SafeTransferLib for IVault;
    using Units for uint256;

    IMarketFactory private marketFactory;
    IMarket market;
    IPriceFeed private priceFeed;
    IERC20 private immutable USDC;
    IWETH private immutable WETH;
    IPositionManager private positionManager;

    uint64 private constant MAX_PERCENTAGE = 1e18;
    // $2 Min Trade Size
    uint128 private MIN_TRADE_SIZE = 2e30;

    event DepositRequestCreated(
        bytes32 indexed marketId, bytes32 indexed requestKey, address owner, address tokenIn, uint256 amountIn
    );
    event WithdrawalRequestCreated(
        bytes32 indexed marketId, bytes32 indexed requestKey, address owner, address tokenOut, uint256 amountOut
    );
    event PositionRequestCreated(bytes32 indexed marketId, bytes32 indexed requestKey, bool _isLimit, address owner);
    event PriceUpdateRequested(bytes32 indexed requestKey, string[] tickers, address indexed requester);
    event StopLossCreated(
        bytes32 indexed marketId, bytes32 indexed requestKey, bytes32 indexed stopLossKey, address owner
    );
    event TakeProfitCreated(
        bytes32 indexed marketId, bytes32 indexed requestKey, bytes32 indexed takeProfitKey, address owner
    );

    error Router_InvalidOwner();
    error Router_InvalidAmountIn();
    error Router_CantWrapUSDC();
    error Router_InvalidTokenIn();
    error Router_InvalidTokenOut();
    error Router_InvalidAsset();
    error Router_InvalidCollateralToken();
    error Router_InvalidAmountInForWrap();
    error Router_InvalidUpdateFee();
    error Router_InvalidStopLossPercentage();
    error Router_InvalidTakeProfitPercentage();
    error Router_InvalidAssetId();
    error Router_MarketDoesNotExist();
    error Router_InvalidLimitPrice();
    error Router_InvalidRequest();
    error Router_SizeExceedsPosition();
    error Router_InvalidConditional();
    error Router_InvalidStopLossPrice();
    error Router_InvalidTakeProfitPrice();

    constructor(
        address _marketFactory,
        address _market,
        address _priceFeed,
        address _usdc,
        address _weth,
        address _positionManager
    ) {
        _initializeOwner(msg.sender);
        marketFactory = IMarketFactory(_marketFactory);
        market = IMarket(_market);
        priceFeed = IPriceFeed(_priceFeed);
        USDC = IERC20(_usdc);
        WETH = IWETH(_weth);
        positionManager = IPositionManager(_positionManager);
    }

    receive() external payable {}

    /**
     * ========================================= Setter Functions =========================================
     */
    function updateConfig(address _marketFactory, address _positionManager) external onlyOwner {
        marketFactory = IMarketFactory(_marketFactory);
        positionManager = IPositionManager(_positionManager);
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    /**
     * ========================================= External Functions =========================================
     */
    function createDeposit(
        MarketId _id,
        address _owner,
        address _tokenIn,
        uint256 _amountIn,
        uint256 _executionFee,
        uint40 _stakeDuration,
        bool _shouldWrap
    ) external payable nonReentrant returns (bytes32 requestKey) {
        uint256 totalPriceUpdateFee = Gas.validateExecutionFee(
            priceFeed, positionManager, _executionFee, msg.value, Gas.Action.DEPOSIT, true, false
        );

        _executionFee -= totalPriceUpdateFee;

        if (msg.sender != _owner) revert Router_InvalidOwner();

        if (_amountIn == 0) revert Router_InvalidAmountIn();

        uint256 excessValue;

        if (_shouldWrap) {
            if (_amountIn > msg.value - (_executionFee + totalPriceUpdateFee)) revert Router_InvalidAmountIn();
            if (_tokenIn != address(WETH)) revert Router_CantWrapUSDC();

            excessValue = msg.value - (_executionFee + totalPriceUpdateFee + _amountIn);

            WETH.deposit{value: _amountIn}();
            WETH.safeTransfer(address(positionManager), _amountIn);
        } else {
            if (_tokenIn != address(USDC) && _tokenIn != address(WETH)) revert Router_InvalidTokenIn();

            excessValue = msg.value - (_executionFee + totalPriceUpdateFee);

            IERC20(_tokenIn).safeTransferFrom(msg.sender, address(positionManager), _amountIn);
        }

        uint256 priceFee = totalPriceUpdateFee / 2;

        bytes32 priceRequestKey = _requestPriceUpdate(priceFee, _id);

        requestKey = market.createRequest(
            _id, _owner, _tokenIn, _amountIn, _executionFee, priceRequestKey, _stakeDuration, _shouldWrap, true
        );

        _sendExecutionFee(_executionFee);

        if (excessValue > 0) SafeTransferLib.safeTransferETH(msg.sender, excessValue);

        emit DepositRequestCreated(MarketId.unwrap(_id), requestKey, _owner, _tokenIn, _amountIn);
    }

    function createWithdrawal(
        MarketId _id,
        address _owner,
        address _tokenOut,
        uint256 _marketTokenAmountIn,
        uint256 _executionFee,
        bool _shouldUnwrap
    ) external payable nonReentrant returns (bytes32 requestKey) {
        uint256 totalPriceUpdateFee = Gas.validateExecutionFee(
            priceFeed, positionManager, _executionFee, msg.value, Gas.Action.WITHDRAW, true, false
        );

        _executionFee -= totalPriceUpdateFee;

        if (msg.sender != _owner) revert Router_InvalidOwner();

        if (_marketTokenAmountIn == 0) revert Router_InvalidAmountIn();

        if (_shouldUnwrap) {
            if (_tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        } else {
            if (_tokenOut != address(USDC) && _tokenOut != address(WETH)) revert Router_InvalidTokenOut();
        }

        uint256 priceFee = totalPriceUpdateFee / 2;

        bytes32 priceRequestKey = _requestPriceUpdate(priceFee, _id);

        IVault vault = market.getVault(_id);

        vault.rewardTracker().unstakeForAccount(msg.sender, _marketTokenAmountIn, address(this));

        vault.safeTransfer(address(positionManager), _marketTokenAmountIn);

        requestKey = market.createRequest(
            _id, _owner, _tokenOut, _marketTokenAmountIn, _executionFee, priceRequestKey, 0, _shouldUnwrap, false
        );

        _sendExecutionFee(_executionFee);

        emit WithdrawalRequestCreated(MarketId.unwrap(_id), requestKey, _owner, _tokenOut, _marketTokenAmountIn);
    }

    function createPositionRequest(
        MarketId _id,
        Position.Input memory _trade,
        Position.Conditionals calldata _conditionals
    ) external payable nonReentrant returns (bytes32 orderKey) {
        if (bytes(_trade.ticker).length == 0) revert Router_InvalidAssetId();

        if (address(market) == address(0)) revert Router_MarketDoesNotExist();

        if (_trade.isLimit && _trade.limitPrice == 0) revert Router_InvalidLimitPrice();

        Position.checkSlippage(_trade.maxSlippage);

        // If Long, Collateral must be (W)ETH, if Short, Colalteral must be USDC
        if (_trade.isLong) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidTokenIn();
        } else {
            if (_trade.collateralToken != address(USDC)) revert Router_InvalidTokenIn();
        }

        // Cache the Total Execution Fee before it's manipulated
        uint256 totalExecutionFee = _trade.executionFee;

        uint256 priceUpdateFee;
        Gas.Action action;

        if (_conditionals.stopLossSet && _conditionals.takeProfitSet) {
            action = Gas.Action.POSITION_WITH_LIMITS;
        } else if (_conditionals.stopLossSet || _conditionals.takeProfitSet) {
            action = Gas.Action.POSITION_WITH_LIMIT;
        } else {
            action = Gas.Action.POSITION;
        }

        priceUpdateFee = Gas.validateExecutionFee(
            priceFeed, positionManager, totalExecutionFee, msg.value, action, false, _trade.isLimit
        );

        _trade.executionFee -= uint64(priceUpdateFee);

        // Execution fee includes the price update fee, so can only be manipulated after the price update fee is validated / subtracted.
        if (action == Gas.Action.POSITION_WITH_LIMITS) {
            // Adjust the Execution Fee to a per-order basis (3x requests)
            _trade.executionFee /= 3;
        } else if (action == Gas.Action.POSITION_WITH_LIMIT) {
            // Adjust the Execution Fee to a per-order basis (2x requests)
            _trade.executionFee /= 2;
        }

        if (_trade.isIncrease) {
            _handleTokenTransfers(_trade, totalExecutionFee);
        }

        // Request Price Update for the Asset if Market Order
        // Limit Orders, Stop Loss, and Take Profit Order's prices will be updated at execution time
        bytes32 priceRequestKey = _trade.isLimit ? bytes32(0) : _requestPriceUpdate(priceUpdateFee, _id);

        bytes32 positionKey = Position.generateKey(_trade.ticker, msg.sender, _trade.isLong);

        ITradeStorage tradeStorage = market.tradeStorage();

        Position.Data memory position = tradeStorage.getPosition(_id, positionKey);

        // Position must exist if collateral delta is 0
        if (_trade.collateralDelta == 0) {
            if (position.user == address(0)) revert Router_InvalidRequest();
        }

        Position.RequestType requestType = Position.getRequestType(_trade, position);
        _validateRequestType(_trade, position, requestType);

        Position.Request memory request = Position.createRequest(_trade, msg.sender, requestType, priceRequestKey);

        orderKey = tradeStorage.createOrderRequest(_id, request);

        // Cache isLimit before it's manipulated
        bool isTradeLimit = _trade.isLimit;

        // For each conditional, instead of greating a brand new request, we alter the original request in memory
        if (action != Gas.Action.POSITION && request.requestType == Position.RequestType.CREATE_POSITION) {
            if (_conditionals.stopLossSet) _createStopLoss(_id, tradeStorage, request, _conditionals, orderKey);

            if (_conditionals.takeProfitSet) _createTakeProfit(_id, tradeStorage, request, _conditionals, orderKey);
        }

        _sendExecutionFee(totalExecutionFee - priceUpdateFee);

        emit PositionRequestCreated(MarketId.unwrap(_id), orderKey, isTradeLimit, msg.sender);
    }

    /**
     * This function is used to create a price update request before execution one of either:
     * - Limit Order
     * - Adl
     * - Liquidation
     *
     * As the user doesn't provide the request in real time in these cases.
     *
     * To prevent the case where a user requests pricing to execute an order.
     *
     * Can also be used in cases where the price / pnl fulfillment from the chainlink functions fails.
     * In this case, a user will be incentivized to fetch a new price / pnl for the request
     */
    // Key can be an orderKey if limit new position, position key if limit decrease, sl, tp, adl or liquidation
    function requestExecutionPricing(MarketId _id) external payable returns (bytes32 priceRequestKey) {
        uint256 priceUpdateFee = Oracle.estimateRequestCost(address(priceFeed));

        if (msg.value < priceUpdateFee) revert Router_InvalidUpdateFee();

        priceRequestKey = _requestPriceUpdate(msg.value, _id);
    }

    function requestExecutionData(MarketId _id, bytes32 _key) external payable {
        // Fetch the position request to ensure that it's valid
        Pool.Input memory request = market.getRequest(_id, _key);
        if (request.owner == address(0)) revert Router_InvalidRequest();
        // Estimate how much the functions fulfillment will cost and ensure that the user has paid enough
        uint256 updateFee = Oracle.estimateRequestCost(address(priceFeed));
        if (msg.value < updateFee * 2) revert Router_InvalidUpdateFee();

        // Request the price update
        _requestPriceUpdate(updateFee, _id);
    }

    // Used to simply update the price of an asset
    function requestPricingForAsset(MarketId _id) external payable returns (bytes32 priceRequestKey) {
        uint256 priceUpdateFee = Oracle.estimateRequestCost(address(priceFeed));
        if (msg.value < priceUpdateFee) revert Router_InvalidUpdateFee();
        priceRequestKey = _requestPriceUpdate(msg.value, _id);
    }

    /**
     * ========================================= Internal Functions =========================================
     */
    function _requestPriceUpdate(uint256 _fee, MarketId _id) private returns (bytes32 requestKey) {
        string[] memory args = Oracle.constructPriceArguments(market.getTicker(_id));

        requestKey = priceFeed.requestPriceUpdate{value: _fee}(args, _id, msg.sender);

        emit PriceUpdateRequested(requestKey, args, msg.sender);
    }

    function _validateRequestType(
        Position.Input memory _trade,
        Position.Data memory _position,
        Position.RequestType _requestType
    ) private pure {
        bool shouldExist = _requestType != Position.RequestType.CREATE_POSITION;
        bool exists = _position.user != address(0);

        if (shouldExist != exists) {
            revert Router_InvalidRequest();
        }
        if (_requestType == Position.RequestType.POSITION_DECREASE && _trade.sizeDelta > _position.size) {
            revert Router_SizeExceedsPosition();
        }

        // SL = 3, TP = 4 --> >= checks both
        if (_requestType >= Position.RequestType.STOP_LOSS && !_trade.isLimit) {
            revert Router_InvalidConditional();
        }
    }

    function _createStopLoss(
        MarketId _id,
        ITradeStorage tradeStorage,
        Position.Request memory _request,
        Position.Conditionals memory _conditionals,
        bytes32 _requestKey
    ) internal {
        if (_conditionals.stopLossPercentage == 0 || _conditionals.stopLossPercentage > MAX_PERCENTAGE) {
            revert Router_InvalidStopLossPercentage();
        }

        if (_conditionals.stopLossPrice == 0) revert Router_InvalidStopLossPrice();

        _request.input.collateralDelta = _request.input.collateralDelta.percentage(_conditionals.stopLossPercentage);
        _request.input.sizeDelta = _request.input.sizeDelta.percentage(_conditionals.stopLossPercentage);
        _request.input.isLimit = true;
        _request.input.isIncrease = false;

        _request.input.limitPrice = _conditionals.stopLossPrice;
        _request.input.triggerAbove = _request.input.isLong ? false : true;
        _request.requestType = Position.RequestType.STOP_LOSS;

        // Set and Store the Stop Loss
        bytes32 stopLossKey = tradeStorage.setStopLoss(_id, _request, _requestKey);

        emit StopLossCreated(MarketId.unwrap(_id), _requestKey, stopLossKey, msg.sender);
    }

    function _createTakeProfit(
        MarketId _id,
        ITradeStorage tradeStorage,
        Position.Request memory _request,
        Position.Conditionals memory _conditionals,
        bytes32 _requestKey
    ) internal {
        if (_conditionals.takeProfitPercentage == 0 || _conditionals.takeProfitPercentage > MAX_PERCENTAGE) {
            revert Router_InvalidTakeProfitPercentage();
        }

        if (_conditionals.takeProfitPrice == 0) revert Router_InvalidTakeProfitPrice();

        _request.input.collateralDelta = _request.input.collateralDelta.percentage(_conditionals.takeProfitPercentage);
        _request.input.sizeDelta = _request.input.sizeDelta.percentage(_conditionals.takeProfitPercentage);
        _request.input.isLimit = true;
        _request.input.isIncrease = false;

        _request.input.limitPrice = _conditionals.takeProfitPrice;
        _request.input.triggerAbove = _request.input.isLong ? true : false;
        _request.requestType = Position.RequestType.TAKE_PROFIT;

        // Set and Store the Take Profit
        bytes32 takeProfitKey = tradeStorage.setTakeProfit(_id, _request, _requestKey);

        emit TakeProfitCreated(MarketId.unwrap(_id), _requestKey, takeProfitKey, msg.sender);
    }

    function _handleTokenTransfers(Position.Input memory _trade, uint256 _totalExecutionFee) private {
        if (_trade.reverseWrap) {
            if (_trade.collateralToken != address(WETH)) revert Router_InvalidCollateralToken();

            if (_trade.collateralDelta != msg.value - _totalExecutionFee) revert Router_InvalidAmountInForWrap();

            WETH.deposit{value: _trade.collateralDelta}();
            WETH.safeTransfer(address(positionManager), _trade.collateralDelta);
        } else {
            IERC20(_trade.collateralToken).safeTransferFrom(
                msg.sender, address(positionManager), _trade.collateralDelta
            );
        }
    }

    // Send Fee to positionManager
    function _sendExecutionFee(uint256 _executionFee) private {
        SafeTransferLib.safeTransferETH(address(positionManager), _executionFee);
    }
}
