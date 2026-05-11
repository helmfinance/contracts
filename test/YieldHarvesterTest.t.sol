// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/yield/YieldHarvester.sol";
import "../src/core/AgentVault.sol";
import "../src/core/AgentToken.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPlatformTreasury.sol";
import "./mocks/MockHelmRegistry.sol";
import "./mocks/MockYieldAdapter.sol";

contract YieldHarvesterTest is Test {
    YieldHarvester harvester;
    MockERC20 usdc;
    MockPlatformTreasury treasury;
    MockHelmRegistry mockRegistry;
    MockYieldAdapter mockAdapter;
    AgentVault vault;
    AgentToken agentToken;

    uint256 constant AGENT_ID = 1;
    address executor = address(0xEE);
    address founderVault = address(0xF1);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        treasury = new MockPlatformTreasury();
        mockRegistry = new MockHelmRegistry();
        mockAdapter = new MockYieldAdapter(address(usdc));

        // Deploy harvester
        harvester = new YieldHarvester(executor, address(mockRegistry), address(usdc));

        // Predict vault address for AgentToken
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);

        agentToken = new AgentToken("Agent 1", "AGT-1", predictedVault, AGENT_ID);

        AgentVault.AssetEntry[] memory ea = new AgentVault.AssetEntry[](0);
        AgentVault.WeightConstraint[] memory ew = new AgentVault.WeightConstraint[](0);

        vault = new AgentVault(AgentVault.InitParams({
            agentId: AGENT_ID,
            mandateHash: keccak256("m"),
            mandateURI: "ipfs://m",
            agentToken: address(agentToken),
            founderVault: founderVault,
            registry: address(mockRegistry),
            redemptionQueue: address(0x1),
            treasury: address(treasury),
            yieldHarvester: address(harvester),
            pythAdapter: address(0x2),
            usdc: address(usdc),
            executor: executor,
            initialPhase: IAgentVault.Phase.PublicLaunch,
            assets: ea,
            weightConstraints: ew,
            seniorWindowDuration: 0
        }));
        require(address(vault) == predictedVault, "vault addr");

        // Register in mock registry
        mockRegistry.setDeployment(AGENT_ID, IHelmRegistry.AgentDeployment({
            agentId: AGENT_ID,
            nft: address(0),
            token: address(agentToken),
            vault: address(vault),
            founderVault: founderVault,
            founder: address(0xF0),
            phase: IHelmRegistry.Phase.PublicLaunch,
            incubationStart: 0,
            publicLaunchAt: 0
        }));

        // Register adapter as yield source
        vm.prank(executor);
        harvester.registerSource(AGENT_ID, address(mockAdapter), "");
    }

    // ---------------------------------------------------------------
    // Harvest from mock adapter → USDC deposited to vault yield pool
    // ---------------------------------------------------------------

    function test_harvest_depositsYieldToVault() public {
        uint256 yieldAmt = 500_000_000; // 500 USDC
        usdc.mint(address(mockAdapter), yieldAmt);
        mockAdapter.setYieldAmount(yieldAmt);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        harvester.harvest(AGENT_ID);

        // Yield deposited into vault
        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore + yieldAmt);
        assertEq(vault.yieldPool(), yieldAmt);
    }

    // ---------------------------------------------------------------
    // Harvest with no yield
    // ---------------------------------------------------------------

    function test_harvest_noYield() public {
        harvester.harvest(AGENT_ID);
        assertEq(vault.yieldPool(), 0);
    }

    // ---------------------------------------------------------------
    // lastHarvestAt tracked
    // ---------------------------------------------------------------

    function test_lastHarvestAt() public {
        vm.warp(50_000);
        harvester.harvest(AGENT_ID);
        assertEq(harvester.lastHarvestAt(AGENT_ID), 50_000);
    }

    // ---------------------------------------------------------------
    // Register and remove sources
    // ---------------------------------------------------------------

    function test_registerSource_onlyExecutor() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(IYieldHarvester.OnlyExecutor.selector);
        harvester.registerSource(AGENT_ID, address(0x999), "");
    }

    function test_removeSource() public {
        vm.prank(executor);
        harvester.removeSource(AGENT_ID, address(mockAdapter));

        address[] memory srcs = harvester.sourcesOf(AGENT_ID);
        assertEq(srcs.length, 0);
    }

    function test_removeSource_unknownReverts() public {
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IYieldHarvester.UnknownSource.selector, address(0x999)));
        harvester.removeSource(AGENT_ID, address(0x999));
    }

    function test_sourcesOf() public view {
        address[] memory srcs = harvester.sourcesOf(AGENT_ID);
        assertEq(srcs.length, 1);
        assertEq(srcs[0], address(mockAdapter));
    }
}
