// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

contract TestLiquidationCheck is Test {
    function setUp() public {}

    function test_is_liquidatable(
        int256 pnl,
        int256 fundingFees,
        uint256 borrowingFees,
        uint256 maintenanceMargin,
        uint256 size,
        uint256 collateral,
        bool isLong
    ) public pure {
        // Bound inputs to reasonable ranges
        pnl = bound(pnl, -1000e18, 1000e18);
        fundingFees = bound(fundingFees, -100e18, 100e18);
        borrowingFees = bound(borrowingFees, 0, 100e18);
        maintenanceMargin = bound(maintenanceMargin, 0.001e18, 0.1e18); // 0.1% to 10%
        size = bound(size, 1e18, 1000e18);
        collateral = bound(collateral, 0.1e18, 100e18);

        bool isLiquidatable =
            checkIsLiquidatable(pnl, fundingFees, borrowingFees, maintenanceMargin, size, collateral, isLong);

        bool expectedLiquidatable =
            calculateExpectedLiquidation(pnl, fundingFees, borrowingFees, maintenanceMargin, size, collateral, isLong);

        assertEq(isLiquidatable, expectedLiquidatable, "Liquidation check mismatch");
    }

    function checkIsLiquidatable(
        int256 pnl,
        int256 fundingFees,
        uint256 borrowingFees,
        uint256 maintenanceMargin,
        uint256 size,
        uint256 collateral,
        bool isLong
    ) internal pure returns (bool) {
        int256 totalLosses = -pnl + int256(borrowingFees);

        // Add or subtract funding fees based on position type
        if (isLong) {
            totalLosses += fundingFees;
        } else {
            totalLosses -= fundingFees;
        }

        // Calculate remaining collateral after losses
        int256 remainingCollateral = int256(collateral) - totalLosses;

        // Calculate maintenance collateral
        uint256 maintenanceCollateral = (size * maintenanceMargin) / 1e18;

        // Position is liquidatable if remaining collateral is less than maintenance collateral
        return remainingCollateral < int256(maintenanceCollateral);
    }

    function calculateExpectedLiquidation(
        int256 pnl,
        int256 fundingFees,
        uint256 borrowingFees,
        uint256 maintenanceMargin,
        uint256 size,
        uint256 collateral,
        bool isLong
    ) internal pure returns (bool) {
        int256 totalLosses = -pnl + int256(borrowingFees);

        if (isLong) {
            totalLosses += fundingFees;
        } else {
            totalLosses -= fundingFees;
        }

        int256 remainingCollateral = int256(collateral) - totalLosses;
        uint256 maintenanceCollateral = (size * maintenanceMargin) / 1e18;

        return remainingCollateral < int256(maintenanceCollateral);
    }
}
