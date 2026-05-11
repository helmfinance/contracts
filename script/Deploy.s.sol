// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {AgentToken} from "../src/core/AgentToken.sol";
import {AgentVault} from "../src/core/AgentVault.sol";
import {FounderVault} from "../src/core/FounderVault.sol";

import {HelmRegistry} from "../src/system/HelmRegistry.sol";
import {PlatformTreasury} from "../src/system/PlatformTreasury.sol";
import {RedemptionQueue} from "../src/system/RedemptionQueue.sol";

import {YieldHarvester} from "../src/yield/YieldHarvester.sol";
import {DividendDistributor} from "../src/yield/DividendDistributor.sol";

import {PythPriceAdapter} from "../src/adapters/PythPriceAdapter.sol";
import {SyntheticAsset} from "../src/adapters/SyntheticAsset.sol";
import {MantleMETHAdapter} from "../src/adapters/MantleMETHAdapter.sol";
import {OndoUSDYAdapter} from "../src/adapters/OndoUSDYAdapter.sol";

/// @title Deploy
/// @notice Full-system deploy script for Helm on Mantle Sepolia (chainId 5003).
///         Writes all addresses to `./deployments/<chainId>.json` for the BE/FE
///         ABI sync, and prints them to stdout.
/// @dev    Run with:
///         forge script script/Deploy.s.sol --rpc-url $MANTLE_SEPOLIA_RPC --broadcast
///
///         Required env: DEPLOYER_PRIVATE_KEY, USDC_ADDRESS.
contract Deploy is Script {
    // ─── Pyth Stable channel feed IDs ───────────────────────────────
    bytes32 constant NVDA_FEED = 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593;
    bytes32 constant SPY_FEED  = 0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5;
    bytes32 constant AAPL_FEED = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
    bytes32 constant TSLA_FEED = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 constant MSFT_FEED = 0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1;

    /// @notice Equity-feed staleness window (96h matches PythPriceAdapter convention).
    uint64 constant EQUITY_MAX_STALE = 96 hours;

    /// @notice Mantle Sepolia Pyth contract.
    address constant PYTH_MANTLE_SEPOLIA = 0x98046Bd286715D3B0BC227Dd7a956b83D8978603;

    /// @notice Output of a full deployment.
    struct Deployment {
        // singletons / system
        address registry;
        address treasury;
        address harvester;
        address distributor;
        address redemptionQueue;
        // adapters
        address pythAdapter;
        address mEthAdapter;
        address usdyAdapter;
        // clone implementations
        address agentTokenImpl;
        address agentVaultImpl;
        address founderVaultImpl;
        // synthetics
        address sNVDA;
        address sSPY;
        address sAAPL;
        address sTSLA;
        address sMSFT;
    }

    function run() external returns (Deployment memory d) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address usdc = vm.envAddress("USDC_ADDRESS");

        console2.log("Deployer:", deployer);
        console2.log("USDC:    ", usdc);

        vm.startBroadcast(deployerKey);

        // 1. Platform treasury (deployer is initial admin).
        d.treasury = address(new PlatformTreasury(usdc, deployer));

        // 2. Pyth price adapter with per-feed staleness for the 5 equities.
        d.pythAdapter = _deployPythAdapter();

        // 3. Yield-bearing adapters (mocks — see TODO in each contract).
        d.mEthAdapter = address(new MantleMETHAdapter(usdc, 1e18));
        d.usdyAdapter = address(new OndoUSDYAdapter(usdc, 1e18));

        // 4. Five synthetic equities, all routing through the Pyth adapter.
        d.sNVDA = address(new SyntheticAsset("Synthetic NVIDIA",  "sNVDA", "NVDA", NVDA_FEED, d.pythAdapter, usdc));
        d.sSPY  = address(new SyntheticAsset("Synthetic S&P 500", "sSPY",  "SPY",  SPY_FEED,  d.pythAdapter, usdc));
        d.sAAPL = address(new SyntheticAsset("Synthetic Apple",   "sAAPL", "AAPL", AAPL_FEED, d.pythAdapter, usdc));
        d.sTSLA = address(new SyntheticAsset("Synthetic Tesla",   "sTSLA", "TSLA", TSLA_FEED, d.pythAdapter, usdc));
        d.sMSFT = address(new SyntheticAsset("Synthetic Microsoft","sMSFT","MSFT", MSFT_FEED, d.pythAdapter, usdc));

        // 5. Clone implementations for the per-agent trio.
        d.agentTokenImpl   = address(new AgentToken());
        d.agentVaultImpl   = address(new AgentVault());
        d.founderVaultImpl = address(new FounderVault());

        // 6. HelmRegistry + YieldHarvester + DividendDistributor + RedemptionQueue.
        //    They are mutually dependent — the registry holds the queue, harvester
        //    and distributor as immutables, but each of those holds the registry
        //    as its immutable too. We break the cycle by predicting the registry's
        //    create address, deploying the three dependents with that prediction,
        //    then deploying the registry itself.
        uint64 nonce = vm.getNonce(deployer);
        address predictedRegistry = vm.computeCreateAddress(deployer, nonce + 3);

        d.harvester   = address(new YieldHarvester(deployer, predictedRegistry, usdc));
        d.distributor = address(new DividendDistributor(d.harvester, predictedRegistry, usdc));
        d.redemptionQueue = address(new RedemptionQueue(deployer, predictedRegistry));
        d.registry = address(new HelmRegistry(HelmRegistry.RegistryParams({
            admin:                   deployer,
            usdc:                    usdc,
            redemptionQueue:         d.redemptionQueue,
            treasury:                d.treasury,
            yieldHarvester:          d.harvester,
            pythAdapter:             d.pythAdapter,
            executor:                deployer,
            distributor:             d.distributor,
            agentTokenImpl:          d.agentTokenImpl,
            agentVaultImpl:          d.agentVaultImpl,
            founderVaultImpl:        d.founderVaultImpl,
            defaultLockupDays:       180,
            defaultSubordinationBps: 4000,
            defaultFounderShareBps:  2000
        })));
        require(d.registry == predictedRegistry, "registry addr mismatch");

        vm.stopBroadcast();

        _writeDeployment(d);
        _printDeployment(d);
    }

    function _deployPythAdapter() internal returns (address) {
        bytes32[] memory feeds = new bytes32[](5);
        uint64[]  memory stale = new uint64[](5);
        feeds[0] = NVDA_FEED;
        feeds[1] = SPY_FEED;
        feeds[2] = AAPL_FEED;
        feeds[3] = TSLA_FEED;
        feeds[4] = MSFT_FEED;
        for (uint256 i = 0; i < 5; i++) {
            stale[i] = EQUITY_MAX_STALE;
        }
        return address(new PythPriceAdapter(PYTH_MANTLE_SEPOLIA, feeds, stale));
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
        vm.serializeAddress(json, "founderVaultImpl", d.founderVaultImpl);
        vm.serializeAddress(json, "sNVDA",            d.sNVDA);
        vm.serializeAddress(json, "sSPY",             d.sSPY);
        vm.serializeAddress(json, "sAAPL",            d.sAAPL);
        vm.serializeAddress(json, "sTSLA",            d.sTSLA);
        string memory full = vm.serializeAddress(json, "sMSFT", d.sMSFT);

        string memory path = string.concat(
            "./deployments/", vm.toString(block.chainid), ".json"
        );
        vm.writeJson(full, path);
        console2.log("Deployment written to", path);
    }

    function _printDeployment(Deployment memory d) internal pure {
        console2.log("============================================================");
        console2.log("Helm deployment");
        console2.log("============================================================");
        console2.log("registry:        ", d.registry);
        console2.log("treasury:        ", d.treasury);
        console2.log("harvester:       ", d.harvester);
        console2.log("distributor:     ", d.distributor);
        console2.log("redemptionQueue: ", d.redemptionQueue);
        console2.log("pythAdapter:     ", d.pythAdapter);
        console2.log("mEthAdapter:     ", d.mEthAdapter);
        console2.log("usdyAdapter:     ", d.usdyAdapter);
        console2.log("agentTokenImpl:  ", d.agentTokenImpl);
        console2.log("agentVaultImpl:  ", d.agentVaultImpl);
        console2.log("founderVaultImpl:", d.founderVaultImpl);
        console2.log("sNVDA:           ", d.sNVDA);
        console2.log("sSPY:            ", d.sSPY);
        console2.log("sAAPL:           ", d.sAAPL);
        console2.log("sTSLA:           ", d.sTSLA);
        console2.log("sMSFT:           ", d.sMSFT);
        console2.log("============================================================");
    }
}
