// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MarketFactory} from "src/factory/MarketFactory.sol";
import {Market} from "src/markets/Market.sol";
import {TradeStorage} from "src/positions/TradeStorage.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {Router} from "src/router/Router.sol";
import {PriceFeed, IPriceFeed} from "src/oracle/PriceFeed.sol";
import {OwnableRoles} from "src/auth/OwnableRoles.sol";
import {MarketIdLibrary, MarketId} from "src/types/MarketId.sol";
import {HelperConfig, IHelperConfig} from "../HelperConfig.s.sol";

contract ReplacePriceFeed is Script {
    IHelperConfig public helperConfig;

    IHelperConfig.NetworkConfig public activeNetworkConfig;
    IHelperConfig.Contracts public helperContracts;

    MarketFactory marketFactory = MarketFactory(0x51B2835DB19EAB6931F4988278242E0AA746eB4a);
    Market market = Market(0x81b0a28E71d6e6D53E9891195e74A5cab2ad36Ae);
    TradeStorage tradeStorage = TradeStorage(0xAc97ebB045c4EeE38A70372df68bbBd63ac2Da70);
    TradeEngine tradeEngine = TradeEngine(0x7160544352bA0453F31BF61f5123075a935f7D9a);
    PositionManager positionManager = PositionManager(payable(0x60496f6ADD32E1D9A16A47E19F04581b60C9D128));
    Router router = Router(payable(0x1A011e115368916287cEBf41bCE6eEE0122c8966));

    address referralStorage = 0x23692a0cA433Fbe597281a6d0F28632cA60EFCa2;

    // Fill old pricefeed here
    PriceFeed oldPriceFeed = PriceFeed(payable(0x1641F22EdE2C33Aa85f8495989A05Bc022d99aFE));

    address[] keepers = [
        0xA11c8E0E6A2104c7bE0A19b68620626bC5A2aca7,
        0x542a69D50209129B803D3614B535F8175C282044,
        0x804E3F088b5FA0f04FB7bb5F36C07b1789FD835f,
        0xF0bE92981E8b65e9a1988077D0b5D784ECbcedF5,
        0x0Dc6EAAd2012B1C30b6381192e7225DD518C7aB2,
        0x914d9bDa49a53AE94334eA76E434F64D3DCbc8a9,
        0x214BBAef92762dDc693841e112F9C3d1f8B4e75f
    ];

    uint256 private constant _ROLE_0 = 1 << 0;
    uint256 private constant _ROLE_3 = 1 << 3;
    uint256 private constant _ROLE_69 = 1 << 69; // Price Keeper

    /// IMPORTANT -> NEED TO REPLACE CHAINLINK FUNCTIONS, AS HARD-CODED ADDRESSES WILL NEED TO
    /// BE SWITCHED TO THE NEW PRICE-FEED ETC.
    /// IMPORTANT -> NEED TO UPDATE PRICE SERVER URL.
    // IMPORTANT -> NEED TO SUPPORT ALL ASSETS SUPPORTED BY THE OLD FEED OR STATE WILL BE INCONSISTENT
    function run() public {
        helperConfig = new HelperConfig();

        activeNetworkConfig = helperConfig.getActiveNetworkConfig();

        helperContracts = activeNetworkConfig.contracts;

        bytes32[] memory marketIds = marketFactory.getMarketIds();

        vm.startBroadcast();

        IPriceFeed newPriceFeed = new PriceFeed(address(marketFactory), helperContracts.weth, helperContracts.pyth);

        newPriceFeed.initialize(185000, 300_000, 0.005 ether, 5 minutes);

        // Temporarily grant MarketFactory role to deployer to replace all assets previously supported
        OwnableRoles(address(newPriceFeed)).grantRoles(msg.sender, _ROLE_0);
        for (uint256 i = 0; i < marketIds.length;) {
            string memory ticker = market.getTicker(MarketId.wrap(marketIds[i]));
            IPriceFeed.SecondaryStrategy memory secondaryStrategy = oldPriceFeed.getSecondaryStrategy(ticker);
            uint8 decimals = oldPriceFeed.tokenDecimals(ticker);
            newPriceFeed.supportAsset(ticker, secondaryStrategy, decimals);
            unchecked {
                ++i;
            }
        }
        OwnableRoles(address(newPriceFeed)).revokeRoles(msg.sender, _ROLE_0);

        OwnableRoles(address(newPriceFeed)).grantRoles(address(marketFactory), _ROLE_0);
        OwnableRoles(address(newPriceFeed)).grantRoles(address(router), _ROLE_3);

        // Grant price keeper role to all keepers
        for (uint256 i = 0; i < keepers.length;) {
            OwnableRoles(address(newPriceFeed)).grantRoles(keepers[i], _ROLE_69);
            unchecked {
                ++i;
            }
        }

        // Set Secondary Feeds for Market Tokens
        PriceFeed(payable(address(newPriceFeed))).updateSecondaryStrategy(
            "ETH:1", IPriceFeed.SecondaryStrategy({exists: true, feedId: helperContracts.ethPythId})
        );
        PriceFeed(payable(address(newPriceFeed))).updateSecondaryStrategy(
            "USDC:1", IPriceFeed.SecondaryStrategy({exists: true, feedId: helperContracts.usdcPythId})
        );

        marketFactory.updatePriceFeed(newPriceFeed);
        market.updatePriceFeed(newPriceFeed);
        tradeStorage.updatePriceFeed(newPriceFeed);
        tradeEngine.updateContracts(
            address(newPriceFeed), address(positionManager), address(tradeStorage), address(market), referralStorage
        );
        positionManager.updatePriceFeed(newPriceFeed);
        router.updatePriceFeed(newPriceFeed);
        vm.stopBroadcast();
    }
}
