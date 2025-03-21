// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {Funding} from "../libraries/Funding.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {Position} from "../positions/Position.sol";
import {Execution} from "./Execution.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {Referral} from "../referrals/Referral.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {TradeEngine} from "./TradeEngine.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {ITradeEngine} from "./interfaces/ITradeEngine.sol";
import {Trade} from "./Trade.sol";
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";

/// @notice Contract responsible for storing the state of active trades / requests
contract TradeStorage is ITradeStorage, OwnableRoles, ReentrancyGuard {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;

    bool initialized;

    uint64 public minCancellationTime;

    IMarket public market;
    IPriceFeed public priceFeed;
    ITradeEngine public tradeEngine;

    // Store all data for singleton trade storage
    mapping(MarketId => Trade.State) public tradeState;

    constructor(address _market, address _priceFeed) {
        _initializeOwner(msg.sender);
        market = IMarket(_market);
        priceFeed = IPriceFeed(_priceFeed);
    }

    /**
     * =========================================== Setter Functions ===========================================
     */
    function initialize(address _tradeEngine, address _marketFactory) external onlyOwner {
        if (initialized) revert TradeStorage_AlreadyInitialized();
        tradeEngine = ITradeEngine(_tradeEngine);
        _grantRoles(_tradeEngine, _ROLE_6);
        _grantRoles(_marketFactory, _ROLE_0);
        initialized = true;
    }

    function initializePool(MarketId _id, address _vault) external onlyRoles(_ROLE_0) {
        Trade.State storage state = tradeState[_id];

        if (state.isInitialized) revert TradeStorage_AlreadyInitialized();

        state.vault = IVault(_vault);

        state.isInitialized = true;
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    function updateTradeEngine(address _tradeEngine) external onlyOwner {
        tradeEngine = ITradeEngine(_tradeEngine);
    }

    function updateMarket(address _market) external onlyOwner {
        market = IMarket(_market);
    }

    // Time until a position request can be cancelled by a user
    function setMinCancellationTime(uint64 _minCancellationTime) external onlyOwner {
        minCancellationTime = _minCancellationTime;
    }

    /**
     * =========================================== Order Functions ===========================================
     */
    function createOrderRequest(MarketId _id, Position.Request calldata _request)
        external
        onlyRoles(_ROLE_3)
        returns (bytes32 orderKey)
    {
        EnumerableSetLib.Bytes32Set storage orderSet =
            _request.input.isLimit ? tradeState[_id].limitOrderKeys : tradeState[_id].marketOrderKeys;

        orderKey = Position.generateOrderKey(_request);
        if (orderSet.contains(orderKey)) revert TradeStorage_OrderAlreadyExists();

        bool success = orderSet.add(orderKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();

        tradeState[_id].orders[orderKey] = _request;

        if (_request.requestType >= Position.RequestType.STOP_LOSS) _attachConditionalOrder(_id, _request, orderKey);
    }

    function cancelOrderRequest(MarketId _id, bytes32 _orderKey, bool _isLimit) external onlyRoles(_ROLE_1) {
        _deleteOrder(_id, _orderKey, _isLimit);
    }

    /// @dev - Clears a conditional order from a position
    function clearConditionalOrder(MarketId _id, bytes32 _positionKey, bool _isStopLoss) external onlyRoles(_ROLE_1) {
        Position.Data storage position = tradeState[_id].openPositions[_positionKey];
        if (_isStopLoss) {
            delete position.stopLossKey;
        } else {
            delete position.takeProfitKey;
        }
    }

    function setStopLoss(MarketId _id, Position.Request calldata _request, bytes32 _orderKey)
        external
        onlyRoles(_ROLE_3)
        returns (bytes32 stopLossKey)
    {
        // Stop Loss is always Limit
        EnumerableSetLib.Bytes32Set storage orderSet = tradeState[_id].limitOrderKeys;

        // Create and store the stop loss order
        stopLossKey = Position.generateOrderKey(_request);
        if (orderSet.contains(stopLossKey)) revert TradeStorage_OrderAlreadyExists();

        bool success = orderSet.add(stopLossKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();

        // Attach the stop loss order to the existing Order
        tradeState[_id].orders[_orderKey].stopLossKey = stopLossKey;

        // Store the Stop Loss
        tradeState[_id].orders[stopLossKey] = _request;
    }

    function setTakeProfit(MarketId _id, Position.Request calldata _request, bytes32 _orderKey)
        external
        onlyRoles(_ROLE_3)
        returns (bytes32 takeProfitKey)
    {
        // Take Profit is always Limit
        EnumerableSetLib.Bytes32Set storage orderSet = tradeState[_id].limitOrderKeys;

        // Create and store the Take Profit order
        takeProfitKey = Position.generateOrderKey(_request);
        if (orderSet.contains(takeProfitKey)) revert TradeStorage_OrderAlreadyExists();

        bool success = orderSet.add(takeProfitKey);
        if (!success) revert TradeStorage_OrderAdditionFailed();

        // Attach the Take Profit order to the existing Order
        tradeState[_id].orders[_orderKey].takeProfitKey = takeProfitKey;

        // Store the Take Profit
        tradeState[_id].orders[takeProfitKey] = _request;
    }

    /**
     * =========================================== Callback Functions ===========================================
     */
    function deletePosition(MarketId _id, bytes32 _positionKey, bool _isLong) external onlyRoles(_ROLE_6) {
        Trade.State storage state = tradeState[_id];

        delete state.openPositions[_positionKey];
        bool success = state.openPositionKeys[_isLong].remove(_positionKey);
        if (!success) revert TradeStorage_PositionRemovalFailed();
    }

    function createPosition(MarketId _id, Position.Data calldata _position, bytes32 _positionKey)
        external
        onlyRoles(_ROLE_6)
    {
        Trade.State storage state = tradeState[_id];

        state.openPositions[_positionKey] = _position;
        bool success = state.openPositionKeys[_position.isLong].add(_positionKey);
        if (!success) revert TradeStorage_PositionAdditionFailed();
    }

    function deleteOrder(MarketId _id, bytes32 _orderKey, bool _isLimit) external onlyRoles(_ROLE_6) {
        _deleteOrder(_id, _orderKey, _isLimit);
    }

    function updatePosition(MarketId _id, Position.Data calldata _position, bytes32 _positionKey)
        external
        onlyRoles(_ROLE_6)
    {
        tradeState[_id].openPositions[_positionKey] = _position;
    }

    /**
     * =========================================== Execution Functions ===========================================
     */

    /// @dev needs to accept request id for limit order cases
    /// the request id at the time of request won't be the same as the request id at execution time
    /// @notice the main function responsible for execution of position requests
    function executePositionRequest(MarketId _id, bytes32 _orderKey, bytes32 _limitRequestKey, address _feeReceiver)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
        returns (Execution.FeeState memory feeState, Position.Request memory request)
    {
        Position.Settlement memory params;
        params.orderKey = _orderKey;
        params.limitRequestKey = _limitRequestKey;
        params.feeReceiver = _feeReceiver;

        (feeState, request) = tradeEngine.executePositionRequest(_id, params);
    }

    function liquidatePosition(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _liquidator)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
    {
        tradeEngine.liquidatePosition(_id, _positionKey, _requestKey, _liquidator);
    }

    function executeAdl(MarketId _id, bytes32 _positionKey, bytes32 _requestKey, address _feeReceiver)
        external
        onlyRoles(_ROLE_1)
        nonReentrant
    {
        tradeEngine.executeAdl(_id, _positionKey, _requestKey, _feeReceiver);
    }

    /**
     * =========================================== Private Functions ===========================================
     */
    function _deleteOrder(MarketId _id, bytes32 _orderKey, bool _isLimit) private {
        Trade.State storage state = tradeState[_id];

        bool success = _isLimit ? state.limitOrderKeys.remove(_orderKey) : state.marketOrderKeys.remove(_orderKey);
        if (!success) revert TradeStorage_OrderRemovalFailed();
        delete state.orders[_orderKey];
        emit OrderRequestCancelled(MarketId.unwrap(_id), _orderKey);
    }

    /// @dev Attaches a Conditional Order to a live Position
    function _attachConditionalOrder(MarketId _id, Position.Request calldata _request, bytes32 _orderKey) private {
        bytes32 positionKey = Position.generateKey(_request);

        Trade.State storage state = tradeState[_id];

        Position.Data memory position = state.openPositions[positionKey];

        if (position.user == address(0)) revert TradeStorage_InactivePosition();

        if (_request.requestType == Position.RequestType.STOP_LOSS) {
            if (position.stopLossKey != bytes32(0)) revert TradeStorage_StopLossAlreadySet();
            position.stopLossKey = _orderKey;
            state.openPositions[positionKey] = position;
        } else if (_request.requestType == Position.RequestType.TAKE_PROFIT) {
            if (position.takeProfitKey != bytes32(0)) revert TradeStorage_TakeProfitAlreadySet();
            position.takeProfitKey = _orderKey;
            state.openPositions[positionKey] = position;
        }
    }

    /**
     * =========================================== Getter Functions ===========================================
     */
    function getOpenPositionKeys(MarketId _id, bool _isLong) external view returns (bytes32[] memory) {
        return tradeState[_id].openPositionKeys[_isLong].values();
    }

    function getOrderKeys(MarketId _id, bool _isLimit) external view returns (bytes32[] memory) {
        return _isLimit ? tradeState[_id].limitOrderKeys.values() : tradeState[_id].marketOrderKeys.values();
    }

    /// @notice - Get the position data for a given position key.
    function getPosition(MarketId _id, bytes32 _positionKey) external view returns (Position.Data memory) {
        return tradeState[_id].openPositions[_positionKey];
    }

    function getPosition(MarketId _id, string calldata _ticker, address _user, bool _isLong)
        external
        view
        returns (Position.Data memory)
    {
        bytes32 positionKey = Position.generateKey(_ticker, _user, _isLong);
        return tradeState[_id].openPositions[positionKey];
    }

    /// @notice - Get the request data for a given order key.
    function getOrder(MarketId _id, bytes32 _orderKey) external view returns (Position.Request memory) {
        return tradeState[_id].orders[_orderKey];
    }

    function getOrder(
        MarketId _id,
        string memory _ticker,
        address _user,
        bool _isLong,
        bool _isIncrease,
        uint256 _limitPrice
    ) external view returns (Position.Request memory) {
        bytes32 orderKey = keccak256(abi.encode(_ticker, _user, _isLong, _isIncrease, _limitPrice));
        return tradeState[_id].orders[orderKey];
    }

    function getOrderAtIndex(MarketId _id, uint256 _index, bool _isLimit) external view returns (bytes32) {
        return _isLimit ? tradeState[_id].limitOrderKeys.at(_index) : tradeState[_id].marketOrderKeys.at(_index);
    }
}
