// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import { Script, console } from "forge-std/Script.sol";
import { AsyncVault } from "../src/AsyncVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Upgrades, Options } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { UpgradeableBeacon } from
    "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { BeaconProxy } from
    "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract MAINNET_DeployAmphor is Script {
    uint256 privateKey;
    uint16 fees;
    string vaultName;
    string vaultSymbol;
    address owner;
	address treasuryRenzo;
    address ezETHAddr;
    uint256 bootstrapEZETH;
    uint256 nonce; // beacon deployment + approve
    Options deploy;

    function run() external {
        // if you want to deploy a vault with a seed phrase instead of a pk,
        // uncomment the following line
        privateKey = vm.envUint("PRIVATE_KEY");
        owner = vm.addr(privateKey);
        fees = uint16(vm.envUint("INITIAL_FEES_AMOUNT"));
        vaultName = vm.envString("EZFLOW_V1_NAME");
        vaultSymbol = vm.envString("EZFLOW_V1_SYMBOL");
		ezETHAddr = vm.envAddress("EZETH_MAINNET");
        bootstrapEZETH= vm.envUint("BOOTSTRAP_AMOUNT_EZETH");
		treasuryRenzo= vm.envAddress("TREASURY_RENZO");
        nonce = vm.getNonce(owner);
        address ezETHProxyAddress = vm.computeCreateAddress(owner, nonce + 3);

		// all following txs are made using the address of the private key
        vm.startBroadcast(privateKey);

        IERC20(ezETHAddr).approve(ezETHProxyAddress, UINT256_MAX);

        UpgradeableBeacon beacon = UpgradeableBeacon(
            Upgrades.deployBeacon("AsyncVault.sol:AsyncVault", owner, deploy)
        );

        BeaconProxy proxyWSTETH = BeaconProxy(
            payable(
                Upgrades.deployBeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        AsyncVault.initialize,
                        (
                            fees,
                            fees,
                            owner,
                            treasuryRenzo,
                            owner,
                            IERC20(ezETHAddr),
                            bootstrapEZETH,
                            vaultName,
                            vaultSymbol
                        )
                    )
                )
            )
        );

        address implementation = UpgradeableBeacon(beacon).implementation();
        console.log("Vault EZFLOW proxy address: ", address(proxyWSTETH));
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
