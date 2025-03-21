// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {MarketFactory} from "src/factory/MarketFactory.sol";
import {TradeStorage} from "src/positions/TradeStorage.sol";
import {TradeEngine} from "src/positions/TradeEngine.sol";
import {Vault} from "src/markets/Vault.sol";
import {Market} from "src/markets/Market.sol";
import {MarketId} from "src/types/MarketId.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {ReferralStorage} from "src/referrals/ReferralStorage.sol";

contract ReplaceTradeEngine is Script {
    address oldTradeEngine = 0x53bbC398e670cbE14C3f8c1cef61d1F0e942bc0F;

    MarketFactory marketFactory = MarketFactory(0x967e3C53B4e77342EcDE9BC6F3151B9af7d9D8b7);

    TradeStorage tradeStorage = TradeStorage(0xd05A2C6e35CDfacE3EC557Bc6c417c97EbD035e6);

    PositionManager positionManager = PositionManager(payable(0x4B90beba9f3DA11754305E569761097E733357cB));

    Market market = Market(0xa05345aBBe848482e7C4d13160aCA6e0FbC15Ac0);

    ReferralStorage referralStorage = ReferralStorage(payable(0x2dD2D0b04Fcf537E3802245cd34011Fe871636A0));

    address priceFeed = 0xD86da6E8ff874d98331eF7C938412942dc5Faa17;

    uint256 internal constant _ROLE_4 = 1 << 4; // TradeStorage
    uint256 internal constant _ROLE_6 = 1 << 6; // TradeEngine

    function run() public {
        bytes32[] memory marketIds = marketFactory.getMarketIds();

        address[] memory vaults = new address[](marketIds.length);

        for (uint256 i = 0; i < marketIds.length;) {
            vaults[i] = address(market.getVault(MarketId.wrap(marketIds[i])));
            unchecked {
                ++i;
            }
        }

        vm.startBroadcast();

        TradeEngine tradeEngine = new TradeEngine(address(tradeStorage), address(market));

        marketFactory.updateTradeEngine(address(tradeEngine));

        tradeStorage.updateTradeEngine(address(tradeEngine));

        positionManager.grantRoles(address(tradeEngine), _ROLE_6);

        referralStorage.grantRoles(address(tradeEngine), _ROLE_6);

        market.grantRoles(address(tradeEngine), _ROLE_6);

        tradeStorage.grantRoles(address(tradeEngine), _ROLE_6);

        tradeEngine.initialize(
            priceFeed,
            address(referralStorage),
            address(positionManager),
            2e30,
            0.05e18,
            0.1e18,
            0.001e18,
            0.1e18,
            0.0001e18
        );

        tradeEngine.grantRoles(address(tradeStorage), _ROLE_4);

        for (uint256 i = 0; i < vaults.length;) {
            Vault vault = Vault(payable(vaults[i]));
            vault.replaceTradeEngine(oldTradeEngine, address(tradeEngine));
            unchecked {
                ++i;
            }
        }

        vm.stopBroadcast();
    }
}
