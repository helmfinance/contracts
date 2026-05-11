// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/yield/DividendDistributor.sol";
import "../src/core/AgentToken.sol";
import "../src/core/FounderVault.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHelmRegistry.sol";
import "./mocks/MockAgentVault.sol";

contract DividendDistributorTest is Test {
    DividendDistributor distributor;
    MockERC20 usdc;
    MockHelmRegistry mockRegistry;
    AgentToken agentToken;
    FounderVault founderVault;

    uint256 constant AGENT_ID = 1;
    address harvester;
    address founder = address(0xF0);
    address alice = address(0xA1);
    address bob = address(0xB0);
    address mockVaultAddr = address(0x7777);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mockRegistry = new MockHelmRegistry();

        // Use a deterministic harvester address
        harvester = address(0x1111);

        distributor = new DividendDistributor(harvester, address(mockRegistry), address(usdc));

        // AgentToken: vault = mockVaultAddr so we can mint from it
        AgentToken tokenImpl = new AgentToken();
        agentToken = AgentToken(Clones.clone(address(tokenImpl)));
        agentToken.initialize("Agent 1", "AGT-1", mockVaultAddr, AGENT_ID);

        // FounderVault with distributor as the carry sender
        FounderVault fvImpl = new FounderVault();
        founderVault = FounderVault(Clones.clone(address(fvImpl)));
        founderVault.initialize(
            AGENT_ID,
            address(agentToken),
            address(new MockAgentVault()), // not used in these tests
            founder,
            address(usdc),
            address(distributor), // distributor sends carry
            90,
            5000,
            1000,
            2000
        );

        // Register in mock registry
        mockRegistry.setDeployment(AGENT_ID, IHelmRegistry.AgentDeployment({
            agentId: AGENT_ID,
            nft: address(0),
            token: address(agentToken),
            vault: mockVaultAddr,
            founderVault: address(founderVault),
            founder: founder,
            phase: IHelmRegistry.Phase.PublicLaunch,
            incubationStart: 0,
            publicLaunchAt: 0
        }));

        // Mint AGT shares: alice=600, bob=400 (total=1000)
        vm.startPrank(mockVaultAddr);
        agentToken.mint(alice, 600e18);
        agentToken.mint(bob, 400e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _stageAndDistribute(uint256 amount) internal returns (uint256 epoch) {
        usdc.mint(harvester, amount);
        vm.startPrank(harvester);
        usdc.approve(address(distributor), amount);
        distributor.stageYield(AGENT_ID, amount);
        epoch = distributor.distribute(AGENT_ID);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Distribute splits 90/10 correctly
    // ---------------------------------------------------------------

    function test_distribute_90_10_split() public {
        uint256 yield = 1_000_000_000; // 1000 USDC
        uint256 epoch = _stageAndDistribute(yield);

        assertEq(epoch, 1);

        (uint256 total, uint256 holdersShare, uint256 totalShares,) =
            distributor.epochSnapshot(AGENT_ID, epoch);

        assertEq(total, yield);
        assertEq(holdersShare, 900_000_000); // 90%
        assertEq(totalShares, 1000e18);

        // Carry (10%) sent to FounderVault
        assertEq(founderVault.carryBalance(), 100_000_000);
    }

    // ---------------------------------------------------------------
    // Holder claim: pro-rata correct
    // ---------------------------------------------------------------

    function test_claim_proRata() public {
        _stageAndDistribute(1_000_000_000);

        // Alice has 600/1000 = 60% of supply
        // Holder share = 900 USDC → alice gets 540 USDC
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 1;

        vm.prank(alice);
        uint256 aliceOut = distributor.claim(AGENT_ID, epochs);
        assertEq(aliceOut, 540_000_000);
        assertEq(usdc.balanceOf(alice), 540_000_000);

        // Bob has 400/1000 = 40% → 360 USDC
        vm.prank(bob);
        uint256 bobOut = distributor.claim(AGENT_ID, epochs);
        assertEq(bobOut, 360_000_000);
        assertEq(usdc.balanceOf(bob), 360_000_000);
    }

    // ---------------------------------------------------------------
    // Double claim reverts
    // ---------------------------------------------------------------

    function test_claim_doubleClaimReverts() public {
        _stageAndDistribute(1_000_000_000);

        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 1;

        vm.prank(alice);
        distributor.claim(AGENT_ID, epochs);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDividendDistributor.AlreadyClaimed.selector, AGENT_ID, 1, alice)
        );
        distributor.claim(AGENT_ID, epochs);
    }

    // ---------------------------------------------------------------
    // Carry sent to FounderVault.receiveCarry verified
    // ---------------------------------------------------------------

    function test_carry_sentToFounderVault() public {
        _stageAndDistribute(500_000_000); // 500 USDC

        // 10% = 50 USDC carry
        assertEq(founderVault.carryBalance(), 50_000_000);

        // Founder can claim carry
        vm.prank(founder);
        uint256 claimed = founderVault.claimCarry();
        assertEq(claimed, 50_000_000);
        assertEq(usdc.balanceOf(founder), 50_000_000);
    }

    // ---------------------------------------------------------------
    // Only harvester can stage/distribute
    // ---------------------------------------------------------------

    function test_stageYield_onlyHarvester() public {
        vm.prank(alice);
        vm.expectRevert(DividendDistributor.NotHarvester.selector);
        distributor.stageYield(AGENT_ID, 100);
    }

    function test_distribute_onlyHarvester() public {
        vm.prank(alice);
        vm.expectRevert(DividendDistributor.NotHarvester.selector);
        distributor.distribute(AGENT_ID);
    }

    // ---------------------------------------------------------------
    // Distribute with no staged yield reverts
    // ---------------------------------------------------------------

    function test_distribute_emptyYield_reverts() public {
        vm.prank(harvester);
        vm.expectRevert(IDividendDistributor.EmptyYieldPool.selector);
        distributor.distribute(AGENT_ID);
    }

    // ---------------------------------------------------------------
    // Multiple epochs
    // ---------------------------------------------------------------

    function test_multipleEpochs() public {
        _stageAndDistribute(1_000_000_000);
        _stageAndDistribute(500_000_000);

        assertEq(distributor.epochOf(AGENT_ID), 2);

        // Alice claims both epochs
        uint256[] memory epochs = new uint256[](2);
        epochs[0] = 1;
        epochs[1] = 2;

        vm.prank(alice);
        uint256 total = distributor.claim(AGENT_ID, epochs);

        // Epoch 1: 900M * 60% = 540M
        // Epoch 2: 450M * 60% = 270M
        // Total = 810M
        assertEq(total, 810_000_000);
    }

    // ---------------------------------------------------------------
    // pendingClaimOf view
    // ---------------------------------------------------------------

    function test_pendingClaimOf() public {
        _stageAndDistribute(1_000_000_000);

        uint256 pending = distributor.pendingClaimOf(AGENT_ID, alice);
        assertEq(pending, 540_000_000);

        // After claim, pending = 0
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 1;
        vm.prank(alice);
        distributor.claim(AGENT_ID, epochs);

        pending = distributor.pendingClaimOf(AGENT_ID, alice);
        assertEq(pending, 0);
    }

    // ---------------------------------------------------------------
    // Claim for non-existent epoch reverts
    // ---------------------------------------------------------------

    function test_claim_nonExistentEpoch_reverts() public {
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 999;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDividendDistributor.EpochNotFinalized.selector, AGENT_ID, 999)
        );
        distributor.claim(AGENT_ID, epochs);
    }
}
