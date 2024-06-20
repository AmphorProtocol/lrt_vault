//SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "@test/utils/MockERC20.sol";
import {LRTVault} from "@src/LRTVault.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "forge-std/console.sol";

contract Default1 is Test {
    // ERC20 tokens
    MockERC20 immutable underlying = new MockERC20("toto", "tata");
    uint8 decimalsOffset = 0;

    // Future Owner
    address immutable vaultManager = vm.envAddress("VAULT_MANAGER_ADDRESS");

    // Fees
    uint16 fees = uint16(vm.envUint("INITIAL_FEES_AMOUNT"));
    uint256 bootstrap = vm.envUint("VAULT_TEST_BOOTSTRAP_AMOUNT");

    // vault
    string vaultName = vm.envString("VAULT_TEST_NAME");
    string vaultSymbol = vm.envString("VAULT_TEST_SYMBOL");

    // Users
    VmSafe.Wallet user1 = vm.createWallet("user1");
    VmSafe.Wallet user2 = vm.createWallet("user2");
    VmSafe.Wallet user3 = vm.createWallet("user3");
    VmSafe.Wallet user4 = vm.createWallet("user4");
    VmSafe.Wallet user5 = vm.createWallet("user5");
    VmSafe.Wallet user6 = vm.createWallet("user6");
    VmSafe.Wallet user7 = vm.createWallet("user7");
    VmSafe.Wallet user8 = vm.createWallet("user8");
    VmSafe.Wallet user9 = vm.createWallet("user9");
    VmSafe.Wallet user10 = vm.createWallet("user10");
    VmSafe.Wallet[] users;

    // Wallet
    VmSafe.Wallet address0 =
        VmSafe.Wallet({
            addr: address(0),
            publicKeyX: 0,
            publicKeyY: 0,
            privateKey: 0
        });

    // Else
    int256 immutable bipsDivider = 10_000;

    // lrtVault engine
    LRTVault vault;

    constructor() {
        underlying.mint(user1.addr, 10000000000000000000);
        underlying.mint(address(vaultManager), bootstrap);
        console.log(underlying.totalSupply());
        vm.label(address(vaultManager), "vaultManager");

        // vm.label(address(permit2), "permit2");

        //vm.label(address(zapper), "zapper");

        users.push(user1);
        users.push(user2);
        users.push(user3);
        users.push(user4);
        users.push(user5);
        users.push(user6);
        users.push(user7);
        users.push(user8);
        users.push(user9);
        users.push(user10);

        Options memory deploy;
        deploy.constructorData = "";

        vm.startPrank(vaultManager);

        UpgradeableBeacon beacon = UpgradeableBeacon(
            Upgrades.deployBeacon("LRTVault.sol:LRTVault", vaultManager, deploy)
        );

		vault = _proxyDeploy(
			beacon,
            vaultManager,
            vaultManager,
            underlying,
            bootstrap,
            vaultName,
            vaultSymbol
        );

		underlying.approve(address(vault), bootstrap);
		vault.deposit(bootstrap, vaultManager);

        console.log("deployed!!!");
        vm.label(address(vault), "vault");
        vm.label(address(vault.pendingSilo()), "vault.pendingSilo");
        vm.label(address(vault.claimableSilo()), "vault.claimableSilo");

        vm.stopPrank();
    }

    function _proxyDeploy(
        UpgradeableBeacon beacon,
        address owner,
        address treasury,
        ERC20 _underlying,
        uint256 _bootstrap,
        string memory _vaultName,
        string memory _vaultSymbol
    ) internal returns (LRTVault) {
        BeaconProxy proxy = BeaconProxy(
            payable(
                Upgrades.deployBeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        LRTVault.initialize,
                        (
                            fees,
                            owner,
                            treasury,
                            _underlying,
                            _bootstrap,
                            _vaultName,
                            _vaultSymbol,
							false
                        )
                    )
                )
            )
        );
        return LRTVault(address(proxy));
    }
}
