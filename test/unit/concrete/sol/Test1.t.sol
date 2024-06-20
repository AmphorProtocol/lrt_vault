// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "forge-std/console.sol";
import {Constants} from "../../../utils/Constants.sol";
import {SettleValues} from "@src/LRTVault.sol";
import "forge-std/console.sol";
import {LRTVault} from "src/LRTVault.sol";

contract Test1 is Constants {
    event Deposit(
        address indexed sender,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event FeesChanged(uint16 oldFees, uint16 newFees);

    function test_Deposit() public {
        uint256 depositAmount = 1000;
        address receiver = user1.addr;

        // Approve the vault to spend the tokens
        vm.prank(receiver);
        underlying.approve(address(vault), depositAmount);
        uint256 ownerInitialBalance = underlying.balanceOf(vaultManager);

        // Set up the expected event
        vm.expectEmit(true, true, true, true);
        emit Deposit(receiver, receiver, depositAmount, depositAmount);
        vm.prank(receiver);
        vault.deposit(depositAmount, receiver);

        // Check final balances
        uint256 finalVaultBalance = underlying.balanceOf(address(vault));
        uint256 finalReceiverBalance = vault.balanceOf(receiver);
        uint256 ownerFinalBalance = underlying.balanceOf(vaultManager);

        // Assertions
        assertEq(finalVaultBalance, 0);
        assertEq(finalReceiverBalance, 1000);
        assertEq(ownerFinalBalance, ownerInitialBalance + depositAmount);
    }

    // function test_Deposit_RevertedWithERC4626ExceededMaxDeposit() public {
    //     address receiver = user1.addr;
    //     uint256 depositAmount = vault.maxDeposit(receiver);

    //     // Approve the vault to spend the tokens
    //     vm.prank(receiver);
    //     underlying.approve(address(vault), depositAmount);

    //     // Expect the revert
    //     vm.prank(receiver);
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             bytes4(
    //                 keccak256(
    //                     "ERC4626ExceededMaxDeposit(address,uint256,uint256)"
    //                 )
    //             ),
    //             receiver,
    //             depositAmount,
    //             vault.maxDeposit(receiver)
    //         )
    //     );
    //     vm.prank(vaultManager);
    //     vault.pause();
    //     vault.deposit(depositAmount, receiver);
    // }

    function test_Redeem() public {
        uint256 depositAmount = 1000;
        address receiver = user1.addr;
        address owner = user1.addr;

        // User approves the vault to spend the tokens
        vm.prank(owner);
        underlying.approve(address(vault), depositAmount);

        // Check initial balances before redeem
        uint256 initialVaultBalance = underlying.balanceOf(address(vault));
        uint256 initialReceiverBalance = underlying.balanceOf(receiver);
        uint256 initialOwnerShares = vault.balanceOf(owner);

        // Perform the redeem
        vm.startPrank(owner);
        uint256 max = vault.maxRedeem(owner);
        uint256 previewAmount = vault.previewClaimRedeem(owner);
        // Set up the expected event
        vm.expectEmit(true, true, true, true);
        emit Withdraw(owner, receiver, owner, previewAmount, max);
        uint256 sharesRedeemed = vault.redeem(max, receiver, owner);

        // Check final balances after redeem
        uint256 finalReceiverBalance = underlying.balanceOf(receiver);
        uint256 finalOwnerShares = vault.balanceOf(owner);

        // Assertions
        assertEq(sharesRedeemed, max);
        assertEq(finalOwnerShares, 0);
        assertEq(initialVaultBalance, initialVaultBalance - previewAmount);
        assertEq(finalReceiverBalance, initialReceiverBalance + previewAmount);
        assertEq(finalOwnerShares, initialOwnerShares + sharesRedeemed);
    }

    function test_RedeemExceedsMax() public {
        uint256 depositAmount = 1000;
        address receiver = user1.addr;
        address owner = user1.addr;

        // Mint tokens to the owner
        underlying.mint(owner, depositAmount);

        // User approves the vault to spend the tokens
        vm.prank(owner);
        underlying.approve(address(vault), depositAmount);

        // Perform the deposit
        vm.prank(owner);
        vault.deposit(depositAmount, owner);

        // Get the maximum redeemable shares for the owner
        uint256 maxShares = vault.maxRedeem(owner);

        // Expect the revert with the custom error
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "ERC4626ExceededMaxRedeem(address,uint256,uint256)"
                    )
                ),
                owner,
                maxShares + 1,
                maxShares
            )
        );
        // Perform the redeem with shares exceeding the maximum
        vault.redeem(maxShares + 1, receiver, owner);
    }

    function test_Settle() public {
        uint256 epochRate = 9_500_000;
        // Simulate closing the vault
        vm.startPrank(vaultManager);
		vault.close();
        // Warp to simulate passage of time
        vm.warp(block.timestamp + 7 days);
        // Check initial state
        uint256 initialEpochId = vault.epochId();
        uint256 initialTotalSupply = vault.totalSupply();
        uint256 initialEpochStart = vault.epochStart();
        // Settle the vault
        vault.settle(epochRate);
        // Check final state
        uint256 finalEpochId = vault.epochId();
        uint256 finalTotalSupply = vault.totalSupply();
        uint256 finalEpochStart = vault.epochStart();
        // Assertions
        assertEq(finalEpochId, initialEpochId + 1);
        assertEq(finalTotalSupply, initialTotalSupply);
        assertGt(finalEpochStart, initialEpochStart);
        assertEq(finalEpochStart, initialEpochStart + 7 days);
        vm.stopPrank();
    }

    function test_PendingRedeemRequest() public {
        address owner = user1.addr;
        uint256 depositAmount = 1000;
		vm.prank(vaultManager);
		vault.close();

        // Approve the vault to spend the tokens from the owner
        vm.prank(owner);
        underlying.approve(address(vault), depositAmount);

        // Perform the deposit
        vm.prank(owner);
        vault.deposit(depositAmount, owner);

        // Request to redeem shares
        uint256 redeemAmount = vault.previewClaimRedeem(owner);
        vm.prank(owner);
        vault.requestRedeem(redeemAmount, owner, owner, "");

        // Check pending redeem request for the owner
        uint256 pendingRedeem = vault.pendingRedeemRequest(owner);
        assertEq(pendingRedeem, redeemAmount);
    }

    function test_ClaimableRedeemRequest() public {
        address owner = user1.addr;
        uint256 depositAmount = 1000;
        vm.prank(vaultManager);
		vault.close();
        vm.prank(vaultManager);
        // Mint some tokens to the owner
        underlying.mint(owner, depositAmount);

        // Approve the vault to spend the tokens from the owner
        vm.prank(owner);
        underlying.approve(address(vault), UINT256_MAX);

        // Perform the deposit
        vm.prank(owner);
        vault.deposit(depositAmount, owner);

        uint256 redeemAmount = vault.previewClaimRedeem(owner);
        // Request to redeem shares
        vm.prank(owner);
        vault.requestRedeem(redeemAmount, owner, owner, "");

        uint256 claimableRedeemCurrentEpoch = vault.claimableRedeemRequest(
            owner
        );
        assertEq(claimableRedeemCurrentEpoch, 0);
    }

    function test_TotalPendingRedeems() public {
        address owner = user1.addr;
        uint256 depositAmount1 = 1000;
        vm.prank(vaultManager);
		vault.close();

        // Mint some tokens to the owners
        underlying.mint(owner, depositAmount1);

        // Approve the vault to spend the tokens from the owners
        vm.prank(owner);
        underlying.approve(address(vault), depositAmount1);

        // Perform the deposits
        vm.prank(owner);
        vault.deposit(depositAmount1, owner);

        // Request to redeem shares
        uint256 redeemAmount = vault.previewClaimRedeem(owner);
        vm.prank(owner);
        vault.requestRedeem(redeemAmount, owner, owner, "");

        // Check total pending redeems
        uint256 totalPending = vault.totalPendingRedeems();
        assertEq(totalPending, 0);
    }
}
