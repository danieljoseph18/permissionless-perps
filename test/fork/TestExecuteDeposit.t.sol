// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PositionManager} from "src/router/PositionManager.sol";
import {MarketId} from "src/types/MarketId.sol";

contract TestExecuteDeposit is Test {
    PositionManager positionManager = PositionManager(payable(0x616CA690DA712468901d32dA4CC6d0beEA41dbB6));
    uint256 constant FORK_BLOCK_NUMBER = 13105103;
    uint256 constant GAS_PRICE = 7045021315; // 7.045021315 Gwei in wei

    address from = 0x02A2012c36644f4e4b36A14EBe13E23c96f4C5b6;

    bytes32 id = 0x511df220b507d9a474bda4e6dbae3cb1e83dc33226761d45ed8f4427990d0c23;
    bytes32 key = 0xf5b32f29808db9d1aed7e92856b6890bdeb524f8b10190b231e556b1eb0067fc;

    uint256 forkId;

    function setUp() public {
        string memory rpcUrl = vm.envString("BNB_SEPOLIA_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_NUMBER);
    }

    function test_executing_deposit_on_fork() public {
        vm.selectFork(forkId);
        assertEq(block.number, FORK_BLOCK_NUMBER);

        vm.txGasPrice(GAS_PRICE);

        uint256 gasBefore = gasleft();

        vm.startPrank(from);
        try positionManager.executeDeposit(MarketId.wrap(id), key) {}
        catch {
            console2.log("Failed to execute deposit");
        }
        vm.stopPrank();

        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;

        uint256 gasCostWei = gasUsed * GAS_PRICE;
        uint256 gasCostGwei = gasCostWei / 1e9;
        uint256 gasCostEth = gasCostWei / 1e18;

        console.log("Gas Used:", gasUsed);
        console.log("Gas Cost (Wei):", gasCostWei);
        console.log("Gas Cost (Gwei):", gasCostGwei);
        console.log("Gas Cost (ETH):", gasCostEth);
    }
}
