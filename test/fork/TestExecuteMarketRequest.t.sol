// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {PriceFeed} from "src/oracle/PriceFeed.sol";

contract TestExecuteMarketRequest is Test {
    // Set to block to emulate for simulation
    uint256 constant FORK_BLOCK_NUMBER = 22634051;

    PriceFeed priceFeed = PriceFeed(payable(0xbcE2d2D119a028fBf44Eb18DC292deCe09850340));

    address caller = 0x914d9bDa49a53AE94334eA76E434F64D3DCbc8a9;
    uint256 forkId;

    bytes priceData =
        "0x4254433a31000000000000000000000b00000000674d8e8e0021b9eb145273e44554483a31000000000000000000000c00000000674d8e8e000cb9ac28e28d9f555344433a310000000000000000001000000000674d8e8e0023864d8869777a";
    bytes err = "";
    bytes32 requestId = 0x281481bfc03f5968c8c41487ce0dd5cb401404cb7c10d230d0be567f848a4c9d;
    bytes32 marketRequestKey = 0xcd1a9f7aff355a698dc397e627a5f9dbfed5e04c328ee0f8d03cccbbfc900e16;

    function setUp() public {
        string memory rpcUrl = vm.envString("BNB_SEPOLIA_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_NUMBER);
    }

    function test_execute_market_request() public {
        vm.selectFork(forkId);
        assertEq(block.number, FORK_BLOCK_NUMBER);

        vm.prank(caller);
        priceFeed.setPricesAndExecuteMarket(priceData, err, requestId, marketRequestKey);
    }
}
