// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/system/HelmRegistry.sol";
import {AgentNFT} from "../src/system/AgentNFT.sol";
import {TimeProvider} from "../src/system/TimeProvider.sol";
import "../src/core/AgentVault.sol";
import "../src/core/AgentToken.sol";
import "../src/core/FounderVault.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPlatformTreasury.sol";

contract HelmRegistryTest is Test {
    HelmRegistry registry;
    AgentNFT agentNFT;
    TimeProvider timeProvider;
    MockERC20 usdc;
    MockPlatformTreasury treasury;

    address admin = address(0xAD);
    address redemptionQueue = address(0xBB);
    address yieldHarvester = address(0xCC);
    address pythAdapter = address(0xDD);
    address executor = address(0xEE);
    address distributor = address(0xFF);
    address founder = address(0xF0);

    bytes32 constant MANDATE_HASH = keccak256("mandate-1");
    string constant MANDATE_URI = "ipfs://mandate-1";
    uint256 constant SEED = 1_000e6; // 1000 USDC

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        treasury = new MockPlatformTreasury();
        timeProvider = new TimeProvider();

        // Set mint fee to 0 for simpler test math
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Mint, 0);

        // Implementation deployments (clone targets) — constructors just call
        // _disableInitializers() so these are tiny.
        address tokenImpl = address(new AgentToken());
        address vaultImpl = address(new AgentVault());
        address fvImpl    = address(new FounderVault());

        // Pre-deploy AgentNFT with the predicted registry address so its
        // onlyRegistry modifier sees the right caller.
        uint64 nonce = vm.getNonce(address(this));
        address predictedRegistry = vm.computeCreateAddress(address(this), nonce + 1);
        agentNFT = new AgentNFT(predictedRegistry, admin);

        registry = new HelmRegistry(HelmRegistry.RegistryParams({
            admin: admin,
            usdc: address(usdc),
            redemptionQueue: redemptionQueue,
            treasury: address(treasury),
            yieldHarvester: yieldHarvester,
            pythAdapter: pythAdapter,
            executor: executor,
            distributor: distributor,
            agentNFT: address(agentNFT),
            timeProvider: address(timeProvider),
            agentTokenImpl: tokenImpl,
            agentVaultImpl: vaultImpl,
            founderVaultImpl: fvImpl,
            defaultLockupDays: 180,
            defaultSubordinationBps: 5000,
            defaultFounderShareBps: 2000
        }));
        require(address(registry) == predictedRegistry, "registry addr mismatch");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _registerAgent() internal returns (uint256 agentId) {
        return _registerAgentWith(MANDATE_HASH, MANDATE_URI, SEED);
    }

    function _registerAgentWith(bytes32 hash, string memory uri, uint256 seed) internal returns (uint256 agentId) {
        usdc.mint(founder, seed);
        vm.startPrank(founder);
        usdc.approve(address(registry), seed);
        IAgentVault.AssetEntry[] memory emptyAssets = new IAgentVault.AssetEntry[](0);
        IAgentVault.WeightConstraint[] memory emptyWc = new IAgentVault.WeightConstraint[](0);
        agentId = registry.registerAgent(hash, uri, seed, emptyAssets, emptyWc);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // registerAgent deploys 3 contracts, returns id, phase=Incubation
    // ---------------------------------------------------------------

    function test_registerAgent_deploysContracts() public {
        vm.warp(10_000);
        uint256 agentId = _registerAgent();

        assertEq(agentId, 1);
        assertEq(registry.agentCount(), 1);

        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        assertEq(d.agentId, 1);
        assertEq(d.founder, founder);
        assertTrue(d.token != address(0));
        assertTrue(d.vault != address(0));
        assertTrue(d.founderVault != address(0));
        assertEq(uint8(d.phase), uint8(IHelmRegistry.Phase.Incubation));
        assertEq(d.incubationStart, 10_000);

        // AgentToken vault should point to vault
        AgentToken token = AgentToken(d.token);
        assertEq(token.vault(), d.vault);

        // FounderVault should hold the seed shares (minted by vault.deposit)
        FounderVault fv = FounderVault(d.founderVault);
        assertGt(AgentToken(d.token).balanceOf(d.founderVault), 0);
        assertEq(fv.founder(), founder);

        // AgentNFT minted to the founder at full reputation.
        assertEq(d.nft, address(agentNFT));
        assertEq(agentNFT.ownerOf(agentId), founder);
        assertEq(agentNFT.reputationOf(agentId), 10_000);
    }

    // ---------------------------------------------------------------
    // advanceToPublic before 30 days reverts
    // ---------------------------------------------------------------

    function test_advanceToPublic_before30days_reverts() public {
        vm.warp(10_000);
        uint256 agentId = _registerAgent();

        // Try to advance at day 29
        vm.warp(10_000 + 29 days);
        vm.expectRevert(
            abi.encodeWithSelector(HelmRegistry.IncubationNotComplete.selector, uint64(10_000 + 30 days))
        );
        registry.advanceToPublic(agentId);
    }

    // ---------------------------------------------------------------
    // vm.warp 30+ days, advanceToPublic succeeds
    // ---------------------------------------------------------------

    function test_advanceToPublic_after30days_succeeds() public {
        vm.warp(10_000);
        uint256 agentId = _registerAgent();

        vm.warp(10_000 + 30 days);
        registry.advanceToPublic(agentId);

        assertEq(uint8(registry.phaseOf(agentId)), uint8(IHelmRegistry.Phase.PublicLaunch));
    }

    function test_advanceToPublic_twice_reverts() public {
        vm.warp(10_000);
        uint256 agentId = _registerAgent();

        vm.warp(10_000 + 30 days);
        registry.advanceToPublic(agentId);

        vm.expectRevert(HelmRegistry.AlreadyAdvanced.selector);
        registry.advanceToPublic(agentId);
    }

    // ---------------------------------------------------------------
    // markWindDown by non-vault reverts
    // ---------------------------------------------------------------

    function test_markWindDown_nonVault_reverts() public {
        uint256 agentId = _registerAgent();

        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(HelmRegistry.NotVault.selector, agentId));
        registry.markWindDown(agentId);
    }

    function test_markWindDown_byVault_succeeds() public {
        uint256 agentId = _registerAgent();
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);

        vm.prank(d.vault);
        registry.markWindDown(agentId);

        assertEq(uint8(registry.phaseOf(agentId)), uint8(IHelmRegistry.Phase.WindDown));
        // 20% slash applied via AgentNFT (10000 → 8000 bps).
        assertEq(agentNFT.reputationOf(agentId), 8_000);
        (uint256 slashCount, ) = agentNFT.slashInfoOf(agentId);
        assertEq(slashCount, 1);
    }

    // ---------------------------------------------------------------
    // markSettled by non-vault reverts
    // ---------------------------------------------------------------

    function test_markSettled_nonVault_reverts() public {
        uint256 agentId = _registerAgent();

        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(HelmRegistry.NotVault.selector, agentId));
        registry.markSettled(agentId);
    }

    // ---------------------------------------------------------------
    // Duplicate mandateHash reverts
    // ---------------------------------------------------------------

    function test_registerAgent_duplicateMandate_reverts() public {
        _registerAgent();

        usdc.mint(founder, SEED);
        vm.startPrank(founder);
        usdc.approve(address(registry), SEED);
        vm.expectRevert(abi.encodeWithSelector(HelmRegistry.MandateAlreadyUsed.selector, MANDATE_HASH));
        registry.registerAgent(MANDATE_HASH, MANDATE_URI, SEED, _emptyAssets(), _emptyWc());
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Invalid mandate
    // ---------------------------------------------------------------

    function test_registerAgent_zeroMandateHash_reverts() public {
        usdc.mint(founder, SEED);
        vm.startPrank(founder);
        usdc.approve(address(registry), SEED);
        vm.expectRevert(IHelmRegistry.MandateInvalid.selector);
        registry.registerAgent(bytes32(0), MANDATE_URI, SEED, _emptyAssets(), _emptyWc());
        vm.stopPrank();
    }

    function test_registerAgent_emptyURI_reverts() public {
        usdc.mint(founder, SEED);
        vm.startPrank(founder);
        usdc.approve(address(registry), SEED);
        vm.expectRevert(IHelmRegistry.MandateInvalid.selector);
        registry.registerAgent(MANDATE_HASH, "", SEED, _emptyAssets(), _emptyWc());
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Insufficient seed
    // ---------------------------------------------------------------

    function test_registerAgent_insufficientSeed_reverts() public {
        uint256 lowSeed = 999e6;
        usdc.mint(founder, lowSeed);
        vm.startPrank(founder);
        usdc.approve(address(registry), lowSeed);
        vm.expectRevert(IHelmRegistry.InsufficientSeed.selector);
        registry.registerAgent(MANDATE_HASH, MANDATE_URI, lowSeed, _emptyAssets(), _emptyWc());
        vm.stopPrank();
    }

    function _emptyAssets() internal pure returns (IAgentVault.AssetEntry[] memory) {
        return new IAgentVault.AssetEntry[](0);
    }
    function _emptyWc() internal pure returns (IAgentVault.WeightConstraint[] memory) {
        return new IAgentVault.WeightConstraint[](0);
    }

    // ---------------------------------------------------------------
    // Multiple agents
    // ---------------------------------------------------------------

    function test_registerAgent_multiple() public {
        uint256 id1 = _registerAgentWith(keccak256("m1"), "ipfs://m1", SEED);
        uint256 id2 = _registerAgentWith(keccak256("m2"), "ipfs://m2", SEED);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(registry.agentCount(), 2);

        IHelmRegistry.AgentDeployment memory d1 = registry.deploymentOf(id1);
        IHelmRegistry.AgentDeployment memory d2 = registry.deploymentOf(id2);
        assertTrue(d1.vault != d2.vault);
        assertTrue(d1.token != d2.token);
    }

    // ---------------------------------------------------------------
    // Slash
    // ---------------------------------------------------------------

    function test_slash_onlyAdmin() public {
        uint256 agentId = _registerAgent();

        vm.prank(founder);
        vm.expectRevert(IHelmRegistry.OnlyAdmin.selector);
        registry.slash(agentId, "bad agent");

        vm.prank(admin);
        registry.slash(agentId, "bad agent");
        assertEq(uint8(registry.phaseOf(agentId)), uint8(IHelmRegistry.Phase.Slashed));
    }

    // ---------------------------------------------------------------
    // AgentNotFound
    // ---------------------------------------------------------------

    function test_phaseOf_unknownAgent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(HelmRegistry.AgentNotFound.selector, 999));
        registry.phaseOf(999);
    }
}
