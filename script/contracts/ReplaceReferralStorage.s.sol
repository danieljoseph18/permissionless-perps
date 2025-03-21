// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import {TradeEngine} from "../../src/positions/TradeEngine.sol";
import {PositionManager} from "../../src/router/PositionManager.sol";
import {ReferralStorage, IReferralStorage} from "../../src/referrals/ReferralStorage.sol";

contract ReplaceReferralStorage is Script {
    TradeEngine tradeEngine = TradeEngine(0x726bE3cDbbF40CFC0A762a2470d3F7c53F325fD5);
    PositionManager positionManager = PositionManager(payable(0xE5A76D3c8545F2cA5Ae2C904F2b1aBB396189696));

    address priceFeed = 0x1e60b36b0eBFFC11ddd9AcBcC9C3CAd91F25C38f;
    address tradeStorage = 0x6A077BBFBF3D3083507A12916B798C17f3F4248e;
    address market = 0x6f87f652A06168dEf357467e9bf339Ceee9C9Ecc;

    address weth = 0x4200000000000000000000000000000000000006;
    address usdc = 0x9881f8b307CC3383500b432a8Ce9597fAfc73A77;
    address marketFactory = 0xF1e4E980C5F0De996664De8f80CfE2dbd5D583D6;

    function run() public {
        vm.startBroadcast();
        ReferralStorage referralStorage = new ReferralStorage(weth, usdc, marketFactory);
        tradeEngine.updateContracts(priceFeed, address(positionManager), tradeStorage, market, address(referralStorage));
        positionManager.updateReferralStorage(IReferralStorage(address(referralStorage)));
        vm.stopBroadcast();
    }
}
