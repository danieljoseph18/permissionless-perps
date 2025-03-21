// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceFeed} from "../../oracle/interfaces/IPriceFeed.sol";
import {Pool} from "../../markets/Pool.sol";
import {MarketId} from "../../types/MarketId.sol";

interface IMarketFactory {
    event MarketFactoryInitialized(address priceStorage);
    event MarketCreated(MarketId id, string ticker, address vault, address rewardTracker);
    event DefaultConfigSet();
    event MarketRequested(bytes32 indexed requestKey, string indexTokenTicker);
    event AssetRequested(string ticker);
    event MarketRequestCancelled(bytes32 indexed requestKey, address indexed requester);

    error MarketFactory_AlreadyInitialized();
    error MarketFactory_FailedToAddMarket();
    error MarketFactory_InvalidOwner();
    error MarketFactory_InvalidFee();
    error MarketFactory_RequestDoesNotExist();
    error MarketFactory_FailedToRemoveRequest();
    error MarketFactory_InvalidDecimals();
    error MarketFactory_InvalidTicker();
    error MarketFactory_SelfExecution();
    error MarketFactory_InvalidTimestamp();
    error MarketFactory_RequestNotCancellable();
    error MarketFactory_RequestExists();
    error MarketFactory_FailedToAddRequest();
    error MarketFactory_InvalidSecondaryStrategy();
    error MarketFactory_MarketExists();
    error MarketFactory_InvalidLeverage();
    error MarketFactory_InsufficientBalance();
    error MarketFactory_MarketAlreadyExists();

    struct Request {
        Input input;
        uint48 requestTimestamp;
        address requester;
    }

    struct Input {
        string indexTokenTicker;
        string marketTokenName;
        string marketTokenSymbol;
        IPriceFeed.SecondaryStrategy strategy;
    }

    struct PythData {
        bytes32 id;
        bytes32[] merkleProof;
    }

    struct CreatedMarket {
        MarketId id;
        string ticker;
        address vault;
        address rewardTracker;
    }

    function initialize(
        Pool.Config memory _defaultConfig,
        address _market,
        address _tradeStorage,
        address _tradeEngine,
        address _priceFeed,
        address _referralStorage,
        address _positionManager,
        address _feeDistributor,
        address _feeReceiver,
        uint256 _marketExecutionFee,
        uint256 _defaultTransferGasLimit
    ) external;
    function setDefaultConfig(Pool.Config memory _defaultConfig) external;
    function updatePriceFeed(IPriceFeed _priceFeed) external;
    function createNewMarket(Input calldata _input) external payable returns (bytes32);
    function executeMarketRequest(bytes32 _requestKey) external returns (MarketId);
    function getRequest(bytes32 _requestKey) external view returns (Request memory);
    function getMarketForTicker(string calldata _ticker) external view returns (MarketId);
    function markets(uint256 index) external view returns (MarketId);
    function isMarket(MarketId _market) external view returns (bool);
}
