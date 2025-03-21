// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket} from "src/markets/Market.sol";
import {Pool} from "src/markets/Pool.sol";
import {IVault} from "src/markets/Vault.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {IPriceFeed} from "src/oracle/interfaces/IPriceFeed.sol";
import {TradeStorage, ITradeStorage} from "src/positions/TradeStorage.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {WETH} from "src/tokens/WETH.sol";
import {Oracle} from "src/oracle/Oracle.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {Position} from "src/positions/Position.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";
import {RewardTracker} from "src/rewards/RewardTracker.sol";
import {FeeDistributor} from "src/rewards/FeeDistributor.sol";
import {MockPriceFeed} from "../../mocks/MockPriceFeed.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {Referral} from "src/referrals/Referral.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {PriceImpact} from "src/libraries/PriceImpact.sol";
import {Execution} from "src/positions/Execution.sol";
import {Units} from "src/libraries/Units.sol";
import {MarketId} from "src/types/MarketId.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";

contract TestPriceImpact is Test {
    using MathUtils for uint256;
    using Units for uint256;

    MarketFactory marketFactory;
    MockPriceFeed priceFeed; // Deployed in Helper Config
    ITradeStorage tradeStorage;
    ReferralStorage referralStorage;
    PositionManager positionManager;
    TradeEngine tradeEngine;
    Router router;
    address OWNER;
    IMarket market;
    IVault vault;
    FeeDistributor feeDistributor;
    RewardTracker rewardTracker;

    address weth;
    address usdc;
    address link;

    MarketId marketId;

    string ethTicker = "ETH:1";
    string usdcTicker = "USDC:1";
    string[] tickers;

    address USER = makeAddr("USER");
    address USER1 = makeAddr("USER1");
    address USER2 = makeAddr("USER2");

    uint8[] precisions;
    uint16[] variances;
    uint48[] timestamps;
    uint64[] meds;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();

        marketFactory = contracts.marketFactory;
        priceFeed = MockPriceFeed(payable(address(contracts.priceFeed)));
        referralStorage = contracts.referralStorage;
        positionManager = contracts.positionManager;
        router = contracts.router;
        market = contracts.market;
        tradeStorage = contracts.tradeStorage;
        tradeEngine = contracts.tradeEngine;
        feeDistributor = contracts.feeDistributor;

        OWNER = contracts.owner;
        (weth, usdc,,,) = deploy.helperContracts();
        tickers.push(ethTicker);
        tickers.push(usdcTicker);
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
    }

    receive() external payable {}

    modifier setUpMarkets() {
        vm.deal(OWNER, 2_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.deal(USER, 2_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
        vm.deal(USER1, 2_000_000 ether);
        MockUSDC(usdc).mint(USER1, 1_000_000_000e6);
        vm.deal(USER2, 2_000_000 ether);
        MockUSDC(usdc).mint(USER2, 1_000_000_000e6);
        vm.prank(USER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER1);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER2);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        IMarketFactory.Input memory input = IMarketFactory.Input({
            indexTokenTicker: "ETH:1",
            marketTokenName: "LPT",
            marketTokenSymbol: "LPT",
            strategy: IPriceFeed.SecondaryStrategy({exists: false, feedId: bytes32(0)})
        });
        marketFactory.createNewMarket{value: 0.01 ether}(input);
        // Set Prices
        precisions.push(0);
        precisions.push(0);
        variances.push(0);
        variances.push(0);
        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));
        meds.push(3000);
        meds.push(1);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketId = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);

        vm.stopPrank();
        vault = market.getVault(marketId);
        tradeStorage = ITradeStorage(market.tradeStorage());
        // Call the deposit function with sufficient gas
        vm.prank(OWNER);
        router.createDeposit{value: 20_000.01 ether + 1 gwei}(marketId, OWNER, weth, 20_000 ether, 0.01 ether, 0, true);
        vm.prank(OWNER);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);

        vm.startPrank(OWNER);
        MockUSDC(usdc).approve(address(router), type(uint256).max);
        router.createDeposit{value: 0.01 ether + 1 gwei}(marketId, OWNER, usdc, 50_000_000e6, 0.01 ether, 0, false);
        positionManager.executeDeposit{value: 0.01 ether}(marketId, market.getRequestAtIndex(marketId, 0).key);
        vm.stopPrank();
        _;
    }

    modifier setUpNoLiquidity() {
        vm.deal(OWNER, 2_000_000 ether);
        MockUSDC(usdc).mint(OWNER, 1_000_000_000e6);
        vm.deal(USER, 2_000_000 ether);
        MockUSDC(usdc).mint(USER, 1_000_000_000e6);
        vm.deal(USER1, 2_000_000 ether);
        MockUSDC(usdc).mint(USER1, 1_000_000_000e6);
        vm.deal(USER2, 2_000_000 ether);
        MockUSDC(usdc).mint(USER2, 1_000_000_000e6);
        vm.prank(USER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER1);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.prank(USER2);
        WETH(weth).deposit{value: 1_000_000 ether}();
        vm.startPrank(OWNER);
        WETH(weth).deposit{value: 1_000_000 ether}();
        IMarketFactory.Input memory input = IMarketFactory.Input({
            indexTokenTicker: "ETH:1",
            marketTokenName: "LPT",
            marketTokenSymbol: "LPT",
            strategy: IPriceFeed.SecondaryStrategy({exists: false, feedId: bytes32(0)})
        });
        marketFactory.createNewMarket{value: 0.01 ether}(input);
        // Set Prices
        precisions.push(0);
        precisions.push(0);
        variances.push(0);
        variances.push(0);
        timestamps.push(uint48(block.timestamp));
        timestamps.push(uint48(block.timestamp));
        meds.push(3000);
        meds.push(1);
        bytes memory encodedPrices = priceFeed.encodePrices(tickers, precisions, variances, timestamps, meds);
        priceFeed.updatePrices(encodedPrices);
        marketId = marketFactory.executeMarketRequest(marketFactory.getRequestKeys()[0]);

        vm.stopPrank();
        vault = market.getVault(marketId);
        tradeStorage = ITradeStorage(market.tradeStorage());
        _;
    }

    /**
     * Input Requirements:
     * - Position.Request --> ticker, sizeDelta, isLong, isIncrease
     *
     * Mocked Variable Requirements:
     * - Long and Short oi
     * - Long and Short -> totalAvailableLiquidity
     */
    struct PriceImpactTest {
        uint256 indexPrice;
        uint256 sizeDelta;
        uint256 longOi;
        uint256 shortOi;
        uint256 longAvailable;
        uint256 shortAvailable;
        bool isLong;
        bool isIncrease;
    }

    function test_price_impact_estimation(PriceImpactTest memory _test) public setUpNoLiquidity {
        // Bound Inputs
        _test.longAvailable = bound(_test.longAvailable, 1 ether, 100_000 ether);
        _test.shortAvailable = bound(_test.shortAvailable, 3000e6, 300_000_000e6);
        _test.indexPrice = bound(_test.indexPrice, 100e30, 1_000_000e30); // $1 - $1M

        uint256 maxLongAvailableUsd = _test.longAvailable.toUsd(_test.indexPrice, 1e18) * 8 / 10;
        uint256 maxShortAvailableUsd = _test.shortAvailable.toUsd(1e30, 1e6) * 8 / 10;

        // Constrain longOi and shortOi based on available liquidity
        _test.longOi = bound(_test.longOi, 0, maxLongAvailableUsd);
        _test.shortOi = bound(_test.shortOi, 0, maxShortAvailableUsd);

        uint256 availableLiquidityUsd;
        if (_test.isLong) {
            availableLiquidityUsd = maxLongAvailableUsd - _test.longOi;
        } else {
            availableLiquidityUsd = maxShortAvailableUsd - _test.shortOi;
        }

        // Ensure sizeDelta is within the available liquidity for the respective side
        if (_test.isIncrease) {
            _test.sizeDelta = bound(_test.sizeDelta, 0, availableLiquidityUsd);
        } else {
            uint256 existingOiUsd;
            if (_test.isLong) {
                existingOiUsd = _test.longOi;
            } else {
                existingOiUsd = _test.shortOi;
            }
            _test.sizeDelta = bound(_test.sizeDelta, 0, existingOiUsd);
        }

        vm.assume(_test.sizeDelta > 0);

        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, true),
            abi.encode(_test.longOi)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, false),
            abi.encode(_test.shortOi)
        );
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, true),
            abi.encode(_test.longAvailable)
        );
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, false),
            abi.encode(_test.shortAvailable)
        );

        (int256 priceImpactUsd, uint256 impactedPrice) = PriceImpact.estimate(
            marketId,
            address(market),
            address(vault),
            _test.isIncrease ? int256(_test.sizeDelta) : -1 * int256(_test.sizeDelta),
            _test.indexPrice,
            _test.indexPrice,
            _test.isLong
        );

        // Structure Execution.Prices struct
        Execution.Prices memory impactPrices = _getPrices(_test.indexPrice, _test.isLong);

        // Structure Position.Request struct
        Position.Request memory request = _createRequest(_test.sizeDelta, _test.isLong, _test.isIncrease);

        // Call the function
        (uint256 impactedPriceAfter, int256 priceImpactUsdAfter) =
            PriceImpact.execute(marketId, market, vault, request, impactPrices);

        assertEq(impactedPriceAfter, impactedPrice, "Impacted prices differ");
        assertEq(priceImpactUsdAfter, priceImpactUsd, "Price impact USD differs");
    }

    function test_positions_that_worsen_skew_are_negatively_impacted(
        uint256 _sizeDelta,
        uint256 _currentOiLong,
        uint256 _currentOiShort,
        bool _isLong
    ) public setUpMarkets {
        if (_isLong) {
            // Size delta worsens skew -> higher on same side
            _currentOiLong = bound(_currentOiLong, 51_000e30, 100_000e30);
            _currentOiShort = bound(_currentOiShort, 1e30, 50_000e30);
            _sizeDelta = bound(_sizeDelta, 1e30, 1_000_000e30);
        } else {
            // Size delta worsens skew -> higher on same side
            _currentOiLong = bound(_currentOiLong, 1e30, 50_000e30);
            _currentOiShort = bound(_currentOiShort, 51_000e30, 100_000e30);
            _sizeDelta = bound(_sizeDelta, 1e30, 1_000_000e30);
        }

        bool isIncrease = true;

        // Mock available liquidity
        uint256 longAvailable = 100_000 ether;
        uint256 shortAvailable = 250_000_000e6;

        // Mock calls for open interests
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, true),
            abi.encode(_currentOiLong)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, false),
            abi.encode(_currentOiShort)
        );

        // Mock available liquidity
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, true),
            abi.encode(longAvailable)
        );
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, false),
            abi.encode(shortAvailable)
        );

        // Create Position.Request to worsen skew by adding to the more dominant side
        Position.Request memory request = _createRequest(_sizeDelta, _isLong, isIncrease);

        // Create Execution.Prices struct
        uint256 indexPrice = 2000e30; // Example index price
        Execution.Prices memory impactPrices = _getPrices(indexPrice, _isLong);

        // Act: Execute the price impact
        (uint256 impactedPrice, int256 priceImpactUsd) =
            PriceImpact.execute(marketId, market, vault, request, impactPrices);

        // Assert: Price impact is unfavorable
        if (_isLong) {
            // Adding longs when long OI is higher worsens skew
            assertLt(priceImpactUsd, 0, "Price impact should be negative when long skew worsens");
            assertGe(impactedPrice, indexPrice, "Impacted price should be higher for long positions");
        } else {
            // Adding shorts when short OI is higher worsens skew
            assertLt(priceImpactUsd, 0, "Price impact should be negative when short skew worsens");
            assertLe(impactedPrice, indexPrice, "Impacted price should be lower short positions");
        }
    }

    function test_positions_that_improve_skew_are_positively_impacted(
        uint256 _sizeDelta,
        uint256 _currentOiLong,
        uint256 _currentOiShort,
        bool _isLong
    ) public setUpMarkets {
        if (_isLong) {
            _currentOiLong = bound(_currentOiLong, 0, 50_000_000e30);
            _currentOiShort = bound(_currentOiShort, 51_000_000e30, 100_000_000e30);
            _sizeDelta = bound(_sizeDelta, 1e30, 1_000_000e30);
        } else {
            _currentOiLong = bound(_currentOiLong, 51_000_000e30, 100_000_000e30);
            _currentOiShort = bound(_currentOiShort, 0, 50_000_000e30);
            _sizeDelta = bound(_sizeDelta, 1e30, 1_000_000e30);
        }

        bool isIncrease = true;

        // Mock available liquidity
        uint256 longAvailable = 100_000 ether;
        uint256 shortAvailable = 250_000_000e6;

        // Mock calls for open interests
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, true),
            abi.encode(_currentOiLong)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, false),
            abi.encode(_currentOiShort)
        );

        // Mock available liquidity
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, true),
            abi.encode(longAvailable)
        );
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, false),
            abi.encode(shortAvailable)
        );

        // Mock impact pool
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getImpactPool.selector, marketId), abi.encode(100_000_000e30)
        );

        // Create Position.Request to improve skew by adding to the less dominant side
        Position.Request memory request = _createRequest(_sizeDelta, _isLong, isIncrease);

        // Create Execution.Prices struct
        uint256 indexPrice = 2000e30; // Example index price
        Execution.Prices memory impactPrices = _getPrices(indexPrice, _isLong);

        // Act: Execute the price impact
        (uint256 impactedPrice, int256 priceImpactUsd) =
            PriceImpact.execute(marketId, market, vault, request, impactPrices);

        // Assert: Price impact is favorable
        if (_isLong) {
            // Adding shorts when short OI is lower improves skew
            assertGt(priceImpactUsd, 0, "Price impact should be positive when short skew improves");
            assertLt(impactedPrice, indexPrice, "Impacted price should be more favourable for long positions");
        } else {
            // Adding longs when long OI is lower improves skew
            assertGt(priceImpactUsd, 0, "Price impact should be positive when long skew improves");
            assertGt(impactedPrice, indexPrice, "Impacted price should be more favourable for short positions");
        }
    }

    function test_positions_that_flip_skew_have_nonzero_impact(
        uint256 _sizeDelta,
        uint256 _currentOiLong,
        uint256 _currentOiShort,
        bool _isLong
    ) public setUpMarkets {
        if (_isLong) {
            // Long position that flips skew from short-biased to long-biased
            _currentOiLong = bound(_currentOiLong, 1_000_000e30, 49_999_999e30);
            _currentOiShort = bound(_currentOiShort, _currentOiLong + 1, 100_000_000e30);
            vm.assume(_currentOiShort - _currentOiLong + 1 < 1_000_000e30);
            _sizeDelta = bound(_sizeDelta, _currentOiShort - _currentOiLong + 1000e30, 1_000_000e30);
        } else {
            // Short position that flips skew from long-biased to short-biased
            _currentOiShort = bound(_currentOiShort, 1_000_000e30, 49_999_999e30);
            _currentOiLong = bound(_currentOiLong, _currentOiShort + 1, 100_000_000e30);
            vm.assume(_currentOiLong - _currentOiShort + 1 < 1_000_000e30);
            _sizeDelta = bound(_sizeDelta, _currentOiLong - _currentOiShort + 1_000e30, 1_000_000e30);
        }

        bool isIncrease = true;

        // Mock available liquidity
        uint256 longAvailable = 100_000 ether;
        uint256 shortAvailable = 250_000_000e6;

        // Mock calls for open interests
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, true),
            abi.encode(_currentOiLong)
        );
        vm.mockCall(
            address(market),
            abi.encodeWithSelector(market.getOpenInterest.selector, marketId, false),
            abi.encode(_currentOiShort)
        );

        // Mock available liquidity
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, true),
            abi.encode(longAvailable)
        );
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(vault.totalAvailableLiquidity.selector, false),
            abi.encode(shortAvailable)
        );

        // Mock impact pool
        vm.mockCall(
            address(market), abi.encodeWithSelector(market.getImpactPool.selector, marketId), abi.encode(100_000_000e30)
        );

        // Create Position.Request to flip the skew
        Position.Request memory request = _createRequest(_sizeDelta, _isLong, isIncrease);

        // Create Execution.Prices struct
        uint256 indexPrice = 2000e30; // Example index price
        Execution.Prices memory impactPrices = _getPrices(indexPrice, _isLong);

        // Act: Execute the price impact
        (uint256 impactedPrice, int256 priceImpactUsd) =
            PriceImpact.execute(marketId, market, vault, request, impactPrices);

        // Assert: Price impact is non-zero
        assertNotEq(priceImpactUsd, 0, "Price impact should be non-zero when flipping skew");

        assertNotEq(impactedPrice, indexPrice, "Impacted price should not be equal to the index price");
    }

    function _getPrices(uint256 _indexPrice, bool _isLong)
        private
        pure
        returns (Execution.Prices memory impactPrices)
    {
        impactPrices = Execution.Prices({
            indexPrice: _indexPrice,
            indexBaseUnit: 1e18,
            impactedPrice: _indexPrice,
            longMarketTokenPrice: _indexPrice,
            shortMarketTokenPrice: 1e30,
            priceImpactUsd: 0,
            collateralPrice: _isLong ? _indexPrice : 1e30,
            collateralBaseUnit: _isLong ? 1e18 : 1e6
        });
    }

    function _createRequest(uint256 _sizeDelta, bool _isLong, bool _isIncrease)
        private
        view
        returns (Position.Request memory request)
    {
        request = Position.Request({
            input: Position.Input({
                ticker: ethTicker,
                collateralToken: weth,
                collateralDelta: 0,
                sizeDelta: _sizeDelta,
                limitPrice: 0,
                maxSlippage: 1e30,
                executionFee: 0,
                isLong: _isLong,
                isLimit: false,
                isIncrease: _isIncrease,
                reverseWrap: false,
                triggerAbove: false
            }),
            user: USER,
            requestTimestamp: uint48(block.timestamp),
            requestType: Position.RequestType.CREATE_POSITION,
            requestKey: 0,
            stopLossKey: 0,
            takeProfitKey: 0
        });
    }
}
