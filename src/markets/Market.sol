// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./interfaces/IMarket.sol";
import {OwnableRoles} from "../auth/OwnableRoles.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {EnumerableSetLib} from "../libraries/EnumerableSetLib.sol";
import {EnumerableMap} from "../libraries/EnumerableMap.sol";
import {IVault, IERC20} from "./interfaces/IVault.sol";
import {MarketUtils} from "./MarketUtils.sol";
import {Casting} from "../libraries/Casting.sol";
import {IPriceFeed} from "../oracle/interfaces/IPriceFeed.sol";
import {ITradeStorage} from "../positions/interfaces/ITradeStorage.sol";
import {Pool} from "./Pool.sol";
import {Oracle} from "../oracle/Oracle.sol";
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";
import {Execution} from "../positions/Execution.sol";
import {IRewardTracker} from "../rewards/interfaces/IRewardTracker.sol";

contract Market is IMarket, OwnableRoles, ReentrancyGuard {
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using EnumerableMap for EnumerableMap.MarketMap;
    using Casting for int256;

    uint64 private constant MIN_BORROW_SCALE = 0.0001e18; // 0.01% per day
    uint64 private constant MAX_BORROW_SCALE = 0.01e18; // 1% per day
    uint8 private constant MAX_ASSETS = 100;
    uint8 private constant TOTAL_ALLOCATION = 100;
    uint48 private constant TIME_TO_EXPIRATION = 1 minutes;

    /**
     * Level of proportional skew beyond which funding rate starts to change
     * Units: % Per Day
     */
    uint64 public constant FUNDING_VELOCITY_CLAMP = 0.00001e18; // 0.001% per day

    string private constant LONG_TICKER = "ETH:1";
    string private constant SHORT_TICKER = "USDC:1";
    bool private initialized;

    address private immutable WETH;
    address private immutable USDC;

    ITradeStorage public tradeStorage;
    IPriceFeed public priceFeed;

    // 18 dp percentage: 1e18 = 100%
    uint64 public priceImpactScalar;

    // Each Asset's storage is tracked through this mapping
    mapping(MarketId => Pool.Storage assetStorage) private marketStorage;
    mapping(MarketId => Pool.GlobalState) private globalState;

    modifier orderExists(MarketId _id, bytes32 _key) {
        _orderExists(_id, _key);
        _;
    }

    modifier onlyPoolOwner(MarketId _id) {
        _isPoolOwner(_id);
        _;
    }

    /**
     *  =========================================== Constructor  ===========================================
     */
    constructor(address _weth, address _usdc) {
        _initializeOwner(msg.sender);
        WETH = _weth;
        USDC = _usdc;
    }

    function initialize(address _tradeStorage, address _priceFeed, address _marketFactory) external onlyOwner {
        if (initialized) revert Market_AlreadyInitialized();
        tradeStorage = ITradeStorage(_tradeStorage);
        priceFeed = IPriceFeed(_priceFeed);
        _grantRoles(_marketFactory, _ROLE_0);
        priceImpactScalar = 1e18;
        initialized = true;
    }

    function setPriceImpactScalar(uint64 _priceImpactScalar) external onlyOwner {
        priceImpactScalar = _priceImpactScalar;
    }

    // Only Market Factory
    function initializePool(
        MarketId _id,
        Pool.Config memory _config,
        address _poolOwner,
        uint256 _borrowScale,
        address _marketToken,
        string memory _ticker
    ) external onlyRoles(_ROLE_0) {
        Pool.GlobalState storage state = globalState[_id];

        if (state.isInitialized) revert Market_AlreadyInitialized();

        state.ticker = _ticker;

        Pool.initialize(marketStorage[_id], _config);

        emit TokenAdded(_ticker);

        state.poolOwner = _poolOwner;
        state.vault = IVault(_marketToken);
        state.borrowScale = _borrowScale;

        state.isInitialized = true;

        emit Market_Initialized();
    }
    /**
     * =========================================== Admin Functions  ===========================================
     */

    function transferPoolOwnership(MarketId _id, address _newOwner) external {
        Pool.GlobalState storage state = globalState[_id];

        if (msg.sender != state.poolOwner || _newOwner == address(0)) revert Market_InvalidPoolOwner();

        state.poolOwner = _newOwner;
    }

    function updateConfig(MarketId _id, Pool.Config calldata _config, uint256 _borrowScale)
        external
        onlyPoolOwner(_id)
    {
        Pool.GlobalState storage state = globalState[_id];

        if (_borrowScale < MIN_BORROW_SCALE || _borrowScale > MAX_BORROW_SCALE) revert Market_InvalidBorrowScale();

        uint256 totalOpenInterest = marketStorage[_id].longOpenInterest + marketStorage[_id].shortOpenInterest;

        Pool.validateConfig(_config, totalOpenInterest);

        state.borrowScale = _borrowScale;

        if (_config.maxLeverage != marketStorage[_id].config.maxLeverage) {
            revert Market_MaxLeverageDelta();
        }

        marketStorage[_id].config = _config;

        emit MarketConfigUpdated(MarketId.unwrap(_id));
    }

    function setMaxLeverage(MarketId _id, uint16 _maxLeverage) external onlyOwner {
        Pool.validateLeverage(_maxLeverage);
        marketStorage[_id].config.maxLeverage = _maxLeverage;
    }

    function updatePriceFeed(IPriceFeed _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
    }

    /**
     * =========================================== User Interaction Functions  ===========================================
     */
    function createRequest(
        MarketId _id,
        address _owner,
        address _transferToken, // Token In for Deposits, Out for Withdrawals
        uint256 _amountIn,
        uint256 _executionFee,
        bytes32 _priceRequestKey,
        uint40 _stakeDuration,
        bool _reverseWrap,
        bool _isDeposit
    ) external payable onlyRoles(_ROLE_3) returns (bytes32 requestKey) {
        Pool.GlobalState storage state = globalState[_id];
        Pool.Input memory request = Pool.createRequest(
            _owner,
            _transferToken,
            _amountIn,
            _executionFee,
            _priceRequestKey,
            WETH,
            _stakeDuration,
            _reverseWrap,
            _isDeposit
        );
        if (!state.requests.set(request.key, request)) revert Market_FailedToAddRequest();
        emit RequestCreated(request.key, _owner, _transferToken, _amountIn, _isDeposit);

        return request.key;
    }

    function cancelRequest(MarketId _id, bytes32 _requestKey, address _caller)
        external
        onlyRoles(_ROLE_1)
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap)
    {
        Pool.GlobalState storage state = globalState[_id];

        if (!state.requests.contains(_requestKey)) revert Market_InvalidKey();

        Pool.Input memory request = state.requests.get(_requestKey);
        if (request.owner != _caller) revert Market_NotRequestOwner();

        if (request.requestTimestamp + TIME_TO_EXPIRATION > block.timestamp) revert Market_RequestNotExpired();

        if (!state.requests.remove(_requestKey)) revert Market_FailedToRemoveRequest();

        if (request.isDeposit) {
            // If deposit, token out is the token in
            tokenOut = request.isLongToken ? WETH : USDC;
            shouldUnwrap = request.reverseWrap;
        } else {
            // If withdrawal, token out is market tokens
            tokenOut = address(state.vault);
            shouldUnwrap = false;
        }
        amountOut = request.amountIn;

        emit RequestCanceled(_requestKey, _caller);
    }

    /**
     * =========================================== Vault Actions ===========================================
     */
    function executeDeposit(MarketId _id, IVault.ExecuteDeposit calldata _params)
        external
        onlyRoles(_ROLE_1)
        orderExists(_id, _params.key)
        nonReentrant
        returns (uint256)
    {
        Pool.GlobalState storage state = globalState[_id];
        if (!state.requests.remove(_params.key)) revert Market_FailedToRemoveRequest();
        return state.vault.executeDeposit(_params, _params.deposit.isLongToken ? WETH : USDC, msg.sender);
    }

    function executeWithdrawal(MarketId _id, IVault.ExecuteWithdrawal calldata _params)
        external
        onlyRoles(_ROLE_1)
        orderExists(_id, _params.key)
        nonReentrant
    {
        Pool.GlobalState storage state = globalState[_id];
        if (!state.requests.remove(_params.key)) revert Market_FailedToRemoveRequest();
        state.vault.executeWithdrawal(_params, _params.withdrawal.isLongToken ? WETH : USDC, msg.sender);
    }

    /**
     * =========================================== External State Functions  ===========================================
     */
    function updateMarketState(
        MarketId _id,
        string calldata _ticker,
        uint256 _sizeDelta,
        Execution.Prices memory _prices,
        bool _isLong,
        bool _isIncrease
    ) external nonReentrant onlyRoles(_ROLE_6) {
        Pool.Storage storage self = marketStorage[_id];

        Pool.updateState(_id, this, self, _ticker, _sizeDelta, _prices, _isLong, _isIncrease);
    }

    function updateImpactPool(MarketId _id, int256 _priceImpactUsd) external nonReentrant onlyRoles(_ROLE_6) {
        _priceImpactUsd > 0
            ? marketStorage[_id].impactPool += _priceImpactUsd.abs()
            : marketStorage[_id].impactPool -= _priceImpactUsd.abs();
    }

    /**
     * =========================================== Private Functions  ===========================================
     */
    function _validateOpenInterest(
        MarketId _id,
        IVault vault,
        string memory _ticker,
        uint256 _longSignedPrice,
        uint256 _shortSignedPrice
    ) private view {
        uint256 indexBaseUnit = Oracle.getBaseUnit(priceFeed, _ticker);

        uint256 longMaxOi = MarketUtils.getMaxOpenInterest(_id, this, vault, _longSignedPrice, indexBaseUnit, true);

        if (longMaxOi < marketStorage[_id].longOpenInterest) revert Market_InvalidAllocation();

        uint256 shortMaxOi = MarketUtils.getMaxOpenInterest(_id, this, vault, _shortSignedPrice, indexBaseUnit, false);

        if (shortMaxOi < marketStorage[_id].shortOpenInterest) revert Market_InvalidAllocation();
    }

    function _orderExists(MarketId _id, bytes32 _orderKey) private view {
        if (!globalState[_id].requests.contains(_orderKey)) revert Market_InvalidKey();
    }

    function _isPoolOwner(MarketId _id) internal view returns (bool) {
        return msg.sender == globalState[_id].poolOwner;
    }

    /**
     * =========================================== Getter Functions  ===========================================
     */
    function getVault(MarketId _id) external view returns (IVault) {
        return globalState[_id].vault;
    }

    function getRewardTracker(MarketId _id) external view returns (IRewardTracker) {
        IVault vault = globalState[_id].vault;
        return vault.rewardTracker();
    }

    function getBorrowScale(MarketId _id) external view returns (uint256) {
        return globalState[_id].borrowScale;
    }

    function getStorage(MarketId _id) external view returns (Pool.Storage memory) {
        return marketStorage[_id];
    }

    function getConfig(MarketId _id) external view returns (Pool.Config memory) {
        return marketStorage[_id].config;
    }

    function getCumulatives(MarketId _id) external view returns (Pool.Cumulatives memory) {
        return marketStorage[_id].cumulatives;
    }

    function getImpactPool(MarketId _id) external view returns (uint256) {
        return marketStorage[_id].impactPool;
    }

    function getRequest(MarketId _id, bytes32 _requestKey) external view returns (Pool.Input memory) {
        return globalState[_id].requests.get(_requestKey);
    }

    function getRequestAtIndex(MarketId _id, uint256 _index) external view returns (Pool.Input memory request) {
        (, request) = globalState[_id].requests.at(_index);
    }

    function getTicker(MarketId _id) external view returns (string memory) {
        return globalState[_id].ticker;
    }

    function getLastUpdate(MarketId _id) external view returns (uint48) {
        return marketStorage[_id].lastUpdate;
    }

    function getFundingRates(MarketId _id) external view returns (int64, int64) {
        return (marketStorage[_id].fundingRate, marketStorage[_id].fundingRateVelocity);
    }

    function getCumulativeBorrowFees(MarketId _id)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees)
    {
        return (
            marketStorage[_id].cumulatives.longCumulativeBorrowFees,
            marketStorage[_id].cumulatives.shortCumulativeBorrowFees
        );
    }

    function getCumulativeBorrowFee(MarketId _id, bool _isLong) public view returns (uint256) {
        return _isLong
            ? marketStorage[_id].cumulatives.longCumulativeBorrowFees
            : marketStorage[_id].cumulatives.shortCumulativeBorrowFees;
    }

    function getFundingAccrued(MarketId _id) external view returns (int256) {
        return marketStorage[_id].fundingAccruedUsd;
    }

    function getBorrowingRate(MarketId _id, bool _isLong) external view returns (uint256) {
        return _isLong ? marketStorage[_id].longBorrowingRate : marketStorage[_id].shortBorrowingRate;
    }

    function getMaxLeverage(MarketId _id) external view returns (uint16) {
        return marketStorage[_id].config.maxLeverage;
    }

    function getOpenInterest(MarketId _id, bool _isLong) external view returns (uint256) {
        return _isLong ? marketStorage[_id].longOpenInterest : marketStorage[_id].shortOpenInterest;
    }

    function getAverageCumulativeBorrowFee(MarketId _id, bool _isLong) external view returns (uint256) {
        return _isLong
            ? marketStorage[_id].cumulatives.weightedAvgCumulativeLong
            : marketStorage[_id].cumulatives.weightedAvgCumulativeShort;
    }
}
