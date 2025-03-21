// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IMarket} from "../markets/interfaces/IMarket.sol";
import {ITradeStorage} from "./interfaces/ITradeStorage.sol";
import {IVault} from "../markets/interfaces/IVault.sol";
import {Borrowing} from "../libraries/Borrowing.sol";
import {Funding} from "../libraries/Funding.sol";
import {Execution} from "../positions/Execution.sol";
import {Casting} from "../libraries/Casting.sol";
import {Units} from "../libraries/Units.sol";
import {MarketUtils} from "../markets/MarketUtils.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {MarketId} from "../types/MarketId.sol";

/// @dev Library containing all the data types used throughout the protocol
library Position {
    using Casting for uint256;
    using Casting for int256;
    using Units for uint256;
    using Units for int256;
    using MathUtils for uint256;
    using MathUtils for int256;

    error Position_CollateralExceedsSize();
    error Position_BelowMinLeverage();
    error Position_OverMaxLeverage();
    error Position_InvalidSlippage();
    error Position_InvalidTradingFee();
    error Position_InvalidAdlFee();
    error Position_InvalidFeeForExecution();

    uint8 private constant MIN_LEVERAGE = 1; // 1x
    uint16 private constant MAX_LEVERAGE = 1000; // 1000x
    uint64 private constant PRECISION = 1e18;
    uint64 private constant TARGET_PNL_RATIO = 0.35e18;
    uint128 private constant MIN_SLIPPAGE = 0.0001e30; // 0.01%
    uint128 private constant MAX_SLIPPAGE = 0.9999e30; // 99.99%
    uint256 private constant MAX_ADL_PERCENTAGE = 0.66e18; // 66%
    uint64 private constant MAX_TRADING_FEE = 0.01e18; // 1%
    uint64 private constant MIN_TRADING_FEE = 0.00001e18; // 0.001%
    uint64 private constant MAX_ADL_FEE = 0.05e18; // 5%
    uint64 private constant MIN_ADL_FEE = 0.0001e18; // 0.01%
    uint64 private constant MAX_FEE_FOR_EXECUTION = 0.3e18; // 30%
    uint64 private constant MIN_FEE_FOR_EXECUTION = 0.05e18; // 5%

    struct Data {
        string ticker;
        address user;
        address collateralToken; // WETH long, USDC short
        bool isLong;
        uint48 lastUpdate;
        uint256 collateral; // USD
        uint256 size; // USD
        uint256 weightedAvgEntryPrice;
        FundingParams fundingParams;
        BorrowingParams borrowingParams;
        /**
         * While SL / TPs are separate entities (decrease orders), tieing them to a position lets
         * us close them simultaneously with the position, to prevent the issue
         * of orders being left open after a position is closed.
         */
        bytes32 stopLossKey;
        bytes32 takeProfitKey;
    }

    struct FundingParams {
        int256 lastFundingAccrued;
        int256 fundingOwed;
    }

    struct BorrowingParams {
        uint256 feesOwed;
        uint256 lastLongCumulativeBorrowFee;
        uint256 lastShortCumulativeBorrowFee;
    }

    struct Conditionals {
        bool stopLossSet;
        bool takeProfitSet;
        uint64 stopLossPercentage;
        uint64 takeProfitPercentage;
        uint256 stopLossPrice;
        uint256 takeProfitPrice;
    }

    struct Input {
        string ticker; // Asset ticker, e.g ETH:1
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDelta; // USD
        uint256 limitPrice;
        uint128 maxSlippage; // 30 D.P Ratio
        uint64 executionFee;
        bool isLong;
        bool isLimit;
        bool isIncrease;
        bool reverseWrap;
        bool triggerAbove; // For Limits -> Execute above the limit price, or below it
    }

    struct Request {
        Input input;
        address user;
        uint48 requestTimestamp;
        RequestType requestType;
        bytes32 requestKey; // Key of the price update request
        bytes32 stopLossKey;
        bytes32 takeProfitKey;
    }

    struct Settlement {
        Request request;
        bytes32 orderKey;
        bytes32 limitRequestKey;
        address feeReceiver;
        bool isAdl;
    }

    enum RequestType {
        POSITION_INCREASE,
        POSITION_DECREASE,
        CREATE_POSITION,
        STOP_LOSS,
        TAKE_PROFIT
    }

    /**
     * =========================================== Validation Functions ============================================
     */
    function checkSlippage(uint256 _slippage) internal pure {
        if (!(_slippage >= MIN_SLIPPAGE && _slippage <= MAX_SLIPPAGE)) {
            revert Position_InvalidSlippage();
        }
    }

    function validateFees(uint256 _positionFee, uint256 _adlFee, uint256 _feeForExecution) internal pure {
        if (_positionFee > MAX_TRADING_FEE || _positionFee < MIN_TRADING_FEE) {
            revert Position_InvalidTradingFee();
        }

        if (_adlFee > MAX_ADL_FEE || _adlFee < MIN_ADL_FEE) {
            revert Position_InvalidAdlFee();
        }

        if (_feeForExecution > MAX_FEE_FOR_EXECUTION || _feeForExecution < MIN_FEE_FOR_EXECUTION) {
            revert Position_InvalidFeeForExecution();
        }
    }

    function checkLeverage(MarketId _id, IMarket market, uint256 _sizeUsd, uint256 _collateralUsd) internal view {
        uint16 maxLeverage = market.getMaxLeverage(_id);

        if (_collateralUsd > _sizeUsd) revert Position_CollateralExceedsSize();
        uint256 leverage = _sizeUsd / _collateralUsd;
        if (leverage < MIN_LEVERAGE) revert Position_BelowMinLeverage();
        if (leverage > maxLeverage) revert Position_OverMaxLeverage();
    }

    function getRequestType(Input memory _trade, Data memory _position)
        internal
        pure
        returns (RequestType requestType)
    {
        if (_position.user == address(0)) {
            requestType = RequestType.CREATE_POSITION;
        } else if (_trade.isIncrease) {
            requestType = RequestType.POSITION_INCREASE;
        } else {
            if (_trade.isLimit) {
                if (_trade.triggerAbove) {
                    if (_trade.isLong) {
                        requestType = RequestType.TAKE_PROFIT;
                    } else {
                        requestType = RequestType.STOP_LOSS;
                    }
                } else {
                    if (_trade.isLong) requestType = RequestType.STOP_LOSS;
                    else requestType = RequestType.TAKE_PROFIT;
                }
            } else {
                requestType = RequestType.POSITION_DECREASE;
            }
        }
    }

    /**
     * =========================================== Constructor Functions ============================================
     */
    function generateKey(Request memory _request) internal pure returns (bytes32 positionKey) {
        positionKey = keccak256(abi.encode(_request.input.ticker, _request.user, _request.input.isLong));
    }

    function generateKey(string memory _ticker, address _user, bool _isLong)
        internal
        pure
        returns (bytes32 positionKey)
    {
        positionKey = keccak256(abi.encode(_ticker, _user, _isLong));
    }

    function generateOrderKey(Request memory _request) internal pure returns (bytes32 orderKey) {
        orderKey = keccak256(
            abi.encode(
                _request.input.ticker,
                _request.user,
                _request.input.isLong,
                _request.input.isIncrease,
                _request.input.limitPrice,
                _request.requestType,
                _request.requestTimestamp
            )
        );
    }

    function createRequest(Input memory _trade, address _user, RequestType _requestType, bytes32 _requestKey)
        internal
        view
        returns (Request memory request)
    {
        request = Request({
            input: _trade,
            user: _user,
            requestTimestamp: uint48(block.timestamp),
            requestType: _requestType,
            requestKey: _requestKey,
            stopLossKey: bytes32(0),
            takeProfitKey: bytes32(0)
        });
    }

    function generateNewPosition(
        MarketId _id,
        IMarket market,
        Request memory _request,
        uint256 _impactedPrice,
        uint256 _collateralUsd
    ) internal view returns (Data memory position) {
        (uint256 longBorrowFee, uint256 shortBorrowFee) = market.getCumulativeBorrowFees(_id);

        position = Data({
            ticker: _request.input.ticker,
            collateralToken: _request.input.collateralToken,
            user: _request.user,
            collateral: _collateralUsd,
            size: _request.input.sizeDelta,
            weightedAvgEntryPrice: _impactedPrice,
            lastUpdate: uint48(block.timestamp),
            isLong: _request.input.isLong,
            fundingParams: FundingParams(market.getFundingAccrued(_id), 0),
            borrowingParams: BorrowingParams(0, longBorrowFee, shortBorrowFee),
            stopLossKey: _request.stopLossKey,
            takeProfitKey: _request.takeProfitKey
        });
    }

    function createLiquidationOrder(
        Data memory _position,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit,
        address _liquidator
    ) external view returns (Settlement memory) {
        return Settlement({
            request: Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    collateralDelta: _position.collateral.fromUsd(_collateralPrice, _collateralBaseUnit),
                    sizeDelta: _position.size,
                    limitPrice: 0,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0,
                    isLong: _position.isLong,
                    isLimit: false,
                    isIncrease: false,
                    reverseWrap: false,
                    triggerAbove: false
                }),
                user: _position.user,
                requestTimestamp: uint48(block.timestamp),
                requestType: RequestType.POSITION_DECREASE,
                requestKey: bytes32(0),
                stopLossKey: bytes32(0),
                takeProfitKey: bytes32(0)
            }),
            orderKey: bytes32(0),
            limitRequestKey: bytes32(0),
            feeReceiver: _liquidator,
            isAdl: false
        });
    }

    function createAdlOrder(Data memory _position, uint256 _sizeDelta, uint256 _collateralDelta, address _feeReceiver)
        internal
        view
        returns (Settlement memory)
    {
        return Settlement({
            request: Request({
                input: Input({
                    ticker: _position.ticker,
                    collateralToken: _position.collateralToken,
                    collateralDelta: _collateralDelta,
                    sizeDelta: _sizeDelta,
                    limitPrice: 0,
                    maxSlippage: MAX_SLIPPAGE,
                    executionFee: 0,
                    isLong: _position.isLong,
                    isLimit: false,
                    isIncrease: false,
                    reverseWrap: false,
                    triggerAbove: false
                }),
                user: _position.user,
                requestTimestamp: uint48(block.timestamp),
                requestType: RequestType.POSITION_DECREASE,
                requestKey: bytes32(0),
                stopLossKey: bytes32(0),
                takeProfitKey: bytes32(0)
            }),
            orderKey: bytes32(0),
            limitRequestKey: bytes32(0),
            feeReceiver: _feeReceiver,
            isAdl: true
        });
    }

    /**
     * =========================================== Getter Functions ============================================
     */
    function calculateFee(
        uint256 _tradingFee,
        uint256 _feeForExecution,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        uint256 _collateralPrice,
        uint256 _collateralBaseUnit
    ) internal pure returns (uint256 positionFee, uint256 feeForExecutor) {
        if (_sizeDelta != 0) {
            uint256 sizeInCollateral = _sizeDelta.fromUsd(_collateralPrice, _collateralBaseUnit);

            positionFee = sizeInCollateral.percentage(_tradingFee);
            feeForExecutor = positionFee.percentage(_feeForExecution);
            positionFee -= feeForExecutor;
        } else {
            positionFee = _collateralDelta.percentage(_tradingFee);
            feeForExecutor = positionFee.percentage(_feeForExecution);
            positionFee -= feeForExecutor;
        }
    }

    /// @dev Calculates the funding fee proportional to the size delta in USD
    function getFundingFeeDelta(MarketId _id, IMarket market, uint256 _sizeDelta, int256 _entryFundingAccrued)
        internal
        view
        returns (int256 fundingFeeUsd, int256 nextFundingAccrued)
    {
        (, nextFundingAccrued) = Funding.calculateNextFunding(_id, address(market));

        fundingFeeUsd = _sizeDelta.toInt256().percentageInt(nextFundingAccrued - _entryFundingAccrued);
    }

    /// @dev Calculates the total funding owed by a position in USD
    function getTotalFundingFees(MarketId _id, IMarket market, Data memory _position) internal view returns (int256) {
        (, int256 nextFundingAccrued) = Funding.calculateNextFunding(_id, address(market));

        return _position.size.toInt256().percentageInt(nextFundingAccrued - _position.fundingParams.lastFundingAccrued);
    }

    function getTotalBorrowFees(MarketId _id, IMarket market, Data memory _position, Execution.Prices memory _prices)
        internal
        view
        returns (uint256)
    {
        uint256 feesUsd = getTotalBorrowFeesUsd(_id, market, _position);

        return feesUsd.fromUsd(_prices.collateralPrice, _prices.collateralBaseUnit);
    }

    function getTotalBorrowFeesUsd(MarketId _id, IMarket market, Data memory _position) public view returns (uint256) {
        uint256 borrowFee = _position.isLong
            ? market.getCumulativeBorrowFee(_id, true) - _position.borrowingParams.lastLongCumulativeBorrowFee
            : market.getCumulativeBorrowFee(_id, false) - _position.borrowingParams.lastShortCumulativeBorrowFee;

        borrowFee += Borrowing.calculatePendingFees(_id, address(market), _position.isLong);

        uint256 feeSinceUpdate = borrowFee == 0 ? 0 : _position.size.percentage(borrowFee);

        return feeSinceUpdate + _position.borrowingParams.feesOwed;
    }

    function getTotalFeesOwed(MarketId marketId, IMarket market, Data memory _position, Execution.Prices memory _prices)
        external
        view
        returns (uint256)
    {
        int256 fundingFees = getTotalFundingFees(marketId, market, _position).fromUsdToSigned(
            _prices.collateralPrice, _prices.collateralBaseUnit
        );

        uint256 borrowFees = getTotalBorrowFees(marketId, market, _position, _prices);

        if (fundingFees > 0) {
            return fundingFees.abs() + borrowFees;
        } else {
            return borrowFees;
        }
    }

    function getTotalFeesOwedUsd(MarketId marketId, IMarket market, Data memory _position)
        external
        view
        returns (uint256)
    {
        int256 fundingFees = getTotalFundingFees(marketId, market, _position);

        uint256 borrowFees = getTotalBorrowFeesUsd(marketId, market, _position);

        return fundingFees > 0 ? fundingFees.abs() + borrowFees : borrowFees;
    }

    /// @dev PNL = (Current Price - Average Entry Price) * (Position Value / Average Entry Price)
    function getPositionPnl(
        uint256 _positionSizeUsd,
        uint256 _weightedAvgEntryPrice,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        bool _isLong
    ) public pure returns (int256) {
        int256 priceDelta = _indexPrice.diff(_weightedAvgEntryPrice);

        uint256 entryIndexAmount = _positionSizeUsd.fromUsd(_weightedAvgEntryPrice, _indexBaseUnit);

        if (_isLong) {
            return priceDelta.mulDivSigned(entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        } else {
            return -priceDelta.mulDivSigned(entryIndexAmount.toInt256(), _indexBaseUnit.toInt256());
        }
    }

    /// @dev Returns fractional PNL in Collateral tokens
    function getRealizedPnl(
        uint256 _positionSizeUsd,
        uint256 _sizeDeltaUsd,
        uint256 _weightedAvgEntryPrice,
        uint256 _impactedPrice,
        uint256 _indexBaseUnit,
        uint256 _collateralTokenPrice,
        uint256 _collateralBaseUnit,
        bool _isLong
    ) internal pure returns (int256) {
        int256 positionPnl =
            getPositionPnl(_positionSizeUsd, _weightedAvgEntryPrice, _impactedPrice, _indexBaseUnit, _isLong);

        int256 realizedPnlUsd = positionPnl.percentageSigned(_sizeDeltaUsd, _positionSizeUsd);

        return realizedPnlUsd.fromUsdToSigned(_collateralTokenPrice, _collateralBaseUnit);
    }

    /// @dev Only used for external queries.
    function getLiquidationPrice(Data memory _position) external pure returns (uint256) {
        if (_position.isLong) {
            // For long positions, liquidation price is when:
            // collateral + PNL = 0
            // Solving for liquidation price:
            // (liquidationPrice - entryPrice) * (positionSize / entryPrice) + _position.collateral = 0
            // liquidationPrice = entryPrice - (_position.collateral * entryPrice) / positionSize

            return _position.weightedAvgEntryPrice
                - _position.collateral.mulDiv(_position.weightedAvgEntryPrice, _position.size);
        } else {
            // For short positions, liquidation price is when:
            // collateral - PNL = 0
            // Solving for liquidation price:
            // (entryPrice - liquidationPrice) * (positionSize / entryPrice) - _position.collateral = 0
            // liquidationPrice = entryPrice + (_position.collateral * entryPrice) / positionSize

            return _position.weightedAvgEntryPrice
                + _position.collateral.mulDiv(_position.weightedAvgEntryPrice, _position.size);
        }
    }

    /**
     * @dev Calculates the Percentage to ADL a position by based on the PNL to Pool Ratio.
     * Percentage to ADL = 1 - e ** (-excessRatio**2) * (positionPnl/positionSize))
     * where excessRatio = (currentPnlToPoolRatio/targetPnlToPoolRatio) - 1
     *
     * The maximum pnl to pool ratio is configured to 0.45e18, or 45%. We introduce
     * a target pnl to pool ratio (35%), so that in the event of the max ratio being exceeded, the
     * overall ratio can still be reduced. If we configured the excess ratio
     * purely based on the max ratio, once pnl exceeds 45%, the percentage to adl would be 0.
     */
    function calculateAdlPercentage(uint256 _pnlToPoolRatio, int256 _positionProfit, uint256 _positionSize)
        public
        pure
        returns (uint256 adlPercentage)
    {
        // Excess ratio = ((pnlToPoolRatio / targetPnlRatio) - 1) ** 2
        uint256 excessRatio = (_pnlToPoolRatio.divWadUp(TARGET_PNL_RATIO) - PRECISION).rpow(2, PRECISION);

        // Exponent = -excessRatio * positionProfit / positionSize
        int256 exponent = (-excessRatio.toInt256()).mulDivSigned(_positionProfit, _positionSize.toInt256());

        // adlPercentage = 1 - e ** exponent
        adlPercentage = PRECISION - exponent.wadExp().toUint256();

        if (adlPercentage > MAX_ADL_PERCENTAGE) adlPercentage = MAX_ADL_PERCENTAGE;
    }

    /**
     * Loop through all open positions on the market, calculate the pnl for the position.
     * Then calculate the ADL Target score for each position, returning the position key
     * with the highest ADL Target Score, which is essentially the position that is next
     * in priority for ADL.
     *
     * The formula is adapted from Bybit's as:
     *
     * ADL Target Score = ( Position Size / Total Pool Size) * (Position PnL / Position Size)
     *
     * This function requires loops, so should *never* be used onchain. It is simply a queryable
     * function from frontends to determine the next most optimal position to be adl'd. Also,
     * optimistically assumes accurate pricing data.
     *
     * Users are incentivized to target these positions as they'll generate them the
     * most profit in the event of ADL.
     */
    function getNextAdlTarget(
        MarketId _id,
        ITradeStorage tradeStorage,
        string memory _ticker,
        uint256 _indexPrice,
        uint256 _indexBaseUnit,
        uint256 _totalPoolSizeUsd,
        bool _isLong
    ) external view returns (bytes32 positionKey) {
        bytes32[] memory positionKeys = tradeStorage.getOpenPositionKeys(_id, _isLong);

        uint256 len = positionKeys.length;

        uint256 highestAdlScore;

        for (uint256 i = 0; i < len;) {
            Position.Data memory position = tradeStorage.getPosition(_id, positionKeys[i]);

            if (keccak256(abi.encode(position.ticker)) != keccak256(abi.encode(_ticker))) continue;

            int256 pnl =
                getPositionPnl(position.size, position.weightedAvgEntryPrice, _indexPrice, _indexBaseUnit, _isLong);

            if (pnl < 0) continue;

            // Position Size terms cancel out
            uint256 adlTargetScore = pnl.abs() / _totalPoolSizeUsd;

            if (adlTargetScore > highestAdlScore) {
                highestAdlScore = adlTargetScore;
                positionKey = positionKeys[i];
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev - For Frontends -> Returns Fees in USD
    function getFeesForKey(MarketId _id, address _tradeStorage, address _market, bytes32 _positionKey)
        external
        view
        returns (int256, uint256)
    {
        Position.Data memory position = ITradeStorage(_tradeStorage).getPosition(_id, _positionKey);

        int256 fundingFees = getTotalFundingFees(_id, IMarket(_market), position);

        uint256 borrowFees = getTotalBorrowFeesUsd(_id, IMarket(_market), position);

        return (fundingFees, borrowFees);
    }
}
