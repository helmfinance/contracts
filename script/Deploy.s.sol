// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {AgentToken} from "../src/core/AgentToken.sol";
import {AgentVault} from "../src/core/AgentVault.sol";
import {FounderVault} from "../src/core/FounderVault.sol";

/// @title Deploy
/// @notice Foundation deploy script. Deploys singleton system contracts and writes
///         addresses to `./deployments/<chainId>.json` for the ABI sync script
///         (consumed by both BE and FE).
/// @dev    Run with:
///         forge script script/Deploy.s.sol --rpc-url mantle_sepolia --broadcast --verify
contract Deploy is Script {
    struct Deployment {
        address registry;
        address treasury;
        address harvester;
        address distributor;
        address redemptionQueue;
        address pythAdapter;
        address mEthAdapter;
        address usdyAdapter;
        address agentTokenImpl;
        address agentVaultImpl;
        address founderVaultImpl;
    }

    function run() external returns (Deployment memory d) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // --- 1. Adapters first (no inter-dependencies) -----------------------
        // d.pythAdapter   = address(new PythPriceAdapter(vm.envAddress("PYTH_CONTRACT_MANTLE_SEPOLIA")));
        // d.mEthAdapter   = address(new MantleMETHAdapter(vm.envAddress("MANTLE_METH"), vm.envAddress("USDC_MANTLE")));
        // d.usdyAdapter   = address(new OndoUSDYAdapter(vm.envAddress("ONDO_USDY_MANTLE"), vm.envAddress("USDC_MANTLE")));

        // --- 2. Singletons ---------------------------------------------------
        // d.treasury        = address(new PlatformTreasury(deployer));
        // d.redemptionQueue = address(new RedemptionQueue());
        // d.harvester       = address(new YieldHarvester());
        // d.distributor     = address(new DividendDistributor());

        // --- 3. Clone implementations. Constructors only call _disableInitializers()
        //        so each implementation deployment is tiny. HelmRegistry will clone
        //        these per-agent via EIP-1167.
        d.agentTokenImpl   = address(new AgentToken());
        d.agentVaultImpl   = address(new AgentVault());
        d.founderVaultImpl = address(new FounderVault());

        // --- 4. Registry (factory). Wires everything together. ---------------
        // d.registry = address(new HelmRegistry(HelmRegistry.RegistryParams({
        //     admin:                   deployer,
        //     usdc:                    vm.envAddress("USDC_MANTLE"),
        //     redemptionQueue:         d.redemptionQueue,
        //     treasury:                d.treasury,
        //     yieldHarvester:          d.harvester,
        //     pythAdapter:             d.pythAdapter,
        //     executor:                deployer,
        //     distributor:             d.distributor,
        //     agentTokenImpl:          d.agentTokenImpl,
        //     agentVaultImpl:          d.agentVaultImpl,
        //     founderVaultImpl:        d.founderVaultImpl,
        //     defaultLockupDays:       180,
        //     defaultSubordinationBps: 5000,
        //     defaultFounderShareBps:  2000
        // })));

        // --- 5. Cross-wire admin pointers ------------------------------------
        // PlatformTreasury(d.treasury).setRegistry(d.registry);
        // RedemptionQueue(d.redemptionQueue).setRegistry(d.registry);
        // YieldHarvester(d.harvester).setRegistry(d.registry);
        // DividendDistributor(d.distributor).setRegistry(d.registry);

        vm.stopBroadcast();

        _writeDeployment(d);
    }

    function _writeDeployment(Deployment memory d) internal {
        string memory json = "deployment";
        vm.serializeAddress(json, "registry",         d.registry);
        vm.serializeAddress(json, "treasury",         d.treasury);
        vm.serializeAddress(json, "harvester",        d.harvester);
        vm.serializeAddress(json, "distributor",      d.distributor);
        vm.serializeAddress(json, "redemptionQueue",  d.redemptionQueue);
        vm.serializeAddress(json, "pythAdapter",      d.pythAdapter);
        vm.serializeAddress(json, "mEthAdapter",      d.mEthAdapter);
        vm.serializeAddress(json, "usdyAdapter",      d.usdyAdapter);
        vm.serializeAddress(json, "agentTokenImpl",   d.agentTokenImpl);
        vm.serializeAddress(json, "agentVaultImpl",   d.agentVaultImpl);
        string memory full = vm.serializeAddress(json, "founderVaultImpl", d.founderVaultImpl);

        string memory path = string.concat(
            "./deployments/", vm.toString(block.chainid), ".json"
        );
        vm.writeJson(full, path);
        console2.log("Deployment written to", path);
    }
}
