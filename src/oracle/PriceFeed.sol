// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {IMarketFactory} from "../factory/interfaces/IMarketFactory.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IWETH} from "../tokens/interfaces/IWETH.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {Oracle} from "./Oracle.sol";
import {LibString} from "../../src/libraries/LibString.sol";
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";
import {IPositionManager} from "../router/interfaces/IPositionManager.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";

contract PriceFeed is ReentrancyGuard, OwnableRoles, IPriceFeed {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using LibString for bytes15;
    using MarketIdLibrary for bytes32;

    uint256 public constant PRICE_DECIMALS = 30;

    uint8 private constant WORD = 32;
    uint16 private constant MAX_DATA_LENGTH = 3296;
    uint8 private constant MAX_ARGS_LENGTH = 4;

    address public immutable WETH;

    IMarketFactory public marketFactory;
    IMarket market;

    address public pyth;
    address public sequencerUptimeFeed;
    bool private isInitialized;

    //Callback gas limit
    uint256 public gasOverhead;
    uint256 public premiumFee;
    uint32 public callbackGasLimit;
    uint48 public timeToExpiration;

    mapping(string ticker => mapping(uint48 blockTimestamp => Price priceResponse)) private prices;
    mapping(string ticker => Price priceResponse) private lastPrice;

    mapping(string ticker => SecondaryStrategy) private strategies;
    mapping(string ticker => uint8) public tokenDecimals;

    // Dictionary to enable clearing of the RequestKey
    // Bi-directional to handle the case of invalidated requests
    mapping(bytes32 requestId => bytes32 requestKey) public idToKey;
    mapping(bytes32 requestKey => bytes32 requestId) public keyToId;

    // Used to track whether a price has been attempted or not.
    mapping(bytes32 requestKey => bool attempted) public fullfillmentAttempted;

    mapping(bytes32 requestId => RequestData) private requestData;

    // Used to track if a request has been fulfilled
    mapping(bytes32 requestId => bool fulfilled) private fulfilledRequests;

    EnumerableSetLib.Bytes32Set private assetIds;
    EnumerableSetLib.Bytes32Set private requestKeys;

    modifier onlyFactoryOrRouter() {
        if (rolesOf(msg.sender) != _ROLE_0 && rolesOf(msg.sender) != _ROLE_3) revert Unauthorized();
        _;
    }

    constructor(address _marketFactory, address _weth, address _pyth) {
        _initializeOwner(msg.sender);
        marketFactory = IMarketFactory(_marketFactory);
        WETH = _weth;
        pyth = _pyth;
    }

    receive() external payable {}

    function initialize(uint256 _gasOverhead, uint32 _callbackGasLimit, uint256 _premiumFee, uint48 _timeToExpiration)
        external
        onlyOwner
    {
        if (isInitialized) revert PriceFeed_AlreadyInitialized();
        gasOverhead = _gasOverhead;
        callbackGasLimit = _callbackGasLimit;
        premiumFee = _premiumFee;
        timeToExpiration = _timeToExpiration;
        isInitialized = true;
    }

    function updateBillingParameters(uint256 _gasOverhead, uint32 _callbackGasLimit, uint256 _premiumFee)
        external
        onlyOwner
    {
        gasOverhead = _gasOverhead;
        callbackGasLimit = _callbackGasLimit;
        premiumFee = _premiumFee;
    }

    function supportAsset(string memory _ticker, SecondaryStrategy calldata _strategy, uint8 _tokenDecimals)
        external
        onlyRoles(_ROLE_0)
    {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (assetIds.contains(assetId)) return; // Return if already supported
        bool success = assetIds.add(assetId);
        if (!success) revert PriceFeed_AssetSupportFailed();
        strategies[_ticker] = _strategy;
        tokenDecimals[_ticker] = _tokenDecimals;
        emit AssetSupported(_ticker, _tokenDecimals);
    }

    function unsupportAsset(string memory _ticker) external onlyOwner {
        bytes32 assetId = keccak256(abi.encode(_ticker));
        if (!assetIds.contains(assetId)) return; // Return if not supported
        bool success = assetIds.remove(assetId);
        if (!success) revert PriceFeed_AssetRemovalFailed();
        delete strategies[_ticker];
        delete tokenDecimals[_ticker];
        emit SupportRemoved(_ticker);
    }

    function updateDataFeeds(address _pyth, address _sequencerUptimeFeed) external onlyOwner {
        pyth = _pyth;
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function updateSecondaryStrategy(string memory _ticker, SecondaryStrategy memory _strategy) external onlyOwner {
        strategies[_ticker] = _strategy;
    }

    function setTimeToExpiration(uint48 _timeToExpiration) external onlyOwner {
        timeToExpiration = _timeToExpiration;
    }

    function clearInvalidRequest(bytes32 _requestId) external onlyOwner {
        delete requestData[_requestId];
    }

    /**
     * @notice Sends an HTTP request for character information
     * @param args The arguments to pass to the HTTP request -> should be the tickers for which pricing is requested
     * @return requestKey The signature of the request
     */
    function requestPriceUpdate(string[] calldata args, MarketId _marketId, address _requester)
        external
        payable
        onlyFactoryOrRouter
        nonReentrant
        returns (bytes32)
    {
        uint48 blockTimestamp = _blockTimestamp();

        if (args.length > MAX_ARGS_LENGTH) revert PriceFeed_InvalidArgsLength();

        bytes32 requestKey = _generateKey(abi.encode(args, _requester, blockTimestamp));

        if (requestKeys.contains(requestKey)) return requestKey;

        bytes32 requestId = _generateRequestId(args);

        RequestData memory data = RequestData({requester: _requester, blockTimestamp: blockTimestamp, args: args});

        requestKeys.add(requestKey);
        idToKey[requestId] = requestKey;
        keyToId[requestKey] = requestId;
        requestData[requestId] = data;

        emit PriceUpdateRequested(requestId, MarketId.unwrap(_marketId), _requester, abi.encode(args));

        return requestKey;
    }

    /**
     * @notice Fast fulfillment function for authorized callers - V SENSITIVE!
     * @param requestId The ID of the request to fulfill
     * @param response The bytes encoded response data
     * @param err Any errors from the Functions request
     */
    function fastFulfillRequest(bytes32 requestId, bytes memory response, bytes memory err)
        external
        onlyRoles(_ROLE_69)
    {
        _processFulfillment(requestId, response, err, false);
    }

    function settleAccumulatedFees(address usdc) external onlyOwner nonReentrant {
        uint256 ethBalance = address(this).balance;

        if (ethBalance > 0) {
            SafeTransferLib.safeTransferETH(payable(msg.sender), ethBalance);
        }

        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));

        if (usdcBalance > 0) {
            SafeTransferLib.safeTransfer(IERC20(usdc), payable(msg.sender), usdcBalance);
        }
    }

    /**
     * ================================== Execution Functions ==================================
     */

    /**
     * @notice Used to rapidly set a price and execute a position simultaneously for limit orders and liquidations.
     */
    function setPricesAndExecutePosition(
        IPositionManager positionManager,
        bytes memory priceData, // fulfilled price data
        bytes memory err,
        string calldata _ticker, // custom id
        MarketId _id,
        bytes32 _orderKey,
        uint48 _timestamp, // Must match the timestamp encoded in the priceData
        bool _isLimit // Limit or liquidation
    ) external onlyRoles(_ROLE_69) nonReentrant {
        // Create a price request -> acts as an instant replacement for requestPriceUpdate
        string[] memory args = Oracle.constructPriceArguments(_ticker);

        // Generate a random key from the response
        bytes32 requestKey = _generateKey(abi.encode(args, msg.sender, _timestamp));

        bytes32 requestId = _generateRequestId(args);

        // For liquidations, set address(this), so it passes validatePriceRequest
        RequestData memory data =
            RequestData({requester: _isLimit ? msg.sender : address(this), blockTimestamp: _timestamp, args: args});

        requestKeys.add(requestKey);
        idToKey[requestId] = requestKey;
        keyToId[requestKey] = requestId;
        requestData[requestId] = data;

        // Fulfill the price request
        _processFulfillment(requestId, priceData, err, true);

        if (_isLimit) {
            positionManager.executePosition(_id, _orderKey, idToKey[requestId], msg.sender);
        } else {
            // Tokens will be sent to this contract. They can be withdrawn by the owner.
            positionManager.liquidatePosition(_id, _orderKey, idToKey[requestId]);
        }
    }

    /**
     * @notice Used to rapidly set a price and execute a market creation simultaneously.
     */
    function setPricesAndExecuteMarket(
        bytes memory priceData, // fulfilled price data
        bytes memory err,
        bytes32 _requestId,
        bytes32 _marketRequestKey
    ) external onlyRoles(_ROLE_69) nonReentrant {
        // Fulfill the price request
        _processFulfillment(_requestId, priceData, err, true);

        // Execute the market
        marketFactory.executeMarketRequest(_marketRequestKey);
    }

    /**
     * @notice Used to rapidly set a price and execute a market order simultaneously.
     */
    function setPricesAndExecuteOrder(
        IPositionManager positionManager,
        bytes memory priceData, // fulfilled price data
        bytes memory err,
        MarketId _id,
        bytes32 _orderKey,
        bytes32 _requestId
    ) external onlyRoles(_ROLE_69) nonReentrant {
        // Fulfill the price request
        _processFulfillment(_requestId, priceData, err, true);

        // Execute the order
        positionManager.executePosition(_id, _orderKey, idToKey[_requestId], msg.sender);
    }

    function setPricesAndExecuteDepositWithdrawal(
        IPositionManager positionManager,
        bytes memory priceData, // fulfilled price data
        bytes memory err,
        MarketId _id,
        bytes32 _orderKey,
        bytes32 _requestId,
        bool _isDeposit
    ) external onlyRoles(_ROLE_69) nonReentrant {
        // Fulfill the price request
        _processFulfillment(_requestId, priceData, err, true);

        // Execute the order
        if (_isDeposit) {
            positionManager.executeDeposit(_id, _orderKey);
        } else {
            positionManager.executeWithdrawal(_id, _orderKey);
        }
    }

    /**
     * ================================== Private Functions ==================================
     */
    /**
     * @dev Internal helper function to process fulfillment logic
     * @param requestId The ID of the request to fulfill
     * @param response The bytes encoded response data
     * @param err Any errors from the Functions request
     * @param skipFulfilled If true, will not revert if the request has already been fulfilled
     */
    function _processFulfillment(bytes32 requestId, bytes memory response, bytes memory err, bool skipFulfilled)
        internal
    {
        if (requestData[requestId].requester == address(0)) revert PriceFeed_RequestNotFound();
        if (fulfilledRequests[requestId]) {
            if (skipFulfilled) {
                return;
            }
            revert PriceFeed_RequestAlreadyFulfilled();
        }

        bytes32 requestKey = idToKey[requestId];
        fullfillmentAttempted[requestKey] = true;

        if (err.length > 0) {
            revert PriceFeed_FastFulfillmentFailed();
        }

        fulfilledRequests[requestId] = true;
        RequestData memory data = requestData[requestId];
        requestKeys.remove(requestKey);
        _decodeAndStorePrices(response);

        emit Response(requestId, data, response, err);
    }

    function _generateRequestId(string[] memory _args) private view returns (bytes32 requestId) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, address(this)));
        requestId = keccak256(abi.encode(salt, _args));
    }

    function _decodeAndStorePrices(bytes memory _encodedPrices) private {
        if (_encodedPrices.length > MAX_DATA_LENGTH) revert PriceFeed_PriceUpdateLength();
        if (_encodedPrices.length % WORD != 0) revert PriceFeed_PriceUpdateLength();

        uint256 numPrices = _encodedPrices.length / 32;

        for (uint16 i = 0; i < numPrices;) {
            bytes32 encodedPrice;

            // Use yul to extract the encoded price from the bytes
            // offset = (32 * i) + 32 (first 32 bytes are the length of the byte string)
            // encodedPrice = mload(encodedPrices[offset:offset+32])
            /// @solidity memory-safe-assembly
            assembly {
                encodedPrice := mload(add(_encodedPrices, add(32, mul(i, 32))))
            }

            Price memory price = Price(
                // First 15 bytes are the ticker
                bytes15(encodedPrice),
                // Next byte is the precision
                uint8(encodedPrice[15]),
                // Shift recorded values to the left and store the first 2 bytes (variance)
                uint16(bytes2(encodedPrice << 128)),
                // Shift recorded values to the left and store the first 6 bytes (timestamp)
                uint48(bytes6(encodedPrice << 144)),
                // Shift recorded values to the left and store the first 8 bytes (median price)
                uint64(bytes8(encodedPrice << 192))
            );

            if (!Oracle.validatePrice(this, price)) return;

            string memory ticker = price.ticker.fromSmallString();

            prices[ticker][price.timestamp] = price;
            lastPrice[ticker] = price;

            emit PriceUpdated(price.ticker, price.timestamp, price.med, price.variance);

            unchecked {
                ++i;
            }
        }
    }

    function _blockTimestamp() internal view returns (uint48) {
        return uint48(block.timestamp);
    }

    function _generateKey(bytes memory _args) internal pure returns (bytes32) {
        return keccak256(_args);
    }

    /**
     * ================================== External / Getter Functions ==================================
     */
    function getPrices(string memory _ticker, uint48 _timestamp) external view returns (Price memory signedPrices) {
        signedPrices = prices[_ticker][_timestamp];
        if (signedPrices.timestamp == 0) revert PriceFeed_PriceRequired(_ticker);
        if (signedPrices.timestamp + timeToExpiration < block.timestamp) revert PriceFeed_PriceExpired();
    }

    function getSecondaryStrategy(string memory _ticker) external view returns (SecondaryStrategy memory) {
        return strategies[_ticker];
    }

    function priceUpdateRequested(bytes32 _requestId) external view returns (bool) {
        return requestData[_requestId].requester != address(0);
    }

    function isValidAsset(string memory _ticker) external view returns (bool) {
        return assetIds.contains(keccak256(abi.encode(_ticker)));
    }

    function getRequester(bytes32 _requestId) external view returns (address) {
        return requestData[_requestId].requester;
    }

    function getRequestData(bytes32 _requestKey) external view returns (RequestData memory) {
        bytes32 requestId = keyToId[_requestKey];
        return requestData[requestId];
    }

    function isRequestValid(bytes32 _requestKey) external view returns (bool) {
        bytes32 requestId = keyToId[_requestKey];
        if (requestData[requestId].requester != address(0)) {
            return requestData[requestId].blockTimestamp + timeToExpiration > block.timestamp;
        } else {
            return false;
        }
    }

    function getRequestTimestamp(bytes32 _requestKey) external view returns (uint48) {
        bytes32 requestId = keyToId[_requestKey];
        return requestData[requestId].blockTimestamp;
    }

    function getRequests() external view returns (bytes32[] memory) {
        return requestKeys.values();
    }

    function getLastPrice(string memory _ticker) external view returns (Price memory) {
        return lastPrice[_ticker];
    }
}
