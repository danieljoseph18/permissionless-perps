// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IMarket} from "../markets/interfaces/IMarket.sol";
import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";
import {IPyth} from "@pyth/contracts/IPyth.sol";
import {PythStructs} from "@pyth/contracts/PythStructs.sol";
import {IERC20} from "../tokens/interfaces/IERC20.sol";
import {IERC20Metadata} from "../tokens/interfaces/IERC20Metadata.sol";
import {MathUtils} from "../libraries/MathUtils.sol";
import {Casting} from "../libraries/Casting.sol";
import {Units} from "../libraries/Units.sol";
import {LibString} from "../libraries/LibString.sol";
import {ud, UD60x18, unwrap} from "@prb/math/UD60x18.sol";
import {MarketId, MarketIdLibrary} from "../types/MarketId.sol";

library Oracle {
    using MathUtils for uint256;
    using MathUtils for int256;
    using Units for uint256;
    using Casting for uint256;
    using Casting for int256;
    using Casting for int32;
    using Casting for int64;
    using LibString for uint256;
    using LibString for bytes32;

    error Oracle_SequencerDown();
    error Oracle_InvalidAmmDecimals();
    error Oracle_InvalidPoolType();
    error Oracle_InvalidReferenceQuery();
    error Oracle_InvalidPriceRetrieval();
    error Oracle_InvalidSecondaryStrategy();
    error Oracle_RequestExpired();
    error Oracle_FailedToGetDecimals();

    struct Prices {
        uint256 min;
        uint256 med;
        uint256 max;
    }

    enum PoolType {
        V3,
        V2
    }

    string private constant LONG_TICKER = "ETH:1";
    string private constant SHORT_TICKER = "USDC:1";
    uint8 private constant PRICE_DECIMALS = 30;
    uint8 private constant CHAINLINK_DECIMALS = 8;
    uint8 private constant MAX_STRATEGY = 1;
    uint16 private constant MAX_VARIANCE = 10_000;
    uint64 private constant MAX_PRICE_DEVIATION = 0.1e18;
    uint64 private constant OVERESTIMATION_FACTOR = 0.1e18;
    uint64 private constant PREMIUM_FEE = 0.1e18; // 10%

    /**
     * =========================================== Validation Functions ===========================================
     */

    // Try to fetch a price from the Pyth contract and ensure that it returns a non-zero value.
    // It's possible pyth feeds are valid, but have never had a price signed.
    // This case should be handled from front-ends.
    function isValidPythFeed(IPyth pyth, bytes32 _priceId) internal view {
        PythStructs.Price memory pythData = pyth.getPriceUnsafe(_priceId);
        if (pythData.price == 0) revert Oracle_InvalidSecondaryStrategy();
    }

    /**
     * =========================================== Helper Functions ===========================================
     */
    function estimateRequestCost(address _priceFeed) public view returns (uint256 cost) {
        IPriceFeed priceFeed = IPriceFeed(_priceFeed);

        uint256 gasPrice = tx.gasprice;

        uint256 overestimatedGasPrice = gasPrice + gasPrice.percentage(OVERESTIMATION_FACTOR);

        uint256 totalEstimatedGasCost = overestimatedGasPrice * (priceFeed.gasOverhead() + priceFeed.callbackGasLimit());

        uint256 premiumFee = totalEstimatedGasCost.percentage(PREMIUM_FEE);

        cost = totalEstimatedGasCost + premiumFee;
    }

    /// @dev - Prepend the timestamp to the arguments before sending to the DON
    function constructPriceArguments(string memory _ticker) internal view returns (string[] memory args) {
        if (bytes(_ticker).length == 0) {
            // Only prices for Long and Short Tokens
            args = new string[](3);
            args[0] = block.timestamp.toString();
            args[1] = LONG_TICKER;
            args[2] = SHORT_TICKER;
        } else {
            // Prices for index token, long token, and short token
            args = new string[](4);
            args[0] = block.timestamp.toString();
            args[1] = _ticker;
            args[2] = LONG_TICKER;
            args[3] = SHORT_TICKER;
        }
    }

    /**
     * =========================================== Price Retrieval ===========================================
     */
    function getPrice(IPriceFeed priceFeed, string memory _ticker, uint48 _blockTimestamp)
        external
        view
        returns (uint256 medPrice)
    {
        IPriceFeed.Price memory price = priceFeed.getPrices(_ticker, _blockTimestamp);

        medPrice = price.med * (10 ** (PRICE_DECIMALS - price.precision));
    }

    function getMaxPrice(IPriceFeed priceFeed, string memory _ticker, uint48 _blockTimestamp)
        public
        view
        returns (uint256 maxPrice)
    {
        IPriceFeed.Price memory price = priceFeed.getPrices(_ticker, _blockTimestamp);

        uint256 medPrice = price.med * (10 ** (PRICE_DECIMALS - price.precision));

        maxPrice = medPrice + medPrice.mulDiv(price.variance, MAX_VARIANCE);
    }

    function getMinPrice(IPriceFeed priceFeed, string memory _ticker, uint48 _blockTimestamp)
        public
        view
        returns (uint256 minPrice)
    {
        IPriceFeed.Price memory price = priceFeed.getPrices(_ticker, _blockTimestamp);

        uint256 medPrice = price.med * (10 ** (PRICE_DECIMALS - price.precision));

        minPrice = medPrice - medPrice.mulDiv(price.variance, MAX_VARIANCE);
    }

    function getLastPrice(IPriceFeed priceFeed, string memory _ticker) internal view returns (uint256 price) {
        IPriceFeed.Price memory priceData = priceFeed.getLastPrice(_ticker);
        price = priceData.med * (10 ** (PRICE_DECIMALS - priceData.precision));
    }

    function getVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        internal
        view
        returns (Prices memory longPrices, Prices memory shortPrices)
    {
        longPrices = getVaultPricesForSide(priceFeed, _blockTimestamp, true);
        shortPrices = getVaultPricesForSide(priceFeed, _blockTimestamp, false);
    }

    function getVaultPricesForSide(IPriceFeed priceFeed, uint48 _blockTimestamp, bool _isLong)
        internal
        view
        returns (Prices memory prices)
    {
        IPriceFeed.Price memory signedPrice = priceFeed.getPrices(_isLong ? LONG_TICKER : SHORT_TICKER, _blockTimestamp);

        prices.med = signedPrice.med * (10 ** (PRICE_DECIMALS - signedPrice.precision));

        prices.min = prices.med - prices.med.mulDiv(signedPrice.variance, MAX_VARIANCE);

        prices.max = prices.med + prices.med.mulDiv(signedPrice.variance, MAX_VARIANCE);
    }

    function getMaxVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        internal
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        longPrice = getMaxPrice(priceFeed, LONG_TICKER, _blockTimestamp);
        shortPrice = getMaxPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
    }

    function getMinVaultPrices(IPriceFeed priceFeed, uint48 _blockTimestamp)
        internal
        view
        returns (uint256 longPrice, uint256 shortPrice)
    {
        longPrice = getMinPrice(priceFeed, LONG_TICKER, _blockTimestamp);
        shortPrice = getMinPrice(priceFeed, SHORT_TICKER, _blockTimestamp);
    }

    /**
     * =========================================== Auxillary ===========================================
     */
    function getBaseUnit(IPriceFeed priceFeed, string memory _ticker) internal view returns (uint256 baseUnit) {
        uint8 decimals = priceFeed.tokenDecimals(_ticker);
        if (decimals == 0) revert Oracle_FailedToGetDecimals();
        baseUnit = 10 ** priceFeed.tokenDecimals(_ticker);
    }

    /// @dev - Wrapper around `getRequestTimestamp` with an additional validation step
    function getRequestTimestamp(IPriceFeed priceFeed, bytes32 _requestKey)
        internal
        view
        returns (uint48 requestTimestamp)
    {
        requestTimestamp = priceFeed.getRequestTimestamp(_requestKey);

        if (block.timestamp > requestTimestamp + priceFeed.timeToExpiration()) revert Oracle_RequestExpired();
    }

    function validatePrice(IPriceFeed priceFeed, IPriceFeed.Price memory _priceData) internal view returns (bool) {
        uint256 referencePrice = _getReferencePrice(priceFeed, string(abi.encodePacked(_priceData.ticker)));

        uint256 medPrice = _priceData.med * (10 ** (PRICE_DECIMALS - _priceData.precision));

        // If med price is 0, or variance is 100%, return false
        if (medPrice == 0 || _priceData.variance == MAX_VARIANCE) return false;

        // If no secondary price feed, return true by default
        if (referencePrice == 0) return true;

        return medPrice.absDiff(referencePrice) <= referencePrice.percentage(MAX_PRICE_DEVIATION);
    }

    function encodePrices(
        string[] calldata _tickers,
        uint8[] calldata _precisions,
        uint16[] calldata _variances,
        uint48[] calldata _timestamps,
        uint64[] calldata _meds
    ) external pure returns (bytes memory) {
        uint16 len = uint16(_tickers.length);

        bytes32[] memory encodedPrices = new bytes32[](len);

        for (uint16 i = 0; i < len;) {
            bytes32 encodedPrice = bytes32(
                abi.encodePacked(bytes15(bytes(_tickers[i])), _precisions[i], _variances[i], _timestamps[i], _meds[i])
            );

            encodedPrices[i] = encodedPrice;

            unchecked {
                ++i;
            }
        }

        return abi.encodePacked(encodedPrices);
    }

    /**
     * =========================================== Reference Prices ===========================================
     */

    /* ONLY EVER USED FOR REFERENCE PRICES.  */
    function _getReferencePrice(IPriceFeed priceFeed, string memory _ticker) internal view returns (uint256 price) {
        IPriceFeed.SecondaryStrategy memory strategy = priceFeed.getSecondaryStrategy(_ticker);
        if (!strategy.exists) return 0;
        price = _getPythPrice(priceFeed.pyth(), strategy);
        if (price == 0) revert Oracle_InvalidReferenceQuery();
    }

    // Need the Pyth address and the bytes32 id for the ticker
    function _getPythPrice(address _pythFeed, IPriceFeed.SecondaryStrategy memory _strategy)
        private
        view
        returns (uint256 price)
    {
        // Query the Pyth feed for the price
        IPyth pythFeed = IPyth(_pythFeed);
        PythStructs.Price memory pythData = pythFeed.getEmaPriceUnsafe(_strategy.feedId);
        // Expand the price to 30 d.p
        uint256 exponent = PRICE_DECIMALS - pythData.expo.abs();
        price = pythData.price.abs() * (10 ** exponent);
    }
}
