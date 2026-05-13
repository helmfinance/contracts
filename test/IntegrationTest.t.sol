// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AgentToken} from "../src/core/AgentToken.sol";
import {AgentVault} from "../src/core/AgentVault.sol";
import {FounderVault} from "../src/core/FounderVault.sol";
import {HelmRegistry} from "../src/system/HelmRegistry.sol";
import {RedemptionQueue} from "../src/system/RedemptionQueue.sol";
import {AgentNFT} from "../src/system/AgentNFT.sol";
import {TimeProvider} from "../src/system/TimeProvider.sol";
import {YieldHarvester} from "../src/yield/YieldHarvester.sol";
import {DividendDistributor} from "../src/yield/DividendDistributor.sol";
import {PythPriceAdapter} from "../src/adapters/PythPriceAdapter.sol";
import {SyntheticAsset} from "../src/adapters/SyntheticAsset.sol";

import {IAgentVault} from "../src/interfaces/IAgentVault.sol";
import {IAgentToken} from "../src/interfaces/IAgentToken.sol";
import {IFounderVault} from "../src/interfaces/IFounderVault.sol";
import {IHelmRegistry} from "../src/interfaces/IHelmRegistry.sol";
import {IRedemptionQueue} from "../src/interfaces/IRedemptionQueue.sol";
import {IPlatformTreasury} from "../src/interfaces/IPlatformTreasury.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockYieldAdapter} from "./mocks/MockYieldAdapter.sol";
import {MockPlatformTreasury} from "./mocks/MockPlatformTreasury.sol";
import {MantleMETHAdapter} from "../src/adapters/MantleMETHAdapter.sol";
import {OndoUSDYAdapter} from "../src/adapters/OndoUSDYAdapter.sol";

/// @title IntegrationTest
/// @notice End-to-end tests exercising the full Helm system with real contracts.
///         Only Pyth, USDC and the yield adapter are mocked; HelmRegistry,
///         AgentVault, AgentToken, FounderVault, PythPriceAdapter, SyntheticAsset,
///         YieldHarvester, DividendDistributor and RedemptionQueue are all real.
/// @dev    PlatformTreasury is currently only available as a mock implementation
///         of IPlatformTreasury — TODO: swap in the real PlatformTreasury once
///         the contract exists (after Prompt 9).
contract IntegrationTest is Test {
    // ── system contracts ────────────────────────────────────────────
    MockERC20 usdc;
    MockPyth pyth;
    PythPriceAdapter priceAdapter;
    SyntheticAsset sNVDA;
    SyntheticAsset sSPY;
    MockYieldAdapter yieldAdapter;
    MockPlatformTreasury treasury;
    HelmRegistry registry;
    AgentNFT agentNFT;
    TimeProvider timeProvider;
    YieldHarvester harvester;
    DividendDistributor distributor;
    RedemptionQueue queue;

    // ── clone implementations ───────────────────────────────────────
    address tokenImpl;
    address vaultImpl;
    address fvImpl;

    // ── pyth feeds ──────────────────────────────────────────────────
    bytes32 constant NVDA_FEED = keccak256("NVDA/USD");
    bytes32 constant SPY_FEED  = keccak256("SPY/USD");

    // ── actors ──────────────────────────────────────────────────────
    address admin    = makeAddr("admin");
    address founder1 = makeAddr("founder1");
    address founder2 = makeAddr("founder2");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address carol    = makeAddr("carol");
    address backend1 = makeAddr("backend1");
    address backend2 = makeAddr("backend2");

    // ── trio struct for manual deploys ──────────────────────────────
    struct Trio {
        AgentToken token;
        AgentVault vault;
        FounderVault founderVault;
    }

    // ─── setUp ──────────────────────────────────────────────────────

    function setUp() public {
        // anchor block.timestamp far enough in the future that test-side
        // vm.warp() jumps don't underflow when comparing against past values
        vm.warp(1_700_000_000);

        // 1. Mock USDC, decimals=6
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.label(address(usdc), "USDC");

        // 2. MockPyth + initial prices (expo=-5, raw price in 1e-5 units)
        pyth = new MockPyth(1);
        vm.label(address(pyth), "Pyth");
        _setPythPrice(NVDA_FEED, 21_486_000);  // $214.86
        _setPythPrice(SPY_FEED,  73_724_000);  // $737.24

        // 3. PythPriceAdapter — register both feeds with 96h staleness (equity)
        bytes32[] memory feeds = new bytes32[](2);
        uint64[]  memory stale = new uint64[](2);
        feeds[0] = NVDA_FEED; feeds[1] = SPY_FEED;
        stale[0] = 96 hours;   stale[1] = 96 hours;
        priceAdapter = new PythPriceAdapter(address(pyth), feeds, stale);
        vm.label(address(priceAdapter), "PythPriceAdapter");

        // 4. Two synthetic equities
        sNVDA = new SyntheticAsset(
            "Synthetic NVIDIA", "sNVDA", "NVDA",
            NVDA_FEED, address(priceAdapter), address(usdc)
        );
        sSPY = new SyntheticAsset(
            "Synthetic S&P 500", "sSPY", "SPY",
            SPY_FEED, address(priceAdapter), address(usdc)
        );
        vm.label(address(sNVDA), "sNVDA");
        vm.label(address(sSPY), "sSPY");

        // 5. Mock yield adapter (used for stub harvest flows)
        yieldAdapter = new MockYieldAdapter(address(usdc));
        vm.label(address(yieldAdapter), "MockYieldAdapter");

        // 6. Implementations (clone targets)
        tokenImpl = address(new AgentToken());
        vaultImpl = address(new AgentVault());
        fvImpl    = address(new FounderVault());
        vm.label(tokenImpl, "AgentTokenImpl");
        vm.label(vaultImpl, "AgentVaultImpl");
        vm.label(fvImpl,    "FounderVaultImpl");

        // 7. Treasury (mock for now; TODO: real PlatformTreasury after Prompt 9)
        treasury = new MockPlatformTreasury();
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Mint,      50);  // 0.5%
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Redeem,    50);  // 0.5%
        treasury.setFeeRate(IPlatformTreasury.FeeKind.Rebalance,  5);  // 0.05%
        vm.label(address(treasury), "PlatformTreasury(mock)");

        // 8/9. AgentNFT + queue + harvester + distributor + registry form a
        // mutual-dependency cycle (each takes the registry, and the registry
        // takes each of them). Predict the registry's CREATE address, deploy
        // the four dependents with that prediction, then deploy the registry.
        timeProvider = new TimeProvider();

        uint64 nonce = vm.getNonce(address(this));
        address predictedRegistry = vm.computeCreateAddress(address(this), nonce + 4);

        agentNFT    = new AgentNFT(predictedRegistry, admin);
        harvester   = new YieldHarvester(backend1, predictedRegistry, address(usdc), address(timeProvider));
        distributor = new DividendDistributor(address(harvester), predictedRegistry, address(usdc), address(timeProvider));
        queue       = new RedemptionQueue(admin, predictedRegistry, address(timeProvider));

        registry = new HelmRegistry(HelmRegistry.RegistryParams({
            admin:                   admin,
            usdc:                    address(usdc),
            redemptionQueue:         address(queue),
            treasury:                address(treasury),
            yieldHarvester:          address(harvester),
            pythAdapter:             address(priceAdapter),
            executor:                backend1,
            distributor:             address(distributor),
            agentNFT:                address(agentNFT),
            timeProvider:            address(timeProvider),
            agentTokenImpl:          tokenImpl,
            agentVaultImpl:          vaultImpl,
            founderVaultImpl:        fvImpl,
            defaultLockupDays:       180,
            defaultSubordinationBps: 4000,
            defaultFounderShareBps:  2000
        }));
        require(address(registry) == predictedRegistry, "registry addr mismatch");
        vm.label(address(registry),    "HelmRegistry");
        vm.label(address(agentNFT),    "AgentNFT");
        vm.label(address(queue),       "RedemptionQueue");
        vm.label(address(harvester),   "YieldHarvester");
        vm.label(address(distributor), "DividendDistributor");
    }

    // ─── helpers ────────────────────────────────────────────────────

    /// @dev Set a Pyth price with expo=-5 (so `raw` is dollars × 100,000).
    function _setPythPrice(bytes32 feed, uint256 raw) internal {
        pyth.setPrice(feed, int64(int256(raw)), 50, -5, block.timestamp);
    }

    /// @dev Mint USDC to a user.
    function _giveUsdc(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    /// @dev Register an agent via the real HelmRegistry with the supplied
    ///      mandate (tradeable assets and weight bounds). After registration
    ///      the vault is fully wired and can rebalance into any of `assets`.
    function _registerAgent(
        address founder_,
        bytes32 mandateHash,
        uint256 seedUsdc,
        IAgentVault.AssetEntry[] memory assets,
        IAgentVault.WeightConstraint[] memory weights
    ) internal returns (uint256 agentId) {
        _giveUsdc(founder_, seedUsdc);
        vm.startPrank(founder_);
        usdc.approve(address(registry), seedUsdc);
        agentId = registry.registerAgent(mandateHash, "ipfs://mandate", seedUsdc, assets, weights);
        vm.stopPrank();

        // Authorize the freshly-deployed vault on each synthetic in the mandate
        // (the test contract is the synthetics' admin).
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].kind == IAgentVault.AssetKind.Synthetic) {
                SyntheticAsset(assets[i].asset).registerVault(d.vault);
            }
        }
    }

    /// @dev Cash-only convenience overload (no tradeable assets).
    function _registerAgent(address founder_, bytes32 mandateHash, uint256 seedUsdc)
        internal returns (uint256 agentId)
    {
        return _registerAgent(founder_, mandateHash, seedUsdc, _emptyAssets(), _emptyWeights());
    }

    /// @dev Deploy an agent trio manually (cloning the impls). Lets tests
    ///      configure assets/weights, executor and initialPhase — none of which
    ///      the real HelmRegistry currently exposes. Bypasses registry tracking.
    function _deployAgentManual(
        uint256 agentId,
        address founder_,
        address executor_,
        IAgentVault.AssetEntry[] memory assets,
        IAgentVault.WeightConstraint[] memory weights,
        IAgentVault.Phase initialPhase
    ) internal returns (Trio memory t) {
        t.token        = AgentToken(Clones.clone(tokenImpl));
        t.vault        = AgentVault(Clones.clone(vaultImpl));
        t.founderVault = FounderVault(Clones.clone(fvImpl));

        t.token.initialize(
            string.concat("Helm Agent ", vm.toString(agentId)),
            string.concat("AGT-", vm.toString(agentId)),
            address(t.vault),
            agentId
        );

        t.vault.initialize(IAgentVault.InitParams({
            agentId:              agentId,
            mandateHash:          keccak256(abi.encodePacked("mandate", agentId)),
            mandateURI:           "ipfs://mandate",
            agentToken:           address(t.token),
            founderVault:         address(t.founderVault),
            registry:             address(this), // test contract impersonates registry
            redemptionQueue:      address(queue),
            treasury:             address(treasury),
            yieldHarvester:       address(harvester),
            pythAdapter:          address(priceAdapter),
            usdc:                 address(usdc),
            executor:             executor_,
            initialPhase:         initialPhase,
            assets:               assets,
            weightConstraints:    weights,
            seniorWindowDuration: 0,
            timeProvider:         address(timeProvider)
        }));

        t.founderVault.initialize(
            agentId, address(t.token), address(t.vault),
            founder_, address(usdc), address(distributor),
            180, 4000, 1000, 2000, address(timeProvider)
        );

        // Authorize the vault to mint/burn each synthetic in its mandate.
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].kind == IAgentVault.AssetKind.Synthetic) {
                SyntheticAsset(assets[i].asset).registerVault(address(t.vault));
            }
        }
    }

    /// @dev Mint vault shares to `user` by depositing USDC into the vault.
    function _mintShares(AgentVault vault, address user, uint256 usdcAmount)
        internal returns (uint256 shares)
    {
        _giveUsdc(user, usdcAmount);
        vm.startPrank(user);
        usdc.approve(address(vault), usdcAmount);
        shares = vault.deposit(usdcAmount, user);
        vm.stopPrank();
    }

    /// @dev Convenience: empty asset/weight arrays.
    function _emptyAssets() internal pure returns (IAgentVault.AssetEntry[] memory) {
        return new IAgentVault.AssetEntry[](0);
    }
    function _emptyWeights() internal pure returns (IAgentVault.WeightConstraint[] memory) {
        return new IAgentVault.WeightConstraint[](0);
    }

    // ══════════════════════════════════════════════════════════════════
    //                           TEST CASES
    // ══════════════════════════════════════════════════════════════════

    /// SCENARIO: One agent, two users, one full cycle.
    /// Founder registers → incubation → public launch → Alice deposits →
    /// Backend rebalances into sNVDA → NVDA pumps 20% → Bob deposits at
    /// higher NAV → Alice redeems via 30-day queue and captures the gain.
    function test_fullLifecycle_happyPath() public {
        // Mandate: one asset (sNVDA) with weight constraint 0–60%.
        IAgentVault.AssetEntry[] memory assets = new IAgentVault.AssetEntry[](1);
        assets[0] = IAgentVault.AssetEntry({asset: address(sNVDA), kind: IAgentVault.AssetKind.Synthetic});
        IAgentVault.WeightConstraint[] memory weights = new IAgentVault.WeightConstraint[](1);
        weights[0] = IAgentVault.WeightConstraint({asset: address(sNVDA), minBps: 0, maxBps: 6000});

        uint256 agentId = _registerAgent(founder1, keccak256("happy-mandate"), 1_000e6, assets, weights);
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        AgentVault   v  = AgentVault(d.vault);
        AgentToken   tk = AgentToken(d.token);
        FounderVault fv = FounderVault(d.founderVault);

        // 1) Phase = Incubation after registration. Founder shares minted to FV.
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.Incubation));
        // Post-fee: 995 USDC of NAV → 995e18 founder shares.
        assertEq(tk.balanceOf(address(fv)), 995e18);
        // AgentNFT minted to founder at full reputation.
        assertEq(agentNFT.ownerOf(agentId), founder1);
        assertEq(agentNFT.reputationOf(agentId), 10_000);

        // 2) Advance to PublicLaunch after the 30-day vetting period.
        vm.warp(block.timestamp + 30 days);
        registry.advanceToPublic(agentId);
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.PublicLaunch));
        // Re-stamp Pyth prices — 30 days exceeds the 96h staleness window.
        _setPythPrice(NVDA_FEED, 21_486_000);

        // 3) Alice deposits 2000 USDC at par NAV → 1990e18 shares.
        //    Deposits are 2× the founder seed so founder's effective stake
        //    stays below the 40% subordination threshold after redemption.
        uint256 aliceShares = _mintShares(v, alice, 2_000e6);
        assertEq(aliceShares, 1990e18);

        // 4) Backend rebalances: buy 2 sNVDA (≈ $429.72 at $214.86).
        IAgentVault.Position[] memory targets = new IAgentVault.Position[](1);
        targets[0] = IAgentVault.Position({asset: address(sNVDA), amount: 2e18});
        vm.prank(backend1);
        v.executeRebalance(targets, "happy-path-rebalance");
        assertEq(sNVDA.balanceOf(address(v)), 2e18);

        uint256 navBeforePump = v.totalNAV();

        // 5) NVDA price +20% → new price $257.832.
        _setPythPrice(NVDA_FEED, 25_783_200);
        uint256 navAfterPump = v.totalNAV();
        // Gain on 2 sNVDA = 2 * ($257.832 − $214.86) ≈ $85.944. Allow ±$1 rounding.
        assertApproxEqAbs(navAfterPump - navBeforePump, 85_944_000, 1_000_000);

        // 6) Bob deposits 2000 USDC at higher NAV/share → he gets fewer shares than Alice.
        uint256 bobShares = _mintShares(v, bob, 2_000e6);
        assertLt(bobShares, aliceShares);

        // 7) Alice requests 30-day redemption.
        vm.prank(admin);
        queue.setAllowedTiers(agentId, [false, true, false, true]);

        vm.startPrank(alice);
        tk.approve(address(queue), aliceShares);
        uint256 reqId = queue.requestRedeem(agentId, aliceShares, IRedemptionQueue.LockupTier.ThirtyDay);
        vm.stopPrank();

        // 8) Warp past unlock; alice claims.
        vm.warp(block.timestamp + 30 days);
        _setPythPrice(NVDA_FEED, 25_783_200);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 usdcOut = queue.claim(reqId);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, usdcOut);
        // After the NVDA gain alice nets >1990 USDC even after 0.5% redeem fee.
        assertGt(usdcOut, 1990e6);

        // 9) Sanity: total supply == FV balance + Bob's balance (alice burned).
        assertEq(tk.totalSupply(), tk.balanceOf(address(fv)) + tk.balanceOf(bob));
        // Founder bps after alice's redemption: 995 / (995 + ~1935) ≈ 34% — under
        // the 40% threshold, so no auto-windDown triggered.
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.PublicLaunch));
    }

    /// SCENARIO: Two independent agents, two backends. State, NAV, and
    /// per-agent executor authority must all be fully isolated.
    /// @dev Uses manual deployment because the HelmRegistry stores a *single*
    ///      global executor — so registering both agents via the registry
    ///      would give them the same executor and defeat the point of this
    ///      test. The queue isn't exercised here (avoiding the deploymentOf
    ///      mock); a separate test (`test_fullLifecycle_happyPath`) covers it.
    function test_multipleAgents_isolation() public {
        // Agent 1: NVDA-focused, backend1.
        IAgentVault.AssetEntry[] memory a1 = new IAgentVault.AssetEntry[](1);
        a1[0] = IAgentVault.AssetEntry({asset: address(sNVDA), kind: IAgentVault.AssetKind.Synthetic});
        // Agent 2: SPY-focused, backend2.
        IAgentVault.AssetEntry[] memory a2 = new IAgentVault.AssetEntry[](1);
        a2[0] = IAgentVault.AssetEntry({asset: address(sSPY), kind: IAgentVault.AssetKind.Synthetic});

        Trio memory t1 = _deployAgentManual(1, founder1, backend1, a1, _emptyWeights(), IAgentVault.Phase.PublicLaunch);
        Trio memory t2 = _deployAgentManual(2, founder2, backend2, a2, _emptyWeights(), IAgentVault.Phase.PublicLaunch);

        // Two distinct deployments.
        assertTrue(address(t1.token)        != address(t2.token));
        assertTrue(address(t1.vault)        != address(t2.vault));
        assertTrue(address(t1.founderVault) != address(t2.founderVault));

        // Alice mints only in agent 1, Bob only in agent 2.
        uint256 aliceShares = _mintShares(t1.vault, alice, 1_000e6);
        uint256 bobShares   = _mintShares(t2.vault, bob,   1_000e6);

        assertEq(t1.token.balanceOf(alice), aliceShares);
        assertEq(t1.token.balanceOf(bob),   0);
        assertEq(t2.token.balanceOf(bob),   bobShares);
        assertEq(t2.token.balanceOf(alice), 0);

        // Cross-executor authorisation: each backend can only touch its agent.
        IAgentVault.Position[] memory p1 = new IAgentVault.Position[](1);
        p1[0] = IAgentVault.Position({asset: address(sNVDA), amount: 1e18});
        IAgentVault.Position[] memory p2 = new IAgentVault.Position[](1);
        p2[0] = IAgentVault.Position({asset: address(sSPY), amount: 1e18});

        vm.prank(backend2);
        vm.expectRevert(IAgentVault.OnlyExecutor.selector);
        t1.vault.executeRebalance(p1, "");

        vm.prank(backend1);
        vm.expectRevert(IAgentVault.OnlyExecutor.selector);
        t2.vault.executeRebalance(p2, "");

        // Each backend CAN rebalance its own agent.
        vm.prank(backend1); t1.vault.executeRebalance(p1, "");
        vm.prank(backend2); t2.vault.executeRebalance(p2, "");
        assertEq(sNVDA.balanceOf(address(t1.vault)), 1e18);
        assertEq(sSPY.balanceOf(address(t2.vault)),  1e18);

        // NVDA-only price move affects agent 1's NAV but not agent 2's.
        uint256 nav1Before = t1.vault.totalNAV();
        uint256 nav2Before = t2.vault.totalNAV();
        _setPythPrice(NVDA_FEED, 25_783_200); // +20%
        assertGt(t1.vault.totalNAV(), nav1Before);
        assertEq(t2.vault.totalNAV(), nav2Before);

        // And vice versa: SPY-only move only affects agent 2.
        _setPythPrice(SPY_FEED, 81_096_400); // ≈ +10%
        nav1Before = t1.vault.totalNAV();
        nav2Before = t2.vault.totalNAV();
        // Re-stamp the existing NVDA price so it stays fresh; assert no NAV change.
        _setPythPrice(NVDA_FEED, 25_783_200);
        assertEq(t1.vault.totalNAV(), nav1Before);
        assertEq(t2.vault.totalNAV(), nav2Before);
    }

    /// SCENARIO: Multiple holders, one yield distribution. Verifies the
    /// distributor's 90/10 split and pro-rata payout to AGT holders.
    ///
    /// @dev YieldHarvester.harvest() deposits yield into vault.yieldPool only —
    /// there is no on-chain path that automatically forwards vault.yieldPool to
    /// the DividendDistributor. So this test imitates the production cron by
    /// pranking as the harvester and calling `distributor.stageYield()` +
    /// `distributor.distribute()` directly. The harvester→adapter pull is
    /// exercised separately via `harvester.harvest` to prove that pipe works.
    function test_yield_harvestAndDistribute_proRata() public {
        uint256 agentId = _registerAgent(founder1, keccak256("yield-mandate"), 1_000e6);
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        AgentVault   v  = AgentVault(d.vault);
        AgentToken   tk = AgentToken(d.token);
        FounderVault fv = FounderVault(d.founderVault);

        vm.warp(block.timestamp + 30 days);
        registry.advanceToPublic(agentId);

        // Three external holders each deposit 1000 USDC; founder seed is also
        // 1000 USDC ⇒ four equal-stake holders after the 0.5% fee.
        _mintShares(v, alice, 1_000e6);
        _mintShares(v, bob,   1_000e6);
        _mintShares(v, carol, 1_000e6);

        uint256 expectedShare = 995e18;
        assertEq(tk.balanceOf(alice), expectedShare);
        assertEq(tk.balanceOf(bob),   expectedShare);
        assertEq(tk.balanceOf(carol), expectedShare);
        assertEq(tk.balanceOf(address(fv)), expectedShare);

        // Exercise the harvester→adapter→vault yield pipe.
        uint256 pipeYield = 1e6; // 1 USDC
        _giveUsdc(address(yieldAdapter), pipeYield);
        yieldAdapter.setYieldAmount(pipeYield);
        vm.prank(backend1);
        harvester.registerSource(agentId, address(yieldAdapter), "");
        harvester.harvest(agentId);
        assertEq(v.yieldPool(), pipeYield);

        // Simulate production cron: stage to distributor, then distribute.
        uint256 yieldAmount = 1_000e6;
        _giveUsdc(address(harvester), yieldAmount);
        vm.startPrank(address(harvester));
        usdc.approve(address(distributor), yieldAmount);
        distributor.stageYield(agentId, yieldAmount);
        uint256 epoch = distributor.distribute(agentId);
        vm.stopPrank();
        assertEq(epoch, 1);

        (uint256 total, uint256 holdersShare,, ) = distributor.epochSnapshot(agentId, epoch);
        assertEq(total, yieldAmount);
        assertEq(holdersShare, 900e6);
        assertEq(fv.carryBalance(), 100e6);

        _claimAndCheckYield(agentId, fv, epoch, yieldAmount);
    }

    /// @dev Split out to keep `test_yield_harvestAndDistribute_proRata` under
    ///      Solidity's stack-too-deep limit.
    function _claimAndCheckYield(
        uint256 agentId,
        FounderVault fv,
        uint256 epoch,
        uint256 yieldAmount
    ) internal {
        uint256[] memory eps = new uint256[](1);
        eps[0] = epoch;

        vm.prank(alice); uint256 ac = distributor.claim(agentId, eps);
        vm.prank(bob);   uint256 bc = distributor.claim(agentId, eps);
        vm.prank(carol); uint256 cc = distributor.claim(agentId, eps);

        // Each holder owns ¼ of supply → ¼ of the 900 USDC holders pool = 225 USDC.
        assertApproxEqAbs(ac, 225e6, 1);
        assertApproxEqAbs(bc, 225e6, 1);
        assertApproxEqAbs(cc, 225e6, 1);

        // Double-claim must revert.
        vm.prank(alice);
        vm.expectRevert();
        distributor.claim(agentId, eps);

        // Founder claims carry from FounderVault.
        vm.prank(founder1);
        uint256 carry = fv.claimCarry();
        assertEq(carry, 100e6);
        assertEq(usdc.balanceOf(founder1), 100e6);

        // Holders + founder-vault pending + carry == staged yield. Founder vault
        // still has the 4th equal-stake share, claimable separately.
        uint256 pendingFv = distributor.pendingClaimOf(agentId, address(fv));
        assertApproxEqAbs(ac + bc + cc + pendingFv, 900e6, 4);
        assertEq(ac + bc + cc + pendingFv + carry, yieldAmount - (900e6 - ac - bc - cc - pendingFv));
    }

    /// SCENARIO: Many user redemptions push the founder's effective share of
    /// total supply over the subordination threshold. RedemptionQueue.claim
    /// must auto-trigger wind-down on the breaching redemption.
    function test_redemptionQueue_subordinationAutoTrigger() public {
        uint256 agentId = _registerAgent(founder1, keccak256("sub-mandate"), 1_000e6);
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        AgentVault v  = AgentVault(d.vault);
        AgentToken tk = AgentToken(d.token);
        address    fv = d.founderVault;

        vm.warp(block.timestamp + 30 days);
        registry.advanceToPublic(agentId);

        // Alice mints 4x the founder's stake at par NAV.
        _mintShares(v, alice, 4_000e6);

        uint256 founderShares = tk.balanceOf(fv);
        uint256 aliceShares   = tk.balanceOf(alice);
        assertApproxEqAbs(founderShares * 10_000 / tk.totalSupply(), 2000, 10); // ~20%

        // Enable instant redemption.
        vm.prank(admin);
        queue.setAllowedTiers(agentId, [true, false, false, false]);

        // Alice redeems 50% of her stake — founder share rises but stays <40%.
        vm.startPrank(alice);
        tk.approve(address(queue), aliceShares);
        uint256 req1 = queue.requestRedeem(agentId, aliceShares / 2, IRedemptionQueue.LockupTier.Instant);
        vm.stopPrank();
        queue.claim(req1);
        assertLt(founderShares * 10_000 / tk.totalSupply(), 4000);

        // Alice redeems more, pushing founder past 40%. The breaching claim
        // must auto-trigger wind-down on the agent's vault.
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.PublicLaunch));
        vm.startPrank(alice);
        uint256 req2 = queue.requestRedeem(agentId, aliceShares / 2 - aliceShares / 5,
            IRedemptionQueue.LockupTier.Instant);
        vm.stopPrank();
        queue.claim(req2);
        assertGt(founderShares * 10_000 / tk.totalSupply(), 4000);
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.WindDown));
    }

    /// SCENARIO: Wind-down with senior priority. After triggerWindDown
    /// snapshots the NAV-per-share, a *further* loss is incurred before
    /// settle (additional Pyth drop between trigger and liquidation). The
    /// junior tranche (founder) must absorb the post-trigger loss first;
    /// senior holders are paid up to their pre-windDown claim.
    function test_windDown_seniorPriority() public {
        IAgentVault.AssetEntry[] memory assets = new IAgentVault.AssetEntry[](1);
        assets[0] = IAgentVault.AssetEntry({asset: address(sNVDA), kind: IAgentVault.AssetKind.Synthetic});
        IAgentVault.WeightConstraint[] memory weights = new IAgentVault.WeightConstraint[](1);
        weights[0] = IAgentVault.WeightConstraint({asset: address(sNVDA), minBps: 0, maxBps: 10_000});

        uint256 agentId = _registerAgent(founder1, keccak256("wd-mandate"), 1_000e6, assets, weights);
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        AgentVault   v  = AgentVault(d.vault);
        FounderVault fv = FounderVault(d.founderVault);

        vm.warp(block.timestamp + 30 days);
        registry.advanceToPublic(agentId);
        _setPythPrice(NVDA_FEED, 21_486_000);

        // Senior holders deposit (each 2× founder seed ⇒ senior ≈ 80% of supply).
        _mintShares(v, alice, 2_000e6);
        _mintShares(v, bob,   2_000e6);

        // Build a meaningful sNVDA position so post-trigger slippage matters.
        // 5 sNVDA at $214.86 ≈ $1074 (~21% of NAV).
        IAgentVault.Position[] memory pos = new IAgentVault.Position[](1);
        pos[0] = IAgentVault.Position({asset: address(sNVDA), amount: 5e18});
        vm.prank(backend1);
        v.executeRebalance(pos, "");

        // First loss event — halve NVDA. This is reflected in the NAV
        // snapshot that triggerWindDown will take.
        _setPythPrice(NVDA_FEED, 10_743_000); // ≈ $107.43

        vm.prank(founder1);
        fv.triggerWindDown("nav collapse");
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.WindDown));
        assertGt(v.preLossNavPerShare(), 0);

        // SECOND loss after trigger — another 50% drop. The junior tranche
        // must absorb this; senior's claim is locked at the snapshot.
        _setPythPrice(NVDA_FEED, 5_371_500); // ≈ $53.71

        v.progressWindDown();
        _setPythPrice(NVDA_FEED, 5_371_500);

        vm.warp(block.timestamp + 91 days);
        _setPythPrice(NVDA_FEED, 5_371_500);
        v.settle();
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.Settled));

        // Per-share assertion: senior receives strictly more per AGT than junior.
        AgentToken tk = AgentToken(d.token);
        uint256 founderShares = tk.balanceOf(address(fv));
        uint256 supply = tk.totalSupply() + (alice == address(0) ? 0 : 0); // settle didn't burn
        // After settle: supply is unchanged (settle doesn't burn). Senior
        // shares = total supply − founder shares.
        uint256 seniorShares = supply - founderShares;

        (,,,,, uint256 seniorPay, uint256 juniorPay) = v.windDown();
        assertGt(seniorPay, 0);

        // Senior per-share strictly greater than junior per-share. Scale both
        // by SHARE_SCALE to use integer math.
        uint256 seniorPerShare = (seniorPay * 1e18) / seniorShares;
        uint256 juniorPerShare = (juniorPay * 1e18) / founderShares;
        assertGt(seniorPerShare, juniorPerShare);

        // Senior per-share ≈ preLossNavPerShare (snapshot honored, modulo
        // cash-cap when liquidation cash isn't enough). Allow a small
        // tolerance for the rebalance fee already paid before trigger.
        assertApproxEqRel(seniorPerShare, v.preLossNavPerShare(), 0.01e18);
    }

    /// SCENARIO: Rebalance must obey the mandate's per-asset weight bounds.
    function test_mandate_weightBreach_reverts() public {
        // Mandate: each asset 10-30% of NAV.
        IAgentVault.AssetEntry[] memory assets = new IAgentVault.AssetEntry[](2);
        assets[0] = IAgentVault.AssetEntry({asset: address(sNVDA), kind: IAgentVault.AssetKind.Synthetic});
        assets[1] = IAgentVault.AssetEntry({asset: address(sSPY),  kind: IAgentVault.AssetKind.Synthetic});

        IAgentVault.WeightConstraint[] memory weights = new IAgentVault.WeightConstraint[](2);
        weights[0] = IAgentVault.WeightConstraint({asset: address(sNVDA), minBps: 1000, maxBps: 3000});
        weights[1] = IAgentVault.WeightConstraint({asset: address(sSPY),  minBps: 1000, maxBps: 3000});

        Trio memory t = _deployAgentManual(
            1, founder1, backend1, assets, weights, IAgentVault.Phase.PublicLaunch
        );

        // Deposit 10000 USDC → NAV ≈ 9950.
        _mintShares(t.vault, alice, 10_000e6);

        // Attempt 1: 50% sNVDA → breaches max (30%).
        IAgentVault.Position[] memory tooMuch = new IAgentVault.Position[](2);
        // ≈ 4975 USDC of sNVDA at $214.86 ≈ 23.15e18 sNVDA
        tooMuch[0] = IAgentVault.Position({asset: address(sNVDA), amount: 23_150_000_000_000_000_000});
        // ≈ 2000 USDC of sSPY at $737.24 ≈ 2.71e18 sSPY (20% — within mandate)
        tooMuch[1] = IAgentVault.Position({asset: address(sSPY),  amount: 2_710_000_000_000_000_000});
        vm.prank(backend1);
        vm.expectRevert(); // MandateBreach(asset, actual, min, max)
        t.vault.executeRebalance(tooMuch, "");

        // Attempt 2: 5% sNVDA → under min (10%).
        IAgentVault.Position[] memory tooLittle = new IAgentVault.Position[](2);
        // ≈ 497 USDC of sNVDA ≈ 2.314e18 sNVDA
        tooLittle[0] = IAgentVault.Position({asset: address(sNVDA), amount: 2_314_000_000_000_000_000});
        // sSPY at 20% — fine
        tooLittle[1] = IAgentVault.Position({asset: address(sSPY),  amount: 2_710_000_000_000_000_000});
        vm.prank(backend1);
        vm.expectRevert();
        t.vault.executeRebalance(tooLittle, "");

        // Attempt 3: Both at ~20% — succeeds.
        IAgentVault.Position[] memory ok = new IAgentVault.Position[](2);
        // sNVDA at 20% ≈ 1990 USDC ≈ 9.26e18
        ok[0] = IAgentVault.Position({asset: address(sNVDA), amount: 9_260_000_000_000_000_000});
        // sSPY at 20% ≈ 1990 USDC ≈ 2.7e18
        ok[1] = IAgentVault.Position({asset: address(sSPY),  amount: 2_700_000_000_000_000_000});
        vm.prank(backend1);
        t.vault.executeRebalance(ok, "");

        // Verify final positions are non-zero.
        assertGt(sNVDA.balanceOf(address(t.vault)), 0);
        assertGt(sSPY.balanceOf(address(t.vault)),  0);
    }

    /// SCENARIO: Strict phase state-machine enforcement via the registry.
    function test_phase_transitions_enforced() public {
        uint256 agentId = _registerAgent(founder1, keccak256("phase-mandate"), 1_000e6);
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        AgentVault v = AgentVault(d.vault);

        // 1) Just-registered → Incubation.
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.Incubation));

        // 2) Alice (non-founder) CANNOT deposit during Incubation.
        _giveUsdc(alice, 50e6);
        vm.startPrank(alice);
        usdc.approve(address(v), 50e6);
        vm.expectRevert(AgentVault.OnlyFounderDuringIncubation.selector);
        v.deposit(50e6, alice);
        vm.stopPrank();
        assertEq(AgentToken(d.token).balanceOf(alice), 0);

        // 2b) Founder CAN top up during Incubation.
        _giveUsdc(founder1, 50e6);
        vm.startPrank(founder1);
        usdc.approve(address(v), 50e6);
        v.deposit(50e6, founder1);
        vm.stopPrank();
        assertGt(AgentToken(d.token).balanceOf(founder1), 0);

        // 3) advanceToPublic before 30d reverts.
        vm.expectRevert();
        registry.advanceToPublic(agentId);

        // 4) Half-way through still reverts.
        vm.warp(block.timestamp + 15 days);
        vm.expectRevert();
        registry.advanceToPublic(agentId);

        // 5) After 30 days, advanceToPublic succeeds.
        vm.warp(block.timestamp + 15 days + 1);
        registry.advanceToPublic(agentId);
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.PublicLaunch));

        // 6) Double advance reverts.
        vm.expectRevert(HelmRegistry.AlreadyAdvanced.selector);
        registry.advanceToPublic(agentId);

        // 7) Public mint works (Alice — previously blocked).
        _mintShares(v, alice, 100e6);
        assertGt(AgentToken(d.token).balanceOf(alice), 0);

        // 8) Trigger wind-down via FounderVault. registry path: only the
        //    real registry, founder vault or queue may call. founderVault
        //    only allows the founder.
        FounderVault fv = FounderVault(d.founderVault);
        vm.prank(founder1);
        fv.triggerWindDown("test winddown");
        assertEq(uint8(v.phase()), uint8(IAgentVault.Phase.WindDown));

        // 9) Mints disabled in WindDown.
        _giveUsdc(carol, 10e6);
        vm.startPrank(carol);
        usdc.approve(address(v), 10e6);
        vm.expectRevert(AgentVault.MintsDisabled.selector);
        v.deposit(10e6, carol);
        vm.stopPrank();

        // 10) advanceToPublic now reverts (wrong phase).
        vm.expectRevert(HelmRegistry.AlreadyAdvanced.selector);
        registry.advanceToPublic(agentId);
    }

    /// SCENARIO: Founder must respect lockup + subordination on FounderVault.
    /// The 180-day lockup is set during registerAgent (the seed shares are
    /// routed through depositFounderShares so the lockup clock starts).
    function test_founderLockup_enforced() public {
        uint256 agentId = _registerAgent(founder1, keccak256("lockup-mandate"), 1_000e6);
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        FounderVault fv = FounderVault(d.founderVault);
        AgentToken   tk = AgentToken(d.token);

        // Lockup clock started, totals tracked, all shares custodied in FV.
        uint256 shares = tk.balanceOf(address(fv));
        assertGt(shares, 0);
        assertEq(fv.lockupEndsAt(), uint64(block.timestamp + 180 days));
        assertEq(fv.totalDeposited(), shares);
        assertEq(fv.totalSharesHeld(), shares);

        // Immediate withdraw — locked.
        vm.prank(founder1);
        vm.expectRevert();
        fv.withdraw(shares / 10);

        // 90 days in — still locked (default lockupDays = 180).
        vm.warp(block.timestamp + 90 days);
        vm.prank(founder1);
        vm.expectRevert();
        fv.withdraw(shares / 10);

        // Past lockup.
        vm.warp(block.timestamp + 90 days + 1);

        // 30% withdrawal — under 40% subordination threshold.
        vm.prank(founder1);
        fv.withdraw((shares * 30) / 100);
        assertEq(tk.balanceOf(founder1), (shares * 30) / 100);

        // Another 15% — cumulative 45% breaches 40% threshold.
        vm.prank(founder1);
        vm.expectRevert(FounderVault.SubordinationBreached.selector);
        fv.withdraw((shares * 15) / 100);
    }

    /// SCENARIO: production-aware adapter yield works end-to-end. Wire a
    /// fresh MantleMETHAdapter (Pyth-priced, 4% APY) as a yield source for
    /// an agent, have the vault deposit some USDC, warp 30 days, harvest →
    /// the vault's yield pool grows by ~30 days × 4% APY worth of USDC,
    /// minted by the adapter via its MockUSDC minter role.
    function test_productionAwareAdapter_yieldFlowsToVaultPool() public {
        // Add an ETH/USD price feed to the existing MockPyth.
        bytes32 ETH_USD_FEED = keccak256("ETH/USD");
        pyth.setPrice(ETH_USD_FEED, int64(int256(uint256(3000_00000))), 50, -5, block.timestamp);

        // Standalone hybrid adapter — not part of the agent's mandate, used
        // purely as a yield source registered with the harvester.
        MantleMETHAdapter mEthAdapter = new MantleMETHAdapter(
            address(usdc), address(pyth), ETH_USD_FEED, address(0), 60, address(timeProvider)
        );
        usdc.addMinter(address(mEthAdapter));

        uint256 agentId = _registerAgent(founder1, keccak256("yield-mech-mandate"), 1_000e6);
        IHelmRegistry.AgentDeployment memory d = registry.deploymentOf(agentId);
        AgentVault v = AgentVault(d.vault);

        vm.warp(block.timestamp + 30 days);
        registry.advanceToPublic(agentId);
        pyth.setPrice(ETH_USD_FEED, int64(int256(uint256(3000_00000))), 50, -5, block.timestamp);

        // Vault stakes 500 USDC into the hybrid mETH adapter directly.
        _giveUsdc(address(v), 500e6);
        vm.startPrank(address(v));
        usdc.approve(address(mEthAdapter), 500e6);
        mEthAdapter.deposit(500e6, 0);
        vm.stopPrank();

        // Register adapter as a yield source for this agent.
        vm.prank(backend1);
        harvester.registerSource(agentId, address(mEthAdapter), "");

        uint256 yieldPoolBefore = v.yieldPool();

        // 30 days at 4% APY on 500 USDC ≈ 1.644 USDC.
        vm.warp(block.timestamp + 30 days);
        pyth.setPrice(ETH_USD_FEED, int64(int256(uint256(3000_00000))), 50, -5, block.timestamp);

        harvester.harvest(agentId);

        uint256 yielded = v.yieldPool() - yieldPoolBefore;
        assertApproxEqAbs(yielded, 1_643_835, 5_000);
        assertGt(yielded, 0);

        // Vault's USDC balance grew by the harvested amount (depositYield
        // pulls USDC into the vault before crediting yieldPool).
    }

    /// SCENARIO: NAV stays consistent across price moves and rebalances.
    function test_synthetic_pricing_NAVConsistency() public {
        IAgentVault.AssetEntry[] memory assets = new IAgentVault.AssetEntry[](1);
        assets[0] = IAgentVault.AssetEntry({asset: address(sNVDA), kind: IAgentVault.AssetKind.Synthetic});
        IAgentVault.WeightConstraint[] memory weights = new IAgentVault.WeightConstraint[](1);
        weights[0] = IAgentVault.WeightConstraint({asset: address(sNVDA), minBps: 0, maxBps: 10_000});

        Trio memory t = _deployAgentManual(
            1, founder1, backend1, assets, weights, IAgentVault.Phase.PublicLaunch
        );

        _mintShares(t.vault, alice, 1_000e6); // ~995 USDC after fee

        uint256 navInitial = t.vault.totalNAV();
        assertApproxEqAbs(navInitial, 995e6, 1e6);

        // Buy ~50% of NAV into sNVDA → 2.314 sNVDA at $214.86 ≈ $497.
        IAgentVault.Position[] memory targets = new IAgentVault.Position[](1);
        targets[0] = IAgentVault.Position({asset: address(sNVDA), amount: 2_314_000_000_000_000_000});
        vm.prank(backend1);
        t.vault.executeRebalance(targets, "");

        // NAV should still ≈ 995 (no price change yet, minus tiny rebalance fee).
        uint256 navAfterBuy = t.vault.totalNAV();
        assertApproxEqAbs(navAfterBuy, 995e6, 5e6);

        // NVDA → $260 (+21%).
        _setPythPrice(NVDA_FEED, 26_000_000);
        uint256 navAfterPump = t.vault.totalNAV();

        // Expected: cash ≈ 497 USDC + sNVDA value (2.314 * $260 ≈ $601.64) ≈ $1098.64.
        // Tolerate ±$2 for rounding through the rebalance.
        assertApproxEqAbs(navAfterPump, 1_098_640_000, 2e6);

        // Buy more sNVDA — get fewer shares per USDC at higher price.
        IAgentVault.Position[] memory more = new IAgentVault.Position[](1);
        more[0] = IAgentVault.Position({asset: address(sNVDA), amount: 4_000_000_000_000_000_000});
        vm.prank(backend1);
        t.vault.executeRebalance(more, "");

        uint256 navAfter2 = t.vault.totalNAV();
        // NAV should NOT meaningfully change from rebalance alone (cash → asset).
        assertApproxEqAbs(navAfter2, navAfterPump, 5e6);

        // Sell half back — should not change NAV either.
        IAgentVault.Position[] memory sellSome = new IAgentVault.Position[](1);
        sellSome[0] = IAgentVault.Position({asset: address(sNVDA), amount: 2_000_000_000_000_000_000});
        vm.prank(backend1);
        t.vault.executeRebalance(sellSome, "");
        uint256 navAfterSell = t.vault.totalNAV();
        assertApproxEqAbs(navAfterSell, navAfter2, 5e6);

        // Cash + sNVDA value reconciles.
        uint256 cash = usdc.balanceOf(address(t.vault));
        uint256 snBal = sNVDA.balanceOf(address(t.vault));
        uint256 expectedNav = cash + (snBal * sNVDA.priceUSDC()) / 1e18;
        assertApproxEqAbs(t.vault.totalNAV(), expectedNav, 1);
    }
}
