// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {IMarket} from "src/markets/Market.sol";
import {MarketFactory, IMarketFactory} from "src/factory/MarketFactory.sol";
import {PriceFeed, IPriceFeed} from "src/oracle/PriceFeed.sol";
import {TradeStorage, ITradeStorage} from "src/positions/TradeStorage.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {WETH} from "src/tokens/WETH.sol";
import {Oracle} from "src/oracle/Oracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {Position} from "src/positions/Position.sol";
import {MarketUtils} from "src/markets/MarketUtils.sol";
import {RewardTracker} from "src/rewards/RewardTracker.sol";
import {FeeDistributor} from "src/rewards/FeeDistributor.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {MarketId} from "src/types/MarketId.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {IVault} from "src/markets/Vault.sol";
import {LibString} from "src/libraries/LibString.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";
import {IPyth} from "@pyth/contracts/IPyth.sol";
import {PythStructs} from "@pyth/contracts/PythStructs.sol";
import {IERC20Metadata} from "src/tokens/interfaces/IERC20Metadata.sol";
import {Casting} from "src/libraries/Casting.sol";

contract TestOracle is Test {
    using LibString for bytes15;
    using Casting for int256;
    using Casting for int32;
    using Casting for int64;

    MarketFactory marketFactory;
    PriceFeed priceFeed;
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

    /**
     * ==================================== Contract Vars ====================================
     */
    uint8 private constant PRICE_DECIMALS = 30;
    uint8 private constant CHAINLINK_DECIMALS = 8;

    function setUp() public {
        Deploy deploy = new Deploy();
        Deploy.Contracts memory contracts = deploy.run();

        marketFactory = contracts.marketFactory;
        vm.label(address(marketFactory), "marketFactory");

        priceFeed = PriceFeed(payable(address(contracts.priceFeed)));
        vm.label(address(priceFeed), "priceFeed");

        referralStorage = contracts.referralStorage;
        vm.label(address(referralStorage), "referralStorage");

        positionManager = contracts.positionManager;
        vm.label(address(positionManager), "positionManager");

        router = contracts.router;
        vm.label(address(router), "router");

        market = contracts.market;
        vm.label(address(market), "market");

        tradeStorage = contracts.tradeStorage;
        vm.label(address(tradeStorage), "tradeStorage");

        tradeEngine = contracts.tradeEngine;
        vm.label(address(tradeEngine), "tradeEngine");

        feeDistributor = contracts.feeDistributor;
        vm.label(address(feeDistributor), "feeDistributor");

        OWNER = contracts.owner;
        (weth, usdc,,,) = deploy.helperContracts();
        tickers.push(ethTicker);
        tickers.push(usdcTicker);
        // Pass some time so block timestamp isn't 0
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
    }

    receive() external payable {}

    function test_validating_pyth_feeds() public view {
        IPyth pyth = IPyth(0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a);
        // SOL
        Oracle.isValidPythFeed(pyth, 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d);
        // SEI
        Oracle.isValidPythFeed(pyth, 0x53614f1cb0c031d4af66c04cb9c756234adad0e1cee85303795091499a4084eb);
        // SHIB
        Oracle.isValidPythFeed(pyth, 0xf0d57deca57b3da2fe63a493f4c25925fdfd8edf834b20f93e1f84dbd1504d4a);
        // MATIC
        Oracle.isValidPythFeed(pyth, 0x5de33a9112c2b700b8d30b8a3402c103578ccfa2765696471cc672bd5cf6ac52);
        // FTM
        Oracle.isValidPythFeed(pyth, 0x5c6c0d2386e3352356c3ab84434fafb5ea067ac2678a38a338c4a69ddc4bdb0c);
        // BTC
        Oracle.isValidPythFeed(pyth, 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43);
    }

    IPriceFeed.SecondaryStrategy btcStrategy = IPriceFeed.SecondaryStrategy({
        exists: true,
        feedId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
    });
    IPriceFeed.SecondaryStrategy ethStrategy = IPriceFeed.SecondaryStrategy({
        exists: true,
        feedId: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
    });
    IPriceFeed.SecondaryStrategy solStrategy = IPriceFeed.SecondaryStrategy({
        exists: true,
        feedId: 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d
    });

    /**
     * ================================== Internal Functions ==================================
     */

    // Need the Pyth address and the bytes32 id for the ticker
    function _getPythPrice(IPriceFeed.SecondaryStrategy memory _strategy) private view returns (uint256 price) {
        // Query the Pyth feed for the price
        IPyth pythFeed = IPyth(priceFeed.pyth());
        PythStructs.Price memory pythData = pythFeed.getEmaPriceUnsafe(_strategy.feedId);
        // Expand the price to 30 d.p
        uint256 exponent = PRICE_DECIMALS - pythData.expo.abs();
        price = pythData.price.abs() * (10 ** exponent);
    }
}
