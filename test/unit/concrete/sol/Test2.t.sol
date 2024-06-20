// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "forge-std/console.sol";
import {Default1} from "../../../utils/Default1.sol";
import {SettleValues} from "@src/LRTVault.sol";

contract Test2 is Default1 {

    function test_SetFees() public {
        vm.startPrank(vaultManager);
        vault.setFees(30 * 100);
        assertEq(vault.feesInBips(), 30 * 100);
    }

    function test_SetTreasury() public {
        vm.startPrank(vaultManager);
        vault.setTreasury(user1.addr);
        assertEq(vault.treasury(), user1.addr);
    }

    function test_FeeComputation1() public {
        uint256 amount = 1000000;
        uint256 duration = 7 * 3600 * 24;
        uint256 rate = 200;

        uint256 expectedFee = vault._computeFees(amount, duration, rate);

        assertEq(388, expectedFee);
    }

    function test_FeeComputation2() public {
        assertEq(vault._computeFees(2000000, 14 * 3600 * 24, 100), 777);
    }

    function test_realRate() public {
        uint256 out = vault._computeRealRate(
            9_000_000, // 90%
            10_000_000_000_000, // fees
            10_000_000_000_000_000_000
        );

        console.log("real rate");
        assertEq(8_999_990, out);
    }

    function test_realRate2() public {
        uint256 out = vault._computeRealRate(
            9_000_000, // 90%
			1_000_000_000_000_000_0, // fees == 1%
            1_000_000_000_000_000_000
        );
        console.log("real rate");
        assertEq(8_900_000, out);
    }


    function test_settleFees() public {
        vm.startPrank(vaultManager);

        // underlying.approve(address(vault), 10000000000000000);
        // console.log(underlying.totalSupply());

        // (, uint256 asset2, ) = vault.previewSettle(9_000_000);
        // vault.open(asset2);
        vault.close();

        // check that the epoch start is correctly set
        assertEq(vault.epochStart(), block.timestamp);

        // warp one week later
        vm.warp(block.timestamp + 24 * 3600 * 7);

        vault.setTreasury(user2.addr);

        vault.setFees(10 * 100);

        assertEq(vault.feesInBips(), 10 * 100);

        // precomputation
        uint256 balanceBefore2 = underlying.balanceOf(user2.addr);
        uint256 lastSavedBalance = vault.totalSupply();
		// removing totalAssets()???

        uint256 assetsToVault;
        uint256 expectedAssetFromOwner;
        SettleValues memory settleData;

        uint256 expectedFees = (lastSavedBalance * 7 * 1000) / (10000 * 360);

        uint256 epochRate = 9_500_000;

        (assetsToVault, expectedAssetFromOwner,, settleData) = vault
            .previewSettle(epochRate);

        assertEq(settleData.fees, expectedFees);
        assertEq(expectedAssetFromOwner, expectedFees);

        deal(
            address(underlying),
            address(vaultManager),
            expectedAssetFromOwner
        );
        underlying.approve(address(vault), expectedFees);

        vault.settle(epochRate);

        uint256 balanceAfter2 = underlying.balanceOf(user2.addr);

        assertEq(balanceAfter2, balanceBefore2 + expectedFees);
        vm.stopPrank();
    }
}
