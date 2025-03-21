// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {MarketId} from "src/types/MarketId.sol";

contract TestExecutePosition is Test {
    PositionManager positionManager = PositionManager(payable(0xC27F81d7958154484411BB7E579920C5Aae0D1A3));
    uint256 constant FORK_BLOCK_NUMBER = 13323254;
    uint256 constant GAS_PRICE = 7045021315; // 7.045021315 Gwei in wei

    address from = 0x02A2012c36644f4e4b36A14EBe13E23c96f4C5b6;

    bytes32 id = 0x8d8ce8a5a2a9bc7ccb340550759df1606c2cdb4ae7e54267d8f1b645ffbf2ef8;
    bytes32 orderKey = 0x850f5132a15b5bae6e03fa46b92563770db8180d34243c2db6ac323e50c172ae;
    bytes32 requestKey = bytes32(0);

    uint256 forkId;

    function setUp() public {
        string memory rpcUrl = vm.envString("BNB_SEPOLIA_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_NUMBER);
    }

    function test_executing_position_on_fork() public {
        vm.selectFork(forkId);
        assertEq(block.number, FORK_BLOCK_NUMBER);

        console2.log("Block timestamp: ", block.timestamp);

        vm.startPrank(from);
        positionManager.executePosition(MarketId.wrap(id), orderKey, requestKey, from);
        vm.stopPrank();
    }
}
