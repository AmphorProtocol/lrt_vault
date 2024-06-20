// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "forge-std/console.sol";
import {Default1} from "../../../utils/Default1.sol";
import {SettleValues} from "@src/LRTVault.sol";

contract TestWorkflow is Default1 {
    address public depositor;
    uint256 public depositAmount;
    uint256 public depositorInitialBalance;

    function setUp() public {
        depositor = user8.addr;
        vm.prank(vaultManager);
        vault.close();
        vm.prank(depositor);
        // warp one week later
        depositAmount = 1000000000000000000;
        underlying.mint(depositor, depositAmount);

        depositorInitialBalance = underlying.balanceOf(depositor);

        vm.prank(depositor);
        underlying.approve(address(vault), depositAmount);

        vm.prank(depositor);
        vault.deposit(depositAmount, depositor);
    }

    function test_redeem() public {
        // check that the epoch start is correctly set
        assertEq(vault.epochStart(), block.timestamp);
        // warp one week later
        vm.warp(block.timestamp + 24 * 3600 * 7);

        vm.prank(vaultManager);
        vault.setFees(0);

        vm.prank(depositor);
        vault.requestRedeem(depositAmount, depositor, depositor, "");

        console.log("depositor redeemed all his balance");
        assertEq(0, underlying.balanceOf(depositor));

        uint256 epochRate = 10_000_000;
        uint256 assetsToVault;
        uint256 expectedAssetFromOwner;
        SettleValues memory settleData;

        (assetsToVault, expectedAssetFromOwner, , settleData) = vault
            .previewSettle(epochRate);

        assertEq(settleData.fees, 0);
        assertEq(expectedAssetFromOwner, depositAmount);

        deal(
            address(underlying),
            address(vaultManager),
            expectedAssetFromOwner
        );
        vm.prank(vaultManager);
        underlying.approve(address(vault), expectedAssetFromOwner);

        vm.prank(vaultManager);
        vault.settle(epochRate);

        vm.prank(depositor);
        vault.claimRedeem(depositor);

        uint256 balanceAfter = underlying.balanceOf(depositor);
        assertEq(depositorInitialBalance, balanceAfter);
        vm.stopPrank();
    }

    function test_redeem_with_fees() public {
        // check that the epoch start is correctly set
        assertEq(vault.epochStart(), block.timestamp);
        // warp one week later
        vm.warp(block.timestamp + 24 * 3600 * 360);

        vm.prank(vaultManager);
        vault.setFees(2000);

        vm.prank(depositor);
        vault.requestRedeem(depositAmount, depositor, depositor, "");

        console.log("depositor redeemed all his balance");
        assertEq(0, underlying.balanceOf(depositor));

		uint256 totalSupply = vault.totalSupply();

        uint256 epochRate = 10_000_000;
        uint256 assetsToVault;
        uint256 realRate;
        uint256 expectedAssetFromOwner;
        SettleValues memory settleData;

        (assetsToVault, expectedAssetFromOwner, realRate, settleData) = vault
            .previewSettle(epochRate);
			
		console.log("real rate");
		console.log(realRate);
		console.log("fees");
		console.log(settleData.fees);

        assertEq(settleData.fees, totalSupply*2000/10000);
        assertEq(expectedAssetFromOwner, depositAmount + totalSupply*2000/10000);

        deal(
            address(underlying),
            address(vaultManager),
            expectedAssetFromOwner
        );
        vm.prank(vaultManager);
        underlying.approve(address(vault), expectedAssetFromOwner);

        vm.prank(vaultManager);
        vault.settle(epochRate);

        vm.prank(depositor);
        vault.claimRedeem(depositor);

        uint256 balanceAfter = underlying.balanceOf(depositor);
        assertEq(depositorInitialBalance* 80 / 100, balanceAfter);
        vm.stopPrank();
    }

}
