// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {Router} from "src/router/Router.sol";
import {IPositionManager} from "src/router/PositionManager.sol";
import {MarketId, MarketIdLibrary} from "src/types/MarketId.sol";
import {IPriceFeed} from "src/oracle/interfaces/IPriceFeed.sol";
import {IERC20} from "src/tokens/interfaces/IERC20.sol";

contract CreateWithdrawal is Script {
    Router router = Router(payable(0xADa3a04DD95A48435c219Fc1BD68014D560D26d2));
    MarketId marketId = MarketId.wrap(0x69b9cda3342215535520e6b157ca90560845ae7d1e75fa59beebef34a49118ab);
    IPriceFeed priceFeed = IPriceFeed(0x4C3C29132894f2fB032242E52fb16B5A1ede5A04);
    IPositionManager positionManager = IPositionManager(0xdF1f52F5020DEaF52C52B00367c63928771E7D71);
    address weth = 0xD8eca5111c93EEf563FAB704F2C6A8DD7A12c77D;
    address usdc = 0x9881f8b307CC3383500b432a8Ce9597fAfc73A77;

    address marketToken = 0xd076E2748dDD64fc26D0E09154dDD750F8FeBD40;

    bool shouldUnwrap = true;

    // 6825e18;
    uint256 marketTokenAmountIn = 3000e18;

    function run() public {
        uint256 executionFee = 0.00001 ether;
        // Create Deposit
        vm.startBroadcast();
        IERC20(marketToken).approve(address(router), type(uint256).max);
        router.createWithdrawal{value: executionFee}(
            marketId, msg.sender, weth, marketTokenAmountIn, executionFee, shouldUnwrap
        );
        vm.stopBroadcast();

        // After the Price Request has been Fulfilled, run the execute script.
    }
}
