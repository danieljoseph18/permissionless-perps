// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script} from "forge-std/Script.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {MarketId, MarketIdLibrary} from "src/types/MarketId.sol";

contract ExecuteDeposit is Script {
    PositionManager positionManager = PositionManager(payable(0xdF1f52F5020DEaF52C52B00367c63928771E7D71));
    MarketId marketId = MarketId.wrap(0x69b9cda3342215535520e6b157ca90560845ae7d1e75fa59beebef34a49118ab);
    // Replace with key of request
    bytes32 requestKey = 0xff69d8613be1968e452d6660132dcad0d0c5a0668e530d7045cbeaceafa5da3f;

    function run() public {
        vm.broadcast();
        positionManager.executeDeposit(marketId, requestKey);
    }
}
