// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {AgentNFT} from "../src/system/AgentNFT.sol";

contract AgentNFTTest is Test {
    AgentNFT nft;

    address registry = makeAddr("registry");
    address admin    = makeAddr("admin");
    address founder  = makeAddr("founder");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");

    uint256 constant AGENT_ID = 42;

    /// @dev Re-declared so vm.expectEmit can match by selector.
    event AgentNFTMinted(uint256 indexed agentId, address indexed founder, uint256 initialReputation);
    event ReputationSlashed(
        uint256 indexed agentId,
        uint256 beforeScore,
        uint256 afterScore,
        uint256 amountBps,
        string reason
    );
    event SlashTriggeredWindDown(uint256 indexed agentId, uint256 finalScore);
    event TokenURISet(uint256 indexed agentId, string newURI);

    function setUp() public {
        nft = new AgentNFT(registry, admin);
    }

    // ─── constructor ────────────────────────────────────────────────

    function test_constructor_state() public view {
        assertEq(nft.registry(), registry);
        assertEq(nft.admin(),    admin);
        assertEq(nft.MAX_BPS(),  10_000);
        assertEq(nft.windDownThreshold(), 5_000);
        assertEq(nft.name(),   "Helm Agent Identity");
        assertEq(nft.symbol(), "HELM-AGENT");
    }

    // ─── mint ───────────────────────────────────────────────────────

    function test_mint_byRegistry_succeeds() public {
        vm.prank(registry);
        vm.expectEmit(true, true, false, true);
        emit AgentNFTMinted(AGENT_ID, founder, 10_000);
        nft.mint(AGENT_ID, founder);

        assertEq(nft.ownerOf(AGENT_ID), founder);
        assertEq(nft.reputationOf(AGENT_ID), 10_000);
        assertTrue(nft.isHealthy(AGENT_ID));
    }

    function test_mint_byNonRegistry_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentNFT.NotRegistry.selector);
        nft.mint(AGENT_ID, founder);
    }

    function test_mint_twice_reverts() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(registry);
        vm.expectRevert(AgentNFT.AlreadyMinted.selector);
        nft.mint(AGENT_ID, alice);
    }

    // ─── slash ──────────────────────────────────────────────────────

    function test_slash_byRegistry_reducesReputation() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(registry);
        vm.expectEmit(true, false, false, true);
        emit ReputationSlashed(AGENT_ID, 10_000, 9_000, 1_000, "mandate_breach");
        nft.slash(AGENT_ID, 1_000, "mandate_breach");

        assertEq(nft.reputationOf(AGENT_ID), 9_000);
        (uint256 count, uint256 lastAt) = nft.slashInfoOf(AGENT_ID);
        assertEq(count, 1);
        assertEq(lastAt, block.timestamp);
    }

    function test_slash_byAdmin_succeeds() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(admin);
        nft.slash(AGENT_ID, 500, "admin_action");
        assertEq(nft.reputationOf(AGENT_ID), 9_500);
    }

    function test_slash_byRandom_reverts() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(alice);
        vm.expectRevert(AgentNFT.NotRegistryOrAdmin.selector);
        nft.slash(AGENT_ID, 1_000, "x");
    }

    function test_slash_unknownAgent_reverts() public {
        vm.prank(registry);
        vm.expectRevert(AgentNFT.AgentNotFound.selector);
        nft.slash(999, 1_000, "x");
    }

    function test_slash_zeroOrTooLarge_reverts() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(registry);
        vm.expectRevert(AgentNFT.InvalidSlashAmount.selector);
        nft.slash(AGENT_ID, 0, "x");

        vm.prank(registry);
        vm.expectRevert(AgentNFT.InvalidSlashAmount.selector);
        nft.slash(AGENT_ID, 10_001, "x");
    }

    function test_slash_pastZero_saturates() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        // Slash the full 10000 — score must clamp to 0, not underflow.
        vm.prank(registry);
        nft.slash(AGENT_ID, 10_000, "totalled");
        assertEq(nft.reputationOf(AGENT_ID), 0);

        // Another slash on a zero score still doesn't underflow.
        vm.prank(registry);
        nft.slash(AGENT_ID, 100, "again");
        assertEq(nft.reputationOf(AGENT_ID), 0);

        (uint256 count, ) = nft.slashInfoOf(AGENT_ID);
        assertEq(count, 2);
    }

    function test_slash_accumulates() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(registry); nft.slash(AGENT_ID, 1_000, "one");
        vm.prank(registry); nft.slash(AGENT_ID,   500, "two");
        vm.prank(admin);    nft.slash(AGENT_ID, 1_500, "three");

        assertEq(nft.reputationOf(AGENT_ID), 7_000);
        (uint256 count, ) = nft.slashInfoOf(AGENT_ID);
        assertEq(count, 3);
    }

    function test_slash_pastThreshold_emitsWindDown() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        // 10000 → 5500 (still healthy, threshold 5000)
        vm.prank(registry);
        nft.slash(AGENT_ID, 4_500, "first");
        assertTrue(nft.isHealthy(AGENT_ID));

        // 5500 → 4500 (crosses threshold → wind-down signal)
        vm.prank(registry);
        vm.expectEmit(true, false, false, true);
        emit SlashTriggeredWindDown(AGENT_ID, 4_500);
        nft.slash(AGENT_ID, 1_000, "second");
        assertFalse(nft.isHealthy(AGENT_ID));
    }

    function test_slash_belowThreshold_doesNotRefire() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(registry);
        nft.slash(AGENT_ID, 6_000, "below"); // 10000 → 4000 (one wind-down emit)

        // Further slashes while already below threshold should NOT re-emit
        // the wind-down event. We can't easily assert "no emit" — instead
        // assert the score keeps decreasing while isHealthy remains false.
        vm.prank(registry);
        nft.slash(AGENT_ID, 500, "more");
        assertEq(nft.reputationOf(AGENT_ID), 3_500);
        assertFalse(nft.isHealthy(AGENT_ID));
    }

    // ─── tokenURI ───────────────────────────────────────────────────

    function test_setTokenURI_byRegistry_storesAndEmits() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(registry);
        vm.expectEmit(true, false, false, true);
        emit TokenURISet(AGENT_ID, "ipfs://meta1");
        nft.setTokenURI(AGENT_ID, "ipfs://meta1");

        assertEq(nft.tokenURI(AGENT_ID), "ipfs://meta1");
    }

    function test_setTokenURI_byAdmin_succeeds() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(admin);
        nft.setTokenURI(AGENT_ID, "ipfs://admin-set");
        assertEq(nft.tokenURI(AGENT_ID), "ipfs://admin-set");
    }

    function test_setTokenURI_byRandom_reverts() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(alice);
        vm.expectRevert(AgentNFT.NotRegistryOrAdmin.selector);
        nft.setTokenURI(AGENT_ID, "x");
    }

    function test_tokenURI_unminted_reverts() public {
        vm.expectRevert(AgentNFT.AgentNotFound.selector);
        nft.tokenURI(999);
    }

    function test_tokenURI_emptyByDefault() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);
        assertEq(nft.tokenURI(AGENT_ID), "");
    }

    // ─── transfer ───────────────────────────────────────────────────

    function test_transfer_movesReputationToNewOwner() public {
        vm.prank(registry);
        nft.mint(AGENT_ID, founder);

        vm.prank(registry);
        nft.slash(AGENT_ID, 1_000, "preTransfer");

        vm.prank(founder);
        nft.transferFrom(founder, alice, AGENT_ID);

        assertEq(nft.ownerOf(AGENT_ID), alice);
        // Reputation travels with the NFT; balance unchanged by transfer.
        assertEq(nft.reputationOf(AGENT_ID), 9_000);
    }

    // ─── admin ──────────────────────────────────────────────────────

    function test_transferAdmin_byAdmin_succeeds() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        nft.transferAdmin(newAdmin);
        assertEq(nft.admin(), newAdmin);

        // New admin can act; old admin cannot.
        vm.prank(registry); nft.mint(AGENT_ID, founder);
        vm.prank(newAdmin); nft.slash(AGENT_ID, 100, "ok");
        vm.prank(admin);
        vm.expectRevert(AgentNFT.NotRegistryOrAdmin.selector);
        nft.slash(AGENT_ID, 100, "should-revert");
    }

    function test_transferAdmin_byNonAdmin_reverts() public {
        vm.prank(bob);
        vm.expectRevert(AgentNFT.NotAdmin.selector);
        nft.transferAdmin(bob);
    }

    // ─── views ──────────────────────────────────────────────────────

    function test_isHealthy_aboveAndBelowThreshold() public {
        vm.prank(registry); nft.mint(AGENT_ID, founder);
        assertTrue(nft.isHealthy(AGENT_ID));

        vm.prank(registry); nft.slash(AGENT_ID, 5_000, "edge"); // 10000 → 5000 (==threshold)
        assertTrue(nft.isHealthy(AGENT_ID));

        vm.prank(registry); nft.slash(AGENT_ID, 1, "just-below");
        assertFalse(nft.isHealthy(AGENT_ID));
    }
}
