// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {MarketId} from "src/types/MarketId.sol";

contract TestExecuteWithdrawalSim is Test {
    PositionManager positionManager = PositionManager(payable(0xc8597A1444F43f06520e730f5bFa2b2754b5f6C7));
    uint256 constant FORK_BLOCK_NUMBER = 14015526;
    uint256 constant GAS_PRICE = 7045021315; // 7.045021315 Gwei in wei

    address from = 0x02A2012c36644f4e4b36A14EBe13E23c96f4C5b6;

    bytes32 id = 0xfbbffa3e0318270e431fa48c78ca9a02f06577f96f3d73c17ca8bf334b7ee28e;
    bytes32 key = 0x5e6253e3c62bb0401b9c1133e3f50dca1f37566577fa2d2e75e99e4e080a11c8;

    // 10 eth

    uint256 forkId;

    function setUp() public {
        string memory rpcUrl = vm.envString("BNB_SEPOLIA_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_NUMBER);
    }

    function test_executing_withdrawal_on_fork() public {
        vm.selectFork(forkId);
        assertEq(block.number, FORK_BLOCK_NUMBER);

        vm.txGasPrice(GAS_PRICE);

        vm.startPrank(from);
        positionManager.executeWithdrawal(MarketId.wrap(id), key);
        vm.stopPrank();
    }
}
