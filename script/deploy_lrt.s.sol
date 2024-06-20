// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Script, console } from "forge-std/Script.sol";
import {LRTVault} from "../src/LRTVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { UpgradeableBeacon } from
    "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { BeaconProxy } from
    "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract MAINNET_DeployAmphor is Script {
    uint256 privateKey;
    string vaultName;
    string vaultSymbol;
    address owner;
    address WSTETHAddr;
    uint256 bootstrap;
    uint256 nonce; // beacon deployment + approve
    Options deploy;

    function run() external {
        // if you want to deploy a vault with a seed phrase instead of a pk,
        // uncomment the following line
        privateKey = vm.envUint("PRIVATE_KEY");
        owner = vm.addr(privateKey);
        vaultName = vm.envString("SYNTHETIC_WSTETH_V1_NAME");
        vaultSymbol = vm.envString("SYNTHETIC_WSTETH_V1_SYMBOL");
		WSTETHAddr = vm.envAddress("WSTETH_MAINNET");
        bootstrap = vm.envUint("BOOTSTRAP_AMOUNT_SYNTHETIC_WSTETH");
        nonce = vm.getNonce(owner);
        address proxyAddress = vm.computeCreateAddress(owner, nonce + 3);

		// all following txs are made using the address of the private key
        vm.startBroadcast(privateKey);

        IERC20(WSTETHAddr).approve(proxyAddress, UINT256_MAX);

        UpgradeableBeacon beacon = UpgradeableBeacon(
            Upgrades.deployBeacon("LRTVault.sol:LRTVault", owner, deploy)
        );

        BeaconProxy proxyWSTETH = BeaconProxy(
            payable(
                Upgrades.deployBeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        LRTVault.initialize,
                        (
                            0,
                            owner,
							owner,
							IERC20(WSTETHAddr),
                            bootstrap,
                            vaultName,
                            vaultSymbol,
							true
                        )
                    )
                )
            )
        );

        address implementation = UpgradeableBeacon(beacon).implementation();
        console.log("Vault LRT proxy address: ", address(proxyWSTETH));
        console.log("Vault beacon address: ", address(beacon));
        console.log("Vault implementation address: ", implementation);


        vm.stopBroadcast();
        //console.log("Vault name: ",AsyncVault(implementation).name());
        //console.log("Vault name: ",AsyncVault(implementation).symbol());

        // Mainnet 
        // source .env && forge clean && forge script script/mainnet_deploy.s.sol:MAINNET_DeployAmphor --ffi --chain-id 1 --optimizer-runs 10000 --verifier-url ${VERIFIER_URL} --etherscan-api-key ${ETHERSCAN_API_KEY} --verify #--broadcast
        // Sepolia
        // source .env && forge clean && forge script script/mainnet_deploy.s.sol:MAINNET_DeployAmphor --ffi --chain-id 534351 --optimizer-runs 10000 --verifier-url ${VERIFIER_URL_SEPOLIA} --etherscan-api-key ${ETHERSCAN_API_KEY} --verify #--broadcast
    }
}
