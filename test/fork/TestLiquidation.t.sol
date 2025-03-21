// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {MarketId} from "src/types/MarketId.sol";

contract TestLiquidation is Test {
    PositionManager positionManager = PositionManager(payable(0xc6Ea95e91A9B0D3E90b858fB80c664D82566A882));
    uint256 constant FORK_BLOCK_NUMBER = 14201498;
    uint256 constant GAS_PRICE = 7045021315; // 7.045021315 Gwei in wei

    address from = 0x804E3F088b5FA0f04FB7bb5F36C07b1789FD835f;

    bytes32 id = 0x8ae2737d738d9fe594edb47cd0f678867fe43e68eeacdf54788fb99c4bd996a3;
    bytes32 positionKey = 0xe4d006347e230f0fd451adf55f278d7aec61425f53d86f9b1f774ceca0976add;
    bytes32 requestKey = 0x1d2e9ab17006c43d51297971abd75238f8660f3c438810fcd1b54e2d419072e9;

    uint256 forkId;

    function setUp() public {
        string memory rpcUrl = vm.envString("BNB_SEPOLIA_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_NUMBER);
    }

    function test_liquidating_position_on_fork() public {
        vm.selectFork(forkId);
        assertEq(block.number, FORK_BLOCK_NUMBER);

        vm.startPrank(from);
        positionManager.liquidatePosition(MarketId.wrap(id), positionKey, requestKey);
        vm.stopPrank();
    }
}
