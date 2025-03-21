// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "./IMarket.sol";
import {ITradeStorage} from "../../positions/interfaces/ITradeStorage.sol";
import {Oracle} from "../../oracle/Oracle.sol";
import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {IVault} from "./IVault.sol";
import {Pool} from "../Pool.sol";
import {MarketId, MarketIdLibrary} from "../../types/MarketId.sol";
import {Execution} from "../../positions/Execution.sol";

interface IMarket {
    /**
     * ================ Errors ================
     */
    error Market_InvalidKey();
    error Market_InvalidPoolOwner();
    error Market_MaxLeverageDelta();
    error Market_AlreadyInitialized();
    error Market_InvalidBorrowScale();
    error Market_FailedToRemoveRequest();
    error Market_InvalidAllocation();
    error Market_NotRequestOwner();
    error Market_RequestNotExpired();
    error Market_FailedToAddRequest();

    /**
     * ================ Events ================
     */
    event TokenAdded(string ticker);
    event MarketConfigUpdated(bytes32 indexed marketId);
    event Market_Initialized();
    event FeesAccumulated(uint256 amount, bool _isLong);
    event RequestCanceled(bytes32 indexed key, address indexed caller);
    event RequestCreated(bytes32 indexed key, address indexed owner, address tokenIn, uint256 amountIn, bool isDeposit);

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
    ) external payable returns (bytes32 requestKey);

    function cancelRequest(MarketId _id, bytes32 _requestKey, address _caller)
        external
        returns (address tokenOut, uint256 amountOut, bool shouldUnwrap);
    function executeDeposit(MarketId _id, IVault.ExecuteDeposit calldata _params) external returns (uint256);
    function executeWithdrawal(MarketId _id, IVault.ExecuteWithdrawal calldata _params) external;

    // Getter
    function getRequest(MarketId _id, bytes32 _key) external view returns (Pool.Input memory);
    function getRequestAtIndex(MarketId _id, uint256 _index) external view returns (Pool.Input memory);

    /**
     * ================ Functions ================
     */
    function initialize(address _tradeStorage, address _priceFeed, address _marketFactory) external;

    function initializePool(
        MarketId _id,
        Pool.Config memory _config,
        address _poolOwner,
        uint256 _borrowScale,
        address _marketToken,
        string memory _ticker
    ) external;
    function updateMarketState(
        MarketId _id,
        string calldata _ticker,
        uint256 _sizeDelta,
        Execution.Prices memory _prices,
        bool _isLong,
        bool _isIncrease
    ) external;
    function updateImpactPool(MarketId _id, int256 _priceImpactUsd) external;

    function tradeStorage() external view returns (ITradeStorage);
    function priceImpactScalar() external view returns (uint64);
    function getVault(MarketId _id) external view returns (IVault);
    function getBorrowScale(MarketId _id) external view returns (uint256);
    function getStorage(MarketId _id) external view returns (Pool.Storage memory);
    function getTicker(MarketId _id) external view returns (string memory);
    function FUNDING_VELOCITY_CLAMP() external view returns (uint64);
    function getConfig(MarketId _id) external view returns (Pool.Config memory);
    function getCumulatives(MarketId _id) external view returns (Pool.Cumulatives memory);
    function getImpactPool(MarketId _id) external view returns (uint256);
    function getLastUpdate(MarketId _id) external view returns (uint48);
    function getFundingRates(MarketId _id) external view returns (int64, int64);
    function getCumulativeBorrowFees(MarketId _id)
        external
        view
        returns (uint256 longCumulativeBorrowFees, uint256 shortCumulativeBorrowFees);
    function getCumulativeBorrowFee(MarketId _id, bool _isLong) external view returns (uint256);
    function getFundingAccrued(MarketId _id) external view returns (int256);
    function getBorrowingRate(MarketId _id, bool _isLong) external view returns (uint256);
    function getMaxLeverage(MarketId _id) external view returns (uint16);
    function getOpenInterest(MarketId _id, bool _isLong) external view returns (uint256);
    function getAverageCumulativeBorrowFee(MarketId _id, bool _isLong) external view returns (uint256);
}
