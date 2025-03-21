// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {HelperConfig, IHelperConfig} from "./HelperConfig.s.sol";
import {MarketFactory} from "../src/factory/MarketFactory.sol";
import {PriceFeed, IPriceFeed} from "../src/oracle/PriceFeed.sol";
import {MockPriceFeed} from "../test/mocks/MockPriceFeed.sol";
import {TradeStorage} from "../src/positions/TradeStorage.sol";
import {ReferralStorage} from "../src/referrals/ReferralStorage.sol";
import {PositionManager} from "../src/router/PositionManager.sol";
import {Router} from "../src/router/Router.sol";
import {IMarket} from "../src/markets/interfaces/IMarket.sol";
import {Oracle} from "../src/oracle/Oracle.sol";
import {FeeDistributor} from "../src/rewards/FeeDistributor.sol";
import {Pool} from "../src/markets/Pool.sol";
import {OwnableRoles} from "../src/auth/OwnableRoles.sol";
import {TradeEngine} from "../src/positions/TradeEngine.sol";
import {Market} from "../src/markets/Market.sol";

/// @dev - IMPORTANT: WHEN DEPLOYING MAKE SURE TO UPDATE CAs, and Backend URLs on CHAINLINK FUNCTIONS SOURCES
contract Deploy is Script {
    IHelperConfig public helperConfig;

    struct Contracts {
        MarketFactory marketFactory;
        Market market;
        TradeStorage tradeStorage;
        TradeEngine tradeEngine;
        IPriceFeed priceFeed; // Deployed in Helper Config
        ReferralStorage referralStorage;
        PositionManager positionManager;
        Router router;
        FeeDistributor feeDistributor;
        address owner;
    }

    IHelperConfig.NetworkConfig public activeNetworkConfig;
    IHelperConfig.Contracts public helperContracts;

    uint256 internal constant _ROLE_0 = 1 << 0;
    uint256 internal constant _ROLE_1 = 1 << 1;
    uint256 internal constant _ROLE_2 = 1 << 2;
    uint256 internal constant _ROLE_3 = 1 << 3;
    uint256 internal constant _ROLE_4 = 1 << 4;
    uint256 internal constant _ROLE_5 = 1 << 5;
    uint256 internal constant _ROLE_6 = 1 << 6;
    uint256 internal constant _ROLE_69 = 1 << 69; // Price Keeper

    address[] keepers = [
        0xA11c8E0E6A2104c7bE0A19b68620626bC5A2aca7,
        0x542a69D50209129B803D3614B535F8175C282044,
        0x804E3F088b5FA0f04FB7bb5F36C07b1789FD835f,
        0xF0bE92981E8b65e9a1988077D0b5D784ECbcedF5,
        0x0Dc6EAAd2012B1C30b6381192e7225DD518C7aB2,
        0x914d9bDa49a53AE94334eA76E434F64D3DCbc8a9,
        0x214BBAef92762dDc693841e112F9C3d1f8B4e75f
    ];

    function run() external returns (Contracts memory contracts) {
        helperConfig = new HelperConfig();
        IPriceFeed priceFeed;
        {
            activeNetworkConfig = helperConfig.getActiveNetworkConfig();
            helperContracts = activeNetworkConfig.contracts;
        }

        vm.startBroadcast();

        contracts = Contracts(
            MarketFactory(address(0)),
            Market(address(0)),
            TradeStorage(address(0)),
            TradeEngine(address(0)),
            priceFeed,
            ReferralStorage(payable(address(0))),
            PositionManager(payable(address(0))),
            Router(payable(address(0))),
            FeeDistributor(address(0)),
            msg.sender
        );

        /**
         * ============ Deploy Contracts ============
         */
        contracts.marketFactory =
            new MarketFactory(activeNetworkConfig.contracts.weth, activeNetworkConfig.contracts.usdc);

        if (activeNetworkConfig.mockFeed) {
            // Deploy a Mock Price Feed contract
            contracts.priceFeed = new MockPriceFeed(
                address(contracts.marketFactory), activeNetworkConfig.contracts.weth, activeNetworkConfig.contracts.pyth
            );
        } else {
            // Deploy a Price Feed Contract
            contracts.priceFeed = new PriceFeed(
                address(contracts.marketFactory), activeNetworkConfig.contracts.weth, activeNetworkConfig.contracts.pyth
            );
        }

        contracts.market = new Market(activeNetworkConfig.contracts.weth, activeNetworkConfig.contracts.usdc);

        contracts.referralStorage = new ReferralStorage(
            activeNetworkConfig.contracts.weth, activeNetworkConfig.contracts.usdc, address(contracts.marketFactory)
        );

        contracts.tradeStorage = new TradeStorage(address(contracts.market), address(contracts.priceFeed));

        contracts.tradeEngine = new TradeEngine(address(contracts.tradeStorage), address(contracts.market));

        contracts.positionManager = new PositionManager(
            address(contracts.marketFactory),
            address(contracts.market),
            address(contracts.tradeStorage),
            address(contracts.referralStorage),
            address(contracts.priceFeed),
            address(contracts.tradeEngine),
            activeNetworkConfig.contracts.weth,
            activeNetworkConfig.contracts.usdc
        );

        contracts.router = new Router(
            address(contracts.marketFactory),
            address(contracts.market),
            address(contracts.priceFeed),
            activeNetworkConfig.contracts.usdc,
            activeNetworkConfig.contracts.weth,
            address(contracts.positionManager)
        );

        contracts.feeDistributor = new FeeDistributor(
            address(contracts.marketFactory), activeNetworkConfig.contracts.weth, activeNetworkConfig.contracts.usdc
        );

        /**
         * ============ Set Up Contracts ============
         */
        Pool.Config memory defaultMarketConfig = Pool.Config({
            // 100x
            maxLeverage: 100,
            reserveFactor: 2000, // 20%
            // Skew Scale = Skew for Max Velocity
            maxFundingVelocity: 900, // 9% per day
            skewScale: 1_000_000 // 1 Mil USD
        });

        contracts.marketFactory.initialize(
            defaultMarketConfig,
            address(contracts.market),
            address(contracts.tradeStorage),
            address(contracts.tradeEngine),
            address(contracts.priceFeed),
            address(contracts.referralStorage),
            address(contracts.positionManager),
            address(contracts.feeDistributor),
            msg.sender,
            0.005 ether,
            21000
        );

        contracts.marketFactory.setRouter(address(contracts.router));

        contracts.marketFactory.setFeedValidators(activeNetworkConfig.contracts.pyth);

        // @audit - dummy values
        contracts.priceFeed.initialize(185000, 300_000, 0.005 ether, 5 minutes);
        if (!activeNetworkConfig.mockFeed) {
            OwnableRoles(address(contracts.priceFeed)).grantRoles(address(contracts.marketFactory), _ROLE_0);
            OwnableRoles(address(contracts.priceFeed)).grantRoles(address(contracts.router), _ROLE_3);

            // Grant price keeper role to all keepers
            for (uint256 i = 0; i < keepers.length;) {
                OwnableRoles(address(contracts.priceFeed)).grantRoles(keepers[i], _ROLE_69);
                unchecked {
                    ++i;
                }
            }

            // @crucial: Set Secondary Feeds for Market Tokens
            PriceFeed(payable(address(contracts.priceFeed))).updateSecondaryStrategy(
                "ETH:1", IPriceFeed.SecondaryStrategy({exists: true, feedId: activeNetworkConfig.contracts.ethPythId})
            );
            PriceFeed(payable(address(contracts.priceFeed))).updateSecondaryStrategy(
                "USDC:1", IPriceFeed.SecondaryStrategy({exists: true, feedId: activeNetworkConfig.contracts.usdcPythId})
            );
        }

        contracts.market.initialize(
            address(contracts.tradeStorage), address(contracts.priceFeed), address(contracts.marketFactory)
        );
        // Dampen by 10x
        contracts.market.setPriceImpactScalar(0.1e18);

        contracts.market.grantRoles(address(contracts.positionManager), _ROLE_1);
        contracts.market.grantRoles(address(contracts.router), _ROLE_3);
        contracts.market.grantRoles(address(contracts.tradeEngine), _ROLE_6);

        contracts.tradeStorage.initialize(address(contracts.tradeEngine), address(contracts.marketFactory));
        contracts.tradeStorage.grantRoles(address(contracts.positionManager), _ROLE_1);
        contracts.tradeStorage.grantRoles(address(contracts.router), _ROLE_3);

        contracts.tradeEngine.initialize(
            address(contracts.priceFeed),
            address(contracts.referralStorage),
            address(contracts.positionManager),
            2e30,
            0.05e18,
            0.1e18,
            0.001e18, // 0.1%
            0.1e18, // 10% of position fee
            0.0001e18 // 0.01%
        );
        contracts.tradeEngine.grantRoles(address(contracts.tradeStorage), _ROLE_4);

        // Need to update estimates based on historical data
        contracts.positionManager.updateGasEstimates(21000, 1000 gwei, 1000 gwei, 1000 gwei);

        contracts.referralStorage.setTier(0, 0.05e18);
        contracts.referralStorage.setTier(1, 0.1e18);
        contracts.referralStorage.setTier(2, 0.15e18);
        contracts.referralStorage.grantRoles(address(contracts.tradeEngine), _ROLE_6);

        contracts.feeDistributor.grantRoles(address(contracts.marketFactory), _ROLE_0);

        // Transfer ownership to caller --> for testing
        contracts.marketFactory.transferOwnership(msg.sender);
        if (!activeNetworkConfig.mockFeed) OwnableRoles(address(contracts.priceFeed)).transferOwnership(msg.sender);
        contracts.referralStorage.transferOwnership(msg.sender);
        contracts.positionManager.transferOwnership(msg.sender);
        contracts.router.transferOwnership(msg.sender);
        contracts.feeDistributor.transferOwnership(msg.sender);

        vm.stopBroadcast();

        return contracts;
    }
}
