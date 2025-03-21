// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {YieldOptimizer} from "../../src/markets/YieldOptimizer.sol";
import {console2} from "forge-std/console2.sol";

contract TestGetAumYieldOp is Test {
    YieldOptimizer public yieldOptimizer = YieldOptimizer(payable(0x1371aF468464FfC811D974A93bc60b5837242e38));

    uint256 forkId;

    uint256 constant FORK_BLOCK_NUMBER = 22799082;

    function setUp() public {
        string memory rpcUrl = vm.envString("BNB_SEPOLIA_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_NUMBER);
    }

    function test_get_aum() public {
        vm.selectFork(forkId);
        uint256 aum = yieldOptimizer.getAum();
        console2.log("Aum: ", aum);
    }

    function test_get_lp_token_price() public {
        vm.selectFork(forkId);
        uint256 price = yieldOptimizer.getLpTokenPrice();
        console2.log("Price: ", price);
    }
}
