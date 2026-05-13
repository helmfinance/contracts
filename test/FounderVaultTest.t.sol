// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/core/FounderVault.sol";
import "../src/core/AgentToken.sol";
import "../src/system/TimeProvider.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAgentVault.sol";

contract FounderVaultTest is Test {
    FounderVault fv;
    FounderVault fvImpl;
    AgentToken agentToken;
    MockERC20 usdc;
    MockAgentVault mockVault;
    TimeProvider timeProvider;

    address founder = address(0xF0);
    address distributor = address(0xD1);
    address alice = address(0xA1);
    uint256 constant AGENT_ID = 1;
    uint64 constant LOCKUP_DAYS = 180; // 6 months
    uint16 constant SUBORDINATION_BPS = 5000; // 50%

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mockVault = new MockAgentVault();
        timeProvider = new TimeProvider();

        // AgentToken's vault is the AgentVault, not FounderVault.
        // For this test we use a token whose vault is address(this) so we can mint freely.
        AgentToken tokenImpl = new AgentToken();
        agentToken = AgentToken(Clones.clone(address(tokenImpl)));
        agentToken.initialize("Agent 1 Shares", "AGT-1", address(this), AGENT_ID);

        fvImpl = new FounderVault();
        fv = _newFV(AGENT_ID, LOCKUP_DAYS, SUBORDINATION_BPS, 1000, 2000);
    }

    /// @dev Helper: clone + initialize a FounderVault. Returns the clone.
    function _newFV(
        uint256 agentId_,
        uint64 lockupDays_,
        uint16 subBps_,
        uint16 carryBps_,
        uint16 founderShareBps_
    ) internal returns (FounderVault out) {
        out = FounderVault(Clones.clone(address(fvImpl)));
        out.initialize(
            agentId_,
            address(agentToken),
            address(mockVault),
            founder,
            address(usdc),
            distributor,
            lockupDays_,
            subBps_,
            carryBps_,
            founderShareBps_,
            address(timeProvider)
        );
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _depositShares(uint256 amount) internal {
        // Mint AGT to this contract (we are the vault for AgentToken)
        agentToken.mint(address(this), amount);
        agentToken.approve(address(fv), amount);
        fv.depositFounderShares(amount);
    }

    // ---------------------------------------------------------------
    // Constructor validation
    // ---------------------------------------------------------------

    /// @dev Clone without initializing; lets us scope expectRevert to the initialize call.
    function _cloneFV() internal returns (FounderVault) {
        return FounderVault(Clones.clone(address(fvImpl)));
    }

    function test_constructor_rejectsWrongCarryBps() public {
        FounderVault t = _cloneFV();
        vm.expectRevert(FounderVault.InvalidCarryBps.selector);
        t.initialize(1, address(agentToken), address(mockVault), founder, address(usdc), distributor, 90, 5000, 500, 2000, address(timeProvider));
    }

    function test_constructor_rejectsLowFounderShareBps() public {
        FounderVault t = _cloneFV();
        vm.expectRevert(FounderVault.InvalidFounderShareBps.selector);
        t.initialize(1, address(agentToken), address(mockVault), founder, address(usdc), distributor, 90, 5000, 1000, 400, address(timeProvider));
    }

    function test_constructor_rejectsHighFounderShareBps() public {
        FounderVault t = _cloneFV();
        vm.expectRevert(FounderVault.InvalidFounderShareBps.selector);
        t.initialize(1, address(agentToken), address(mockVault), founder, address(usdc), distributor, 90, 5000, 1000, 3100, address(timeProvider));
    }

    function test_constructor_rejectsShortLockup() public {
        FounderVault t = _cloneFV();
        vm.expectRevert(FounderVault.InvalidLockupDays.selector);
        t.initialize(1, address(agentToken), address(mockVault), founder, address(usdc), distributor, 89, 5000, 1000, 2000, address(timeProvider));
    }

    // ---------------------------------------------------------------
    // Deposit then immediate withdraw reverts (lockup active)
    // ---------------------------------------------------------------

    function test_withdraw_revertsLockupActive() public {
        vm.warp(1000);
        _depositShares(100e18);

        uint64 lockEnd = fv.lockupEndsAt();
        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(IFounderVault.LockupActive.selector, lockEnd));
        fv.withdraw(10e18);
    }

    // ---------------------------------------------------------------
    // Warp past lockup, withdraw 30% (under 50% threshold) succeeds
    // ---------------------------------------------------------------

    function test_withdraw_underThreshold_succeeds() public {
        vm.warp(1000);
        _depositShares(100e18);

        // Warp past lockup
        vm.warp(1000 + uint256(LOCKUP_DAYS) * 1 days + 1);

        vm.prank(founder);
        fv.withdraw(30e18); // 30% < 50% threshold

        assertEq(fv.totalSharesHeld(), 70e18);
        assertEq(agentToken.balanceOf(founder), 30e18);
        assertEq(fv.cumulativeWithdrawnBps(), 3000); // 30%
    }

    // ---------------------------------------------------------------
    // Withdraw past subordination threshold reverts
    // ---------------------------------------------------------------

    function test_withdraw_pastThreshold_reverts() public {
        vm.warp(1000);
        _depositShares(100e18);

        vm.warp(1000 + uint256(LOCKUP_DAYS) * 1 days + 1);

        // Try to withdraw 51% → exceeds 50% threshold
        vm.prank(founder);
        vm.expectRevert(FounderVault.SubordinationBreached.selector);
        fv.withdraw(51e18);
    }

    function test_withdraw_exactThreshold_succeeds() public {
        vm.warp(1000);
        _depositShares(100e18);

        vm.warp(1000 + uint256(LOCKUP_DAYS) * 1 days + 1);

        // Withdraw exactly 50% → at threshold, should succeed
        vm.prank(founder);
        fv.withdraw(50e18);
        assertEq(fv.totalSharesHeld(), 50e18);
    }

    function test_withdraw_cumulativeBreaches() public {
        vm.warp(1000);
        _depositShares(100e18);

        vm.warp(1000 + uint256(LOCKUP_DAYS) * 1 days + 1);

        // Withdraw 30%, then try another 25% → cumulative 55% > 50%
        vm.prank(founder);
        fv.withdraw(30e18);

        vm.prank(founder);
        vm.expectRevert(FounderVault.SubordinationBreached.selector);
        fv.withdraw(25e18);
    }

    // ---------------------------------------------------------------
    // Carry claim before any carry → revert
    // ---------------------------------------------------------------

    function test_claimCarry_revertsWhenEmpty() public {
        vm.prank(founder);
        vm.expectRevert(IFounderVault.NothingToClaim.selector);
        fv.claimCarry();
    }

    // ---------------------------------------------------------------
    // Receive carry → claim succeeds
    // ---------------------------------------------------------------

    function test_receiveCarry_thenClaim() public {
        uint256 carryAmount = 500_000_000; // 500 USDC
        usdc.mint(distributor, carryAmount);

        vm.startPrank(distributor);
        usdc.approve(address(fv), carryAmount);
        fv.receiveCarry(carryAmount);
        vm.stopPrank();

        assertEq(fv.carryBalance(), carryAmount);

        vm.prank(founder);
        uint256 claimed = fv.claimCarry();

        assertEq(claimed, carryAmount);
        assertEq(usdc.balanceOf(founder), carryAmount);
        assertEq(fv.carryBalance(), 0);
    }

    // ---------------------------------------------------------------
    // receiveCarry: only distributor
    // ---------------------------------------------------------------

    function test_receiveCarry_revertsNonDistributor() public {
        vm.prank(alice);
        vm.expectRevert(IFounderVault.OnlyDistributor.selector);
        fv.receiveCarry(100);
    }

    // ---------------------------------------------------------------
    // Non-founder calls revert
    // ---------------------------------------------------------------

    function test_withdraw_revertsNonFounder() public {
        vm.warp(1000);
        _depositShares(100e18);
        vm.warp(1000 + uint256(LOCKUP_DAYS) * 1 days + 1);

        vm.prank(alice);
        vm.expectRevert(IFounderVault.OnlyFounder.selector);
        fv.withdraw(10e18);
    }

    function test_claimCarry_revertsNonFounder() public {
        vm.prank(alice);
        vm.expectRevert(IFounderVault.OnlyFounder.selector);
        fv.claimCarry();
    }

    function test_triggerWindDown_revertsNonFounder() public {
        vm.prank(alice);
        vm.expectRevert(IFounderVault.OnlyFounder.selector);
        fv.triggerWindDown("not founder");
    }

    // ---------------------------------------------------------------
    // Trigger wind-down → AgentVault state changes
    // ---------------------------------------------------------------

    function test_triggerWindDown_callsVault() public {
        vm.prank(founder);
        fv.triggerWindDown("founder exit");

        assertTrue(mockVault.windDownTriggered());
        assertEq(mockVault.windDownReason(), "founder exit");
    }

    // ---------------------------------------------------------------
    // isSubordinationActive
    // ---------------------------------------------------------------

    function test_isSubordinationActive() public {
        vm.warp(1000);
        _depositShares(100e18);
        vm.warp(1000 + uint256(LOCKUP_DAYS) * 1 days + 1);

        assertFalse(fv.isSubordinationActive());

        // Withdraw exactly to threshold
        vm.prank(founder);
        fv.withdraw(50e18);

        assertTrue(fv.isSubordinationActive());
    }

    // ---------------------------------------------------------------
    // Lockup sets on first deposit only
    // ---------------------------------------------------------------

    function test_lockupSetsOnFirstDeposit() public {
        vm.warp(5000);
        _depositShares(50e18);
        uint64 firstLockup = fv.lockupEndsAt();
        assertEq(firstLockup, uint64(5000 + uint256(LOCKUP_DAYS) * 1 days));

        // Second deposit does not reset lockup
        vm.warp(6000);
        _depositShares(50e18);
        assertEq(fv.lockupEndsAt(), firstLockup);
        assertEq(fv.totalDeposited(), 100e18);
        assertEq(fv.totalSharesHeld(), 100e18);
    }
}
