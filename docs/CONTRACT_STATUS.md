# Helm — Smart Contract Implementation Status

> **Single source of truth** for the Helm smart-contract layer (REIT-model AI Agent ETF on Mantle).
> Generated 2026-05-18. Branch: `fix/upload-mime-validation`. All paths relative to `contracts/`.

---

## Executive Summary

- ✅ **17 production contracts + 1 mock** implemented across 5 layers (core / system / yield / adapters / interfaces). 27 Solidity files in `src/`, plus mocks/tests.
- ✅ **208 / 208 Foundry tests passing** (16 suites, including a 10-test end-to-end integration suite covering the full lifecycle, wind-down senior priority, yield→dividend pro-rata, and subordination auto-trigger).
- ✅ **Anvil (chainId 31337) deployment is current** — includes `TimeProvider`, `AgentNFT`, and the production-aware adapter set. **Mantle Sepolia (5003) deployment is stale** (missing `timeProvider` + `agentNFT`); redeploy is the top pending item.
- ✅ **Production-aware design** — adapters reference real Mantle/Ondo addresses, simulate APY only where mainnet liquidity is unavailable, and gate testnet-only `mint` paths behind `chainId == 5003 || 31337` so a misconfigured mainnet deployment cannot print value.
- 🟡 **Pending for hackathon submission**: (1) redeploy to Mantle Sepolia, (2) verify 19 contracts on Mantle Explorer, (3) ship FE/BE integration package. AI-on-chain function (`executeRebalance` from BE executor) is wired but needs the BE caller; FE/demo video are out of contracts scope.

---

## 1. Implemented Contracts

### 1.1 Core layer — `src/core/`

| Contract | File | LOC | Standard | Property |
|---|---|---|---|---|
| **AgentToken** | [src/core/AgentToken.sol](../src/core/AgentToken.sol) | 54 | ERC-20 (Upgradeable) | Clone, Initializable, no time, no Pyth |
| **AgentVault** | [src/core/AgentVault.sol](../src/core/AgentVault.sol) | 675 | ERC-4626 facade | Clone, Initializable, **time-dependent**, **Pyth-dependent (via assets)** |
| **FounderVault** | [src/core/FounderVault.sol](../src/core/FounderVault.sol) | 203 | Standalone custody | Clone, Initializable, **time-dependent**, no Pyth |

#### AgentToken — share token for one agent

- **Inheritance**: `ERC20Upgradeable`, `IAgentToken`.
- **Mint/burn**: only the linked `vault` (set during {initialize}).
- **State**: `vault`, `agentId`.
- **Public interface**: `initialize(name, symbol, vault, agentId)`, `mint(to, amount)`, `burn(from, amount)`.
- Constructor calls `_disableInitializers()` so only clones run.

#### AgentVault — ERC-4626-shaped vault

- **Inheritance**: `IAgentVault`, `Initializable`, `ReentrancyGuard`.
- **Dependencies**: `IAgentToken`, `IFounderVault`, `IPlatformTreasury`, `ISyntheticAsset`, `IMantleMETHAdapter`, `IOndoUSDYAdapter`, `ITimeProvider`.
- **Key state**: `phase` (Incubation / PublicLaunch / WindDown / Settled), `yieldPool`, `_assets[]`, `_weightOf`, `windDown` struct (active, settled, triggeredAt, seniorWindowEnd, claimable USDC), `preLossNavPerShare`, `_liquidationCursor`.
- **Public interface**:
  - **ERC-4626 facade** (read-only via `agentToken`): `name/symbol/decimals/totalSupply/balanceOf`. Writes (`transfer/transferFrom/approve`) revert `TransfersDisabled`.
  - **Mint path**: `deposit(assets, receiver)`, `mint(shares, receiver)` — gated by `mintsAllowed` (Incubation founder-only, PublicLaunch open, no-mints during WindDown).
  - **Redeem path**: standard `withdraw/redeem` revert (`ERC4626RedeemDisabled`); real path is `fulfillRedemption(holder, shares)` callable only by `RedemptionQueue`.
  - **Yield**: `depositYield(amount)` callable only by `yieldHarvester`.
  - **Rebalance**: `executeRebalance(targets, strategyProof)` callable only by `executor` (BE signer). Enforces mandate weight bounds — breach reverts the whole call.
  - **Lifecycle**: `enterPublicLaunch()` (registry-only), `triggerWindDown(reason)` (founderVault / registry / queue), `progressWindDown()` (anyone — iterative liquidation), `settle()` (anyone — after senior window).
  - **Views**: `totalNAV()`, `cashUSDC()`, `convertToShares/Assets`, `previewDeposit/Mint`, `assetCount`, `assetAt(i)`, `weightConstraintOf(asset)`.
- **NAV model**: cash USDC + Σ position × price. Synthetic price comes from `priceUSDC()`, mETH and USDY from adapter `valueInUSDC(holder)`.
- **Wind-down**: snapshots `preLossNavPerShare` at trigger time → senior tranche claim is locked in pre-loss; junior absorbs losses incurred during liquidation.

#### FounderVault — founder shares custody + dev carry payout

- **Inheritance**: `IFounderVault`, `Initializable`, `ReentrancyGuard`.
- **Hard constraints** (revert in `initialize`):
  - `carryBps != 1000` (10% protocol-locked).
  - `founderShareBps ∉ [500, 3000]` (5–30%).
  - `lockupDays < 90`.
- **State**: `totalDeposited`, `totalWithdrawn`, `totalSharesHeld`, `carryBalance`, `lockupEndsAt`, `subordinationThresholdBps`, `founderShareBps`.
- **Public interface**:
  - `depositFounderShares(amount)` — anyone may deposit; sets `lockupEndsAt = now + lockupDays·days` on first deposit.
  - `withdraw(amount)` — `onlyFounder`, lockup-gated, subordination-checked (cumulative withdrawn ratio ≤ threshold).
  - `receiveCarry(amount)` — `onlyDistributor`; USDC pulled in.
  - `claimCarry()` — `onlyFounder`; drains `carryBalance`.
  - `triggerWindDown(reason)` — founder-driven wind-down on vault.
  - Views: `isSubordinationActive()`, `cumulativeWithdrawnBps()`.

### 1.2 System layer — `src/system/`

| Contract | File | LOC | Property |
|---|---|---|---|
| **AgentNFT** | [src/system/AgentNFT.sol](../src/system/AgentNFT.sol) | 156 | Singleton ERC-721, ERC-8004 compatible |
| **HelmRegistry** | [src/system/HelmRegistry.sol](../src/system/HelmRegistry.sol) | 374 | Singleton factory (EIP-1167 Clones), time-dependent |
| **PlatformTreasury** | [src/system/PlatformTreasury.sol](../src/system/PlatformTreasury.sol) | 121 | Singleton, no time, no Pyth |
| **RedemptionQueue** | [src/system/RedemptionQueue.sol](../src/system/RedemptionQueue.sol) | 239 | Singleton, time-dependent |
| **TimeProvider** | [src/system/TimeProvider.sol](../src/system/TimeProvider.sol) | 71 | Singleton, chainId-gated dev fast-forward |

#### AgentNFT — singleton ERC-721 identity + reputation

- **Inheritance**: `ERC721`.
- **Identity**: `tokenId == agentId` from registry, name `"Helm Agent Identity"` / symbol `HELM-AGENT`.
- **Reputation**: `reputationScore[agentId]` in basis points, starts at `MAX_BPS = 10000`.
- **Slash mechanism**: `slash(agentId, amountBps, reason)` — saturates at 0, increments `slashCount`, sets `lastSlashAt`, emits `ReputationSlashed`. If score crosses below `windDownThreshold` (default 5000 bps), emits `SlashTriggeredWindDown` (BE indexer reacts).
- **Auth**: `mint` is registry-only; `slash` and `setTokenURI` are registry-or-admin.
- **Views**: `reputationOf`, `isHealthy`, `slashInfoOf`, `tokenURI`.
- **NFT transferable** — reputation transfers with it.

#### HelmRegistry — factory + lifecycle controller

- **Inheritance**: `IHelmRegistry`.
- **Hard constants**: `MIN_SEED_USDC = 1000e6`, `INCUBATION_PERIOD = 30 days`.
- **Clone implementations** (immutable): `agentTokenImpl`, `agentVaultImpl`, `founderVaultImpl`. Each agent registration mints three EIP-1167 minimal-proxy clones.
- **Singletons held** (immutable): `agentNFT`, `timeProvider`, `usdc`, `redemptionQueue`, `treasury`, `yieldHarvester`, `pythAdapter`, `executor`, `distributor`.
- **Public interface**:
  - `registerAgent(mandateHash, mandateURI, seedUSDC, assets, weightConstraints)` — pulls seed USDC, deploys trio, deposits seed → mints founder shares → routes into FounderVault, mints AgentNFT to founder. Rejects duplicate mandate hashes.
  - `advanceToPublic(agentId)` — incubation period must have elapsed (uses TimeProvider).
  - `slash(agentId, reason)` — admin only; marks `Phase.Slashed`.
  - `markWindDown(agentId)` — `onlyVault`; sets `Phase.WindDown` and slashes the NFT by 2000 bps with reason `"wind_down"`.
  - `notifyMandateBreach(agentId, reason)` — `onlyVault`; slashes NFT by 1000 bps. Invoked by BE indexer relaying a reverted-rebalance signal.
  - `markSettled(agentId)` — `onlyVault`; final phase.
  - Views: `deploymentOf(agentId)`, `phaseOf(agentId)`, `agentCount()`.
- **Default mandate params**: `defaultLockupDays = 180`, `defaultSubordinationBps = 4000`, `defaultFounderShareBps = 2000` (set on deployment, see Deploy.s.sol).

#### PlatformTreasury — singleton fee sink

- **Inheritance**: `IPlatformTreasury`.
- **Defaults**: Mint 50 bps (0.5%), Redeem 50 bps (0.5%), Rebalance 5 bps (0.05%). Per-kind max 1000 bps (10%).
- **Public interface**: `collectFee(agentId, kind, amount)` (vault pushes USDC then calls), `withdraw(to, amount)` (admin), `setFeeRate(kind, newBps)` (admin), `setFeeRates(mint, redeem, rebalance)` (batch). Views: `feeRate(kind)`, `feeRates()`, `feesCollectedFor(agentId)`, `totalFeesCollected`.

#### RedemptionQueue — singleton lockup queue (0/30/60/90 days)

- **Inheritance**: `IRedemptionQueue`, `ReentrancyGuard`.
- **Lockup tiers**: `TIER_DAYS = [0, 30, 60, 90]` keyed by `LockupTier` enum (Instant / ThirtyDay / SixtyDay / NinetyDay). Per-agent allowance via `tierAllowed[agentId][tier]`, set by admin via `setAllowedTiers(agentId, [bool,bool,bool,bool])`.
- **Public interface**:
  - `requestRedeem(agentId, shares, tier)` — pulls AGT into custody, records `unlockAt = now + days·tier`.
  - `claim(requestId)` — calls back into vault's `fulfillRedemption`, forwards USDC to holder, then runs subordination check: if founder's share of remaining supply ≥ `subordinationThresholdBps`, auto-triggers `vault.triggerWindDown("subordination_breach_via_redemption")`.
  - `cancel(requestId)` — refunds shares; must be > 1 day before unlock.
  - Views: `requestOf`, `pendingRequestsOf(holder)`, `pendingForAgent(agentId)`, public `vaultOf`/`tokenOf`/`founderVaultOf` caches.

#### TimeProvider — singleton clock with dev fast-forward

- **Inheritance**: `ITimeProvider`.
- **Spec**: `currentTime() = block.timestamp + timeOffset`. `devEnabled = (chainid == 5003 || 31337)` frozen at construction.
- **Public interface**: `advance(seconds)` (admin + dev-enabled), `reset()` (admin + dev-enabled), `transferAdmin(newAdmin)`.
- **Rationale**: every time-dependent contract (Vault wind-down windows, FounderVault lockup, RedemptionQueue, YieldHarvester, DividendDistributor, both adapters) reads `currentTime()` so a single admin action fast-forwards the entire system for demos. Mainnet deployments freeze the offset at 0 forever.

### 1.3 Yield layer — `src/yield/`

| Contract | File | LOC | Property |
|---|---|---|---|
| **YieldHarvester** | [src/yield/YieldHarvester.sol](../src/yield/YieldHarvester.sol) | 126 | Singleton, time-dependent |
| **DividendDistributor** | [src/yield/DividendDistributor.sol](../src/yield/DividendDistributor.sol) | 181 | Singleton, time-dependent |

#### YieldHarvester

- Per-agent registry of yield sources (adapters). `executor`-only `registerSource`/`removeSource`. `harvest(agentId)` loops over registered sources, low-level-calls `harvestYield(vault)`, sums USDC, deposits into vault's `yieldPool` via `depositYield`. Records `_lastHarvest[agentId]`.
- Views: `lastHarvestAt(agentId)`, `sourcesOf(agentId)`.

#### DividendDistributor

- Per-agent epochs. `stageYield(agentId, amount)` (harvester-only) → `distribute(agentId)` (harvester-only) splits **90% holders / 10% founder carry**.
- Each epoch snapshots `totalSharesAtSnapshot = AGT.totalSupply()`; holders call `claim(agentId, epochs[])` to pull pro-rata.
- Carry path: `forceApprove` + `IFounderVault.receiveCarry(carry)` — the 10% is pulled into FounderVault as USDC, founder claims via `claimCarry()`.
- **Open caveat** (acknowledged in NatSpec): MVP uses live `balanceOf` at claim — production would snapshot via `ERC20Votes` checkpointing to prevent front-running. Marked `// TODO(human)`.

### 1.4 Adapters — `src/adapters/`

| Contract | File | LOC | Production-aware | Pyth | Property |
|---|---|---|---|---|---|
| **PythPriceAdapter** | [src/adapters/PythPriceAdapter.sol](../src/adapters/PythPriceAdapter.sol) | 117 | Real Pyth wrapper | ✅ | Singleton, no time |
| **SyntheticAsset** | [src/adapters/SyntheticAsset.sol](../src/adapters/SyntheticAsset.sol) | 179 | Real (Pyth-priced) | ✅ | Singleton-per-asset, no time |
| **MantleMETHAdapter** | [src/adapters/MantleMETHAdapter.sol](../src/adapters/MantleMETHAdapter.sol) | 289 | **Hybrid** (real ETH/USD oracle + simulated stake yield) | ✅ (ETH/USD) | Singleton, time-dependent |
| **OndoUSDYAdapter** | [src/adapters/OndoUSDYAdapter.sol](../src/adapters/OndoUSDYAdapter.sol) | 212 | **Production-aware mock** (real USDY/oracle addresses, simulated price growth) | ❌ | Singleton, time-dependent |

#### PythPriceAdapter

- Wraps `IPyth` with per-feed staleness (`maxStaleness[feedId]`). Crypto feeds use 60s, equity feeds use 96h.
- Public interface: `getPrice(feedId)` (returns price/decimals/publishTime normalized to 18 dec), `getPriceUsdc(feedId)` (normalized to 6 dec, USDC scale), `getPriceWithMaxAge(feedId, maxAge)`, `updatePriceFeeds(updateData)` payable, `getUpdateFee`.
- Errors: `UnknownFeed`, `PriceNegative`, `PriceStale`.

#### SyntheticAsset (per-asset clone)

- 18-dec non-transferable ERC-20. `mint(to, usdcCollateral)` / `burn(from, syntheticIn)` callable only by registered agent vaults (`registerVault(vault)` is admin-only).
- USDC locked on mint, released on burn at current `priceUSDC()` from PythPriceAdapter.
- Five instances deployed: sNVDA, sSPY, sAAPL, sTSLA, sMSFT. Pyth feed IDs hardcoded in Deploy.s.sol.

#### MantleMETHAdapter — hybrid integration

- **Production-aware addresses** (constants):
  - `MANTLE_METH_MAINNET = 0xcDA86A272531e8640cD7F1a92c01839911B90bb0` — Ethereum L1 mETH (Mantle Staking).
  - `MANTLE_SEPOLIA_METH = 0x9EF6f9160Ba00B6621e5CB3217BB8b54a92B2828` — Sepolia mETH proxy (real-token reference).
- **Hybrid design**: uses **real Pyth ETH/USD** for USDC ↔ mETH pricing; simulates the mETH/ETH exchange-rate growth at 4% APY (`SIMULATED_APY_BPS = 400`) because Mantle Sepolia has no DEX liquidity to perform the real swap path. The global `mEthEthRatio` grows continuously via `_accrueGlobalYield()`.
- **Per-vault state**: `vaultMethBalance[vault]`, `vaultLastRatio[vault]`, `_pendingYield[vault]`. Yield-accrual delta = balance × (ratio_now − ratio_lastTouch) × ETH/USD price.
- **Public interface**: `deposit(usdcAmount, minMEthOut)`, `withdraw(mEthAmount, minUsdcOut)`, `harvestYield(holder)`, views `balanceOfHolder`, `valueInUSDC`, `exchangeRate`, `pendingYieldOf`, `productionMethAddress()`.
- **MockUSDC mint backstop**: on testnet, `harvestYield` mints the realised USDC yield from MockERC20; chainId-gated inside MockERC20 to no-op on production.

#### OndoUSDYAdapter — production-aware mock

- **Production-aware addresses** (constants):
  - `ONDO_USDY_MAINNET = 0x5bE26527e817998A7206475496fDE1E68957c5A6` — Mantle Mainnet USDY.
  - `ONDO_USDY_ORACLE_MAINNET = 0xA96abbe61AfEdEB0D14a20440Ae7100D9aB4882f` — Ondo's `RWADynamicRateOracle`.
- USDY is regulated and not present on Sepolia, so the testnet adapter simulates the `usdyPricePerShare` growing at 5% APY (`SIMULATED_APY_BPS = 500`).
- **Public interface**: `deposit(usdcAmount, minUsdyOut)`, `redeem(usdyAmount, minUsdcOut)`, `harvestYield(holder)`, views `balanceOfHolder`, `valueInUSDC`, `exchangeRate`, `pendingYieldOf`, `productionUsdyAddress()`, `productionOracleAddress()`.
- **MockUSDC mint backstop**: same chainId-gated pattern as mETH adapter.

### 1.5 Interfaces — `src/interfaces/`

| Interface | LOC | Notes |
|---|---|---|
| IAgentNFT | 52 | mint/slash/reputation |
| IAgentToken | 39 | vault-gated mint/burn |
| IAgentVault | 123 | extends IERC4626, full lifecycle |
| IDividendDistributor | 39 | distribute/claim |
| IFounderVault | 71 | shares + carry + lockup |
| IHelmRegistry | 70 | registerAgent + phase machine |
| IMantleMETHAdapter | 28 | deposit/withdraw/harvest |
| IOndoUSDYAdapter | 23 | deposit/redeem/harvest |
| IPlatformTreasury | 34 | fees + admin |
| IPythPriceAdapter | 34 | getPrice/getPriceUsdc/update |
| IRedemptionQueue | 60 | request/claim/cancel + tiers |
| ISyntheticAsset | 31 | mint/burn + priceUSDC |
| ITimeProvider | 12 | currentTime |
| IYieldHarvester | 32 | harvest + sources |

### 1.6 Mocks — `test/mocks/`

| Mock | Purpose |
|---|---|
| MockERC20 | Testnet USDC with chainId-gated `mint`; `minterAdmin` + `minters[]` two-tier auth |
| MockPyth | Cans price/expo/publishTime for unit tests |
| MockAgentVault | Stub vault used in queue/distributor isolation tests |
| MockHelmRegistry | Stub registry used in distributor/queue tests |
| MockPlatformTreasury | Stub for vault fee-payment paths |
| MockYieldAdapter | Stub adapter for harvester tests |

---

## 2. Tests

### 2.1 Summary

| Metric | Value |
|---|---|
| Total tests | **208** |
| Suites | **16** |
| Pass / Fail / Skip | **208 / 0 / 0** |
| Last run | `forge test` on 2026-05-18, branch `fix/upload-mime-validation` |

### 2.2 Per-contract coverage

| Implementation | Test file | Count | Coverage areas |
|---|---|---|---|
| AgentToken | [test/AgentTokenTest.t.sol](../test/AgentTokenTest.t.sol) | 9 | initialize, mint/burn auth, transfer behaviour, agentId binding |
| AgentVault | [test/AgentVaultTest.t.sol](../test/AgentVaultTest.t.sol) | 16 | deposit at par / at NAV change, redeem profit + loss, wind-down senior priority, mandate breach revert, executor-only rebalance, stale-price revert, ERC4626 redeem/withdraw disabled, settle |
| AgentNFT | [test/AgentNFTTest.t.sol](../test/AgentNFTTest.t.sol) | 22 | constructor, mint by registry / non-registry / twice, slash auth + saturation + accumulation, threshold crossing, setTokenURI, transferAdmin, reputation transfer with NFT |
| FounderVault | [test/FounderVaultTest.t.sol](../test/FounderVaultTest.t.sol) | 18 | deposit/withdraw, lockup enforced, subordination threshold revert, carry receipt and claim, invalid lockupDays/founderShareBps/carryBps reverts |
| HelmRegistry | [test/HelmRegistryTest.t.sol](../test/HelmRegistryTest.t.sol) | 14 | registerAgent happy + dup mandate + zero hash + empty URI + insufficient seed reverts, advanceToPublic (before/after 30d / twice), markWindDown/markSettled auth, slash by admin, multiple agents, unknown agent revert |
| PlatformTreasury | [test/PlatformTreasuryTest.t.sol](../test/PlatformTreasuryTest.t.sol) | 10 | constructor defaults, collectFee, withdraw admin, fee-rate updates + max-bps cap, batch setFeeRates, view tuples |
| RedemptionQueue | [test/RedemptionQueueTest.t.sol](../test/RedemptionQueueTest.t.sol) | 10 | tier gating, requestRedeem custody, claim NAV settlement, cancel + cancel-window, subordination auto-trigger, pendingRequestsOf, pendingForAgent |
| TimeProvider | [test/TimeProviderTest.t.sol](../test/TimeProviderTest.t.sol) | 13 | advance/reset auth, dev-enabled chain gating (mainnet revert), offset arithmetic, transferAdmin, multi-step fast-forward |
| YieldHarvester | [test/YieldHarvesterTest.t.sol](../test/YieldHarvesterTest.t.sol) | 7 | registerSource auth, harvest from multiple sources, depositYield into vault pool, removeSource bookkeeping |
| DividendDistributor | [test/DividendDistributorTest.t.sol](../test/DividendDistributorTest.t.sol) | 10 | 90/10 split, stage-then-distribute, pro-rata claim, double-claim revert, empty pool revert, pending claim view |
| PythPriceAdapter | [test/PythPriceAdapterTest.t.sol](../test/PythPriceAdapterTest.t.sol) | 21 | feed staleness (crypto vs equity), negative expo (–5, –8), positive expo, negative price revert, unknown feed revert, getPriceUsdc, updatePriceFeeds fee handling, getUpdateFee |
| SyntheticAsset | [test/SyntheticAssetTest.t.sol](../test/SyntheticAssetTest.t.sol) | 13 | mint with USDC collateral, burn at current price, non-transferable reverts, registerVault auth, balance accounting |
| MantleMETHAdapter | [test/MantleMETHAdapterTest.t.sol](../test/MantleMETHAdapterTest.t.sol) | 11 | deposit/withdraw round-trip, accrual over time, harvestYield mint backstop, valueInUSDC, slippage revert, projected ratio |
| OndoUSDYAdapter | [test/OndoUSDYAdapterTest.t.sol](../test/OndoUSDYAdapterTest.t.sol) | 11 | deposit at par, accrual at 5% APY, redeem, harvestYield, exchangeRate growth, production address views |
| MockERC20 | [test/MockERC20Test.t.sol](../test/MockERC20Test.t.sol) | 13 | minterAdmin auth, addMinter / removeMinter, chainId gating, transferMinterAdmin |
| Integration | [test/IntegrationTest.t.sol](../test/IntegrationTest.t.sol) | 10 | **full lifecycle happy path**, multi-agent isolation, harvest+distribute pro-rata, queue subordination auto-trigger, wind-down senior priority, mandate weight breach, phase transitions, founder lockup, production-aware adapter yield flow, synthetic NAV consistency |

---

## 3. Deployment Status

### 3.1 Anvil — chainId 31337 (current, complete)

[deployments/31337.json](../deployments/31337.json) — **20 addresses including TimeProvider + AgentNFT**:

| Component | Address |
|---|---|
| usdc (MockERC20) | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| timeProvider | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| treasury | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| pythAdapter | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` |
| mEthAdapter | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |
| usdyAdapter | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` |
| sNVDA / sSPY / sAAPL / sTSLA / sMSFT | see file |
| agentTokenImpl / agentVaultImpl / founderVaultImpl | see file |
| agentNFT | `0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1` |
| harvester | `0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE` |
| distributor | `0x68B1D87F95878fE05B998F19b66F4baba5De1aed` |
| redemptionQueue | `0x3Aa5ebB10DC797CAC828524e59A333d0A371443c` |
| registry | `0xc6e7DF5E7b4f2A278906862b61205850344D4e7d` |

Status: ✅ Up-to-date with `TimeProvider` + `AgentNFT` + production-aware adapter set.

### 3.2 Mantle Sepolia — chainId 5003 (stale, redeploy required)

[deployments/5003.json](../deployments/5003.json) — **18 addresses, MISSING `timeProvider` and `agentNFT`**:

| Component | Address | Status |
|---|---|---|
| usdc | `0xDFFe31A3EE6507A641a9811bA077c5B8bf7a83Fe` | ⏳ pre-TimeProvider build |
| treasury | `0x17186f6ef735Ba1271DB6DE87aC4760DC3FB4e4C` | ⏳ |
| pythAdapter | `0x15DD7bfffAaD273250b330fB75D71F19B7634D9F` | ⏳ |
| mEthAdapter | `0x7a5c40C631b111A3503dc36CA70536B839B54B9f` | ⏳ |
| usdyAdapter | `0x79a7D8aD5F9B1790211720af950A187d08684d09` | ⏳ |
| sNVDA / sSPY / sAAPL / sTSLA / sMSFT | see file | ⏳ |
| agentTokenImpl / agentVaultImpl / founderVaultImpl | see file | ⏳ |
| harvester | `0xeE2EE0131CCC97278FDb62B0DD38aAC7E80bF5AA` | ⏳ |
| distributor | `0x21dE0b4097ea548AbC484Ea26DccCb8c04DE1b30` | ⏳ |
| redemptionQueue | `0x73032888240D85dfC8e65c5bFcdfc1FfFB960D94` | ⏳ |
| registry | `0x73F040de5fdF22f8d54e9ceDe3618DC8CA960184` | ⏳ |
| **timeProvider** | — | ❌ not deployed |
| **agentNFT** | — | ❌ not deployed |

⏳ **Top pending item**: rerun `forge script script/Deploy.s.sol --rpc-url $MANTLE_SEPOLIA_RPC --broadcast` to bring Sepolia onto the current revision (TimeProvider + AgentNFT + updated mETH/USDY adapters with mint backstops).

---

## 4. Comparison Against IDEA.md Spec

### 4.1 Architecture spec (IDEA.md §컨트랙트 아키텍처)

| Spec contract | Implementation | Status |
|---|---|---|
| AgentNFT.sol (ERC-8004) | [src/system/AgentNFT.sol](../src/system/AgentNFT.sol) | ✅ singleton, reputation + slash mechanism |
| AgentToken.sol (ERC-20) | [src/core/AgentToken.sol](../src/core/AgentToken.sol) | ✅ clone, vault-gated mint/burn |
| AgentVault.sol (ERC-4626) | [src/core/AgentVault.sol](../src/core/AgentVault.sol) | ✅ clone, full wind-down state machine |
| FounderVault.sol | [src/core/FounderVault.sol](../src/core/FounderVault.sol) | ✅ clone, lockup + subordination + carry |
| SyntheticAsset.sol | [src/adapters/SyntheticAsset.sol](../src/adapters/SyntheticAsset.sol) | ✅ 5 instances, Pyth-priced |
| HelmRegistry.sol | [src/system/HelmRegistry.sol](../src/system/HelmRegistry.sol) | ✅ singleton, EIP-1167 factory |
| YieldHarvester.sol | [src/yield/YieldHarvester.sol](../src/yield/YieldHarvester.sol) | ✅ adapter loop + depositYield |
| DividendDistributor.sol | [src/yield/DividendDistributor.sol](../src/yield/DividendDistributor.sol) | ✅ 90/10 split, epoch-based claim |
| RedemptionQueue.sol | [src/system/RedemptionQueue.sol](../src/system/RedemptionQueue.sol) | ✅ 4 tiers, subordination auto-trigger |
| PlatformTreasury.sol | [src/system/PlatformTreasury.sol](../src/system/PlatformTreasury.sol) | ✅ fee collection + admin withdraw |
| PythPriceAdapter | [src/adapters/PythPriceAdapter.sol](../src/adapters/PythPriceAdapter.sol) | ✅ per-feed staleness |
| MantleMETHAdapter | [src/adapters/MantleMETHAdapter.sol](../src/adapters/MantleMETHAdapter.sol) | 🟡 **hybrid** — real ETH/USD oracle, simulated mETH/ETH stake yield |
| OndoUSDYAdapter | [src/adapters/OndoUSDYAdapter.sol](../src/adapters/OndoUSDYAdapter.sol) | 🟡 **production-aware mock** — simulated 5% APY with real mainnet addresses surfaced |
| TimeProvider (extra) | [src/system/TimeProvider.sol](../src/system/TimeProvider.sol) | ✅ chainId-gated dev fast-forward (testnet demo accel) |

### 4.2 Spec features (IDEA.md §결정 사항 기록)

| Spec decision | Status | Notes |
|---|---|---|
| Single token model (agent = ETF) | ✅ | ERC-20 AGT + ERC-8004 NFT 1:1 paired |
| Stream 1: yield 90/10 → holders + dev carry | ✅ | `DividendDistributor.distribute` enforces CARRY_BPS = 1000 |
| Stream 2: capital gain → NAV-resident | ✅ | Vault never force-sells synthetic positions |
| Stream 3: trading fees → platform | ✅ | Mint 0.5% / Redeem 0.5% / Rebalance 0.05% → PlatformTreasury |
| 30-day Incubation gate | ✅ | HelmRegistry `INCUBATION_PERIOD = 30 days`, founder-only mints |
| Phase machine (Incubation → PublicLaunch → WindDown → Settled) | ✅ | Vault `Phase` enum + registry transitions |
| Min seed $1000 USDC | ✅ | `MIN_SEED_USDC = 1000e6` |
| Founder lockup ≥ 90 days | ✅ | FounderVault `lockupDays < 90` reverts in init |
| FounderShareBps ∈ [5%, 30%] | ✅ | enforced in init |
| Subordination check on withdraw | ✅ | `cumulativeWithdrawnBps ≤ subordinationThresholdBps` |
| Wind-down: subordination, manual, slash triggers | ✅ | `triggerWindDown` callable by founderVault / registry / queue |
| Senior priority during wind-down | ✅ | `preLossNavPerShare` snapshot + senior window |
| 90-day senior window | ✅ | `DEFAULT_SENIOR_WINDOW = 90 days` |
| Redemption queue 0/30/60/90-day tiers | ✅ | `TIER_DAYS = [0, 30, 60, 90]`, per-agent allowance |
| RedemptionQueue NAV at maturity | ✅ | Queue calls `fulfillRedemption` after lockup ends |
| Whitelisted assets only | ✅ | `_isWhitelisted` + `AssetNotWhitelisted` revert |
| Mandate breach → revert + slash | ✅ | Tx reverts; BE indexer relays to `notifyMandateBreach` → AgentNFT slash 1000 bps |
| ERC-8004 NFT reputation + slash | ✅ | `reputationScore[agentId]`, `windDownThreshold` event |
| Pyth Mantle stock feeds | ✅ | Stage B verified — NVDA/SPY/AAPL/TSLA/MSFT feed IDs hardcoded |
| Mantle mETH integration | 🟡 | Hybrid: real Sepolia address referenced, ETH/USD via Pyth, mETH/ETH ratio simulated 4% APY |
| Ondo USDY integration | 🟡 | Production-aware mock: mainnet addresses surfaced, ~5% APY simulated |
| Demo time acceleration | ✅ | TimeProvider singleton, chainId 5003/31337 only |
| Auto-distribute monthly | ❌ | `distribute()` is manual / harvester-pulled. Spec post-MVP cut tree allowed. |
| LLM mandate parser | ❌ | Out of contracts scope — handled BE-side |
| Init Capital lending | ❌ | Not yet integrated (spec marks "선택") |
| Merchant Moe routing | ❌ | Not yet integrated (spec marks "선택") |
| Pendle PT | ❌ | Not yet integrated (spec marks "선택") |
| FBTC | ❌ | Not yet integrated (spec marks "선택") |

### 4.3 Step-based plan (IDEA.md §단계별 일정)

| Step | Scope | Status |
|---|---|---|
| Step 1 Foundation | Pyth verification, AgentVault skeleton, AgentToken, deposit/mint | ✅ |
| Step 2 Asset Layer | SyntheticAsset, NAV engine, redemption flow | ✅ |
| Step 3 Founder Subordination | FounderVault, lockup, transfer tracking | ✅ |
| Step 4 Agent Runtime | AgentNFT, mandate parser, executor wiring | ✅ contracts side; BE-side LLM parser is FE/BE work |
| Step 5 Vetting System | Phase machine, incubation, public launch | ✅ |
| Step 6 Wind-down | State machine, senior priority, slash trigger | ✅ |
| Step 7 Yield + Dividend + Carry + Queue + Platform | YieldHarvester, DividendDistributor, RedemptionQueue, PlatformTreasury | ✅ |
| Step 8 Marketplace UI | FE | ⏳ FE scope |
| Step 9 Demo Polish | Fast-forward mode, video | ✅ time accel done; demo video FE/marketing scope |

### 4.4 Production-aware design choices and rationale

| Decision | Rationale |
|---|---|
| **mETH adapter = hybrid** (real Pyth ETH/USD, simulated stake ratio) | Mantle Sepolia has no DEX liquidity to swap USDC↔ETH; real ETH/USD pricing keeps the NAV math production-equivalent while the simulated 4% APY exercise the harvest→distribute pipeline end-to-end. |
| **USDY adapter = production-aware mock** | Real USDY is regulated and only on Mantle Mainnet. The adapter surfaces `productionUsdyAddress()` and `productionOracleAddress()` so the FE can show the mainnet target; on-migration the only change is replacing `_accrueYield` with reads from `RWADynamicRateOracle`. |
| **MockUSDC mint backstop** chainId-gated | On testnet, adapters need to print USDC to cover simulated yield + P&L. `MockERC20.onlyMinter` checks `chainid == 5003 \|\| 31337` so a misconfigured mainnet deploy cannot print real value. |
| **TimeProvider with chainId-gated `advance`** | Demo needs to compress 30-day incubation + 90-day lockup into seconds. `devEnabled` frozen at construction means once deployed to mainnet the offset is permanently 0. |
| **AgentNFT singleton (not cloneable)** | Reputation is a system-wide surface. Cloneable NFTs would fracture identity across registries and break ERC-8004's "permanent identity" guarantee. |
| **EIP-1167 Clones for per-agent trio** | Without clones, `HelmRegistry` runtime bytecode would exceed the EIP-170 24,576-byte cap once all three implementations are inlined. Clones drop per-agent gas to ~150k for the full deploy. |
| **`balanceOf` at claim time** (not snapshot) for dividends | MVP simplification; acknowledged in NatSpec as exploitable by front-running buys before distribute. Production path: ERC20Votes checkpointing. |
| **MandateBreach reverts but does not call back to slash** | Atomic-revert + atomic-slash would require splitting weight enforcement from the revert path. Off-chain indexer relays the reverted-tx signal back via `notifyMandateBreach`. |

---

## 5. Mantle / Ecosystem Integration

| System | Integration mode | Where | Status |
|---|---|---|---|
| **Pyth Network** | Real pull oracle, per-feed staleness | PythPriceAdapter + SyntheticAsset (equity feeds) + MantleMETHAdapter (ETH/USD) | ✅ Stage B verified, Mantle Sepolia Pyth address `0x98046Bd286715D3B0BC227Dd7a956b83D8978603` hardcoded |
| **Mantle mETH** | Hybrid — real Sepolia proxy referenced + Pyth-priced + simulated stake yield | MantleMETHAdapter | 🟡 production-aware; mainnet `0xcDA86A272531e8640cD7F1a92c01839911B90bb0` surfaced |
| **Ondo USDY** | Production-aware mock — mainnet addresses + simulated 5% APY | OndoUSDYAdapter | 🟡 production-aware; mainnet USDY `0x5bE26527...c5A6` + oracle `0xA96abbe...882f` surfaced |
| **USDC** | MockERC20 with minter role pattern (chainId-gated) | MockERC20, set as `usdc` in Deploy.s.sol | ✅ ready; real USDC address pluggable via `USDC_ADDRESS` env var on Sepolia |
| **Mantle Sepolia (5003)** | Target deployment chain | Deploy.s.sol chainId branch | 🟡 prior deployment stale, redeploy needed |
| **Anvil (31337)** | Local dev / forge tests | Deploy.s.sol chainId branch | ✅ current |
| Init Capital | — | — | ❌ not started (post-MVP optional) |
| Merchant Moe | — | — | ❌ not started (post-MVP optional) |
| Pendle on Mantle | — | — | ❌ not started (post-MVP optional) |

---

## 6. Architecture Highlights (for pitch / judges)

1. **EIP-1167 Clones pattern** — `HelmRegistry` deploys per-agent `AgentToken` + `AgentVault` + `FounderVault` as minimal-proxy clones from three pre-deployed implementations. Keeps registry bytecode well under the 24,576-byte EIP-170 cap and drops gas-per-agent to ~150k.
2. **TimeProvider singleton** — every time-dependent contract reads `currentTime()` from one place. On chainId 5003/31337, admin can `advance(seconds)` to compress 30-day incubation + 90-day lockups for demos. On mainnet, `devEnabled = false` is frozen at construction → offset is permanently 0.
3. **AgentNFT (ERC-8004 compatible)** — singleton ERC-721 keyed by `agentId`. `reputationScore` in basis points starts at 10000; `slash(agentId, amountBps, reason)` is the only mutation. Below `windDownThreshold` (5000) emits `SlashTriggeredWindDown` which the off-chain indexer can react to. NFT is transferable — reputation moves with ownership.
4. **Reputation slash mechanism + auto-windDown threshold** — wind-down slashes 2000 bps (20%); mandate breach slashes 1000 bps (10%). Repeated breaches push score below threshold → auto-windDown signal.
5. **Subordinated FounderVault (rug pull structural protection)** — founder shares are custodied with `lockupDays ≥ 90` enforced at init, and any withdrawal is rejected if cumulative withdrawn ratio exceeds `subordinationThresholdBps` (default 4000). The RedemptionQueue auto-triggers wind-down if user redemptions push the founder's effective stake above the threshold.
6. **REIT-model yield / dividend (90/10)** — `CARRY_BPS = 1000` is a hard constant inside both `FounderVault.initialize` (rejects any other value) and `DividendDistributor.distribute`. Holders claim pro-rata from each epoch; founder carry is pushed into FounderVault as USDC and claimed via `claimCarry`.
7. **Redemption queue with 0/30/60/90-day lockup tiers** — per-agent allowance set by admin (typically derived from the mandate's `redemptionQueueDays`). Long lockups create reputation-premium space between market price and NAV.
8. **Multi-asset support** — vault holds synthetic equities (sNVDA/sSPY/sAAPL/sTSLA/sMSFT via Pyth) + RWA (USDY via Ondo adapter) + crypto (mETH via Mantle adapter) + USDC, all in one ERC-4626 facade with mandate-defined weight bounds.
9. **MockUSDC mint backstop for yield simulation on testnet (chainId-gated)** — adapters need to print USDC to honour realised yield without a real DEX swap path. `MockERC20.mint` reverts on any chain outside 5003/31337, so a misconfigured mainnet deploy cannot dilute real value.

---

## 7. What's Pending

### 7.1 Must-do before submission

- ⏳ **Redeploy to Mantle Sepolia** — current `deployments/5003.json` predates `TimeProvider` and `AgentNFT`. Command: `forge script script/Deploy.s.sol --rpc-url $MANTLE_SEPOLIA_RPC --broadcast` (assumes `DEPLOYER_PRIVATE_KEY` env var; `USDC_ADDRESS` optional — auto-deploys MockUSDC if unset).
- ⏳ **Contract verification on Mantle Explorer** — 19 contracts to verify in a single batch script: `TimeProvider`, `PlatformTreasury`, `PythPriceAdapter`, `MantleMETHAdapter`, `OndoUSDYAdapter`, 5× SyntheticAsset, `AgentToken` (impl), `AgentVault` (impl), `FounderVault` (impl), `AgentNFT`, `YieldHarvester`, `DividendDistributor`, `RedemptionQueue`, `HelmRegistry`. Use `forge verify-contract` with `--chain-id 5003` and the Mantle Explorer API key.
- ⏳ **Frontend integration package** — bundle ABIs + addresses + integration guide. Output `out/` already has ABIs; needs a script to extract just the public surface contracts and emit `frontend/abis.ts` + `frontend/addresses.ts`.

### 7.2 Optional / post-MVP

- 🟡 Additional Mantle protocols: Init Capital lending adapter, Merchant Moe AMM routing, Pendle PT integration (all marked "선택" in IDEA.md).
- 🟡 More synthetic equities (sGOOGL, sMETA) — trivially additive given the existing SyntheticAsset pattern.
- 🟡 ERC20Votes-based balance checkpointing for `DividendDistributor` (acknowledged TODO in NatSpec).
- 🟡 Monthly cron-driven auto-distribute (spec allows manual `triggerDividend` for MVP).
- 🟡 Slither / Mythril / formal verification pass (helpful for AI×RWA judges' compliance framing).

---

## 8. Hackathon Submission Readiness

### 8.1 "20 Project Deployment Award" criteria

| Criterion | Status | Note |
|---|---|---|
| Smart contract deployed on Mantle testnet | 🟡 | Sepolia deployment exists (5003.json) but is stale — needs redeploy with TimeProvider + AgentNFT |
| Contract verified on Mantle Explorer | ❌ | Not yet done — batch verification needed for ~19 contracts |
| AI-powered function callable on-chain | 🟡 | `executeRebalance` is wired and tested; needs the BE executor to actually invoke it for the demo |
| Frontend demo publicly accessible | ❌ | FE work — outside contracts scope |
| Deployment addresses in submission | 🟡 | Anvil addresses ready; Sepolia addresses pending redeploy |
| Demo video ≥ 2 min | ❌ | Production / video work — outside contracts scope |
| Open-source GitHub repo with README | 🟡 | Contracts repo open, `contracts/README.md` is 70 lines (concise); top-level README needs framing for judges |

### 8.2 AI × RWA Track — 1st Place criteria

| Criterion | Current state |
|---|---|
| **AI × RWA integration depth** | Strong on architecture: production-aware adapter pattern (USDY mock surfaces real Mantle Mainnet addresses; mETH hybrid uses real Pyth ETH/USD oracle), single-token ETF model wrapping RWA (USDY) + synthetic equities + crypto in one vault. **Gap**: the "AI" side is BE-driven (LLM mandate parser, executor), so the on-chain demo needs the BE caller in place to land the narrative. |
| **Technical completeness** | Strong: 208/208 tests pass, 16 suites, end-to-end integration suite covers happy path + wind-down + yield + queue + mandate breach. Contracts side is feature-complete vs. IDEA.md's "절대 컷 금지" list (Pyth, FounderVault, senior priority, vetting incubation, YieldHarvester+DividendDistributor 90/10, RedemptionQueue ≥30-day). |
| **Mantle ecosystem integration** | Pyth (real, Stage B verified), Mantle mETH (hybrid real-address + Pyth oracle), Ondo USDY (production-aware mock with mainnet addresses surfaced). Init/Merchant Moe/Pendle marked optional in spec, not yet integrated. |
| **Compliance awareness** | In code: USDY adapter NatSpec explicitly states "Real USDY is regulated and not available on Sepolia"; MockUSDC chainId gate prevents accidental mainnet value-printing. In NatSpec across all contracts. **Gap**: framing — a top-level "Regulatory considerations" section in the repo README or pitch deck would land the point for judges. |
| **Real-World Validity** | Strong asset clarity (5 named equities + USDY T-bills + mETH staking), clear target user (retail allocator picking AI-managed ETF), explicit UX flow (mandate → incubation → public launch → redeem at lockup tier → claim dividends + carry). **Gap**: end-to-end UX completeness requires FE, which is out-of-scope here. |

---

## Appendix A — Lifecycle sequence (happy path, end-to-end)

This is the canonical agent lifecycle that `test_fullLifecycle_happyPath` exercises in [test/IntegrationTest.t.sol](../test/IntegrationTest.t.sol). It also matches the 4-minute demo video script in IDEA.md §데모 영상 시나리오.

```
┌─ FOUNDER ───────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  founder → HelmRegistry.registerAgent(mandateHash, mandateURI, 1000e6 USDC,     │
│                                       assets, weightConstraints)                 │
│             │                                                                    │
│             ├─ Clones.clone(agentTokenImpl)    ──► AgentToken.initialize()      │
│             ├─ Clones.clone(agentVaultImpl)    ──► AgentVault.initialize()      │
│             ├─ Clones.clone(founderVaultImpl)  ──► FounderVault.initialize()    │
│             ├─ vault.deposit(1000e6, registry) → 1000e18 founder shares minted  │
│             ├─ founderVault.depositFounderShares(1000e18) — lockup clock starts │
│             └─ agentNFT.mint(agentId, founder) — reputation = 10000 bps         │
│                                                                                  │
│             Vault enters Phase.Incubation. Mints gated to founder-only.          │
│                                                                                  │
├─ INCUBATION (30 days) ──────────────────────────────────────────────────────────┤
│                                                                                  │
│  executor (BE) → vault.executeRebalance(targets, proof)                          │
│                  - Iteratively buys/sells synthetic + adapter positions          │
│                  - Mandate weight bounds enforced (revert on breach)             │
│                  - Rebalance fee skimmed to PlatformTreasury                     │
│                                                                                  │
│  TimeProvider.advance(30 days)  [testnet/anvil only]                             │
│                                                                                  │
├─ ADVANCE TO PUBLIC LAUNCH ──────────────────────────────────────────────────────┤
│                                                                                  │
│  anyone → HelmRegistry.advanceToPublic(agentId)                                  │
│           - checks incubationStart + 30 days ≤ now                               │
│           - vault.enterPublicLaunch()  →  Phase.PublicLaunch                     │
│           - AgentNFT can be updated to "verified" tokenURI by admin              │
│                                                                                  │
├─ PUBLIC TRADING ────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  holder → vault.deposit(usdc, receiver)                                          │
│           - mint fee 0.5% → PlatformTreasury                                     │
│           - shares minted at NAV-before-deposit                                  │
│                                                                                  │
│  executor (BE cron) → harvester.harvest(agentId)                                 │
│                       - low-level harvestYield() on each registered adapter     │
│                       - mETH adapter mints realised yield as USDC (testnet)     │
│                       - USDY adapter mints realised yield as USDC (testnet)     │
│                       - harvester.depositYield(total) → vault.yieldPool         │
│                                                                                  │
│  harvester → distributor.stageYield(agentId, amount)                             │
│  harvester → distributor.distribute(agentId)                                     │
│             - 90% holdersShare → epoch snapshot                                  │
│             - 10% carry → founderVault.receiveCarry(carry)                       │
│                                                                                  │
│  holder → distributor.claim(agentId, epochs[]) → USDC                            │
│  founder → founderVault.claimCarry() → USDC                                      │
│                                                                                  │
├─ REDEMPTION (lockup-tiered) ────────────────────────────────────────────────────┤
│                                                                                  │
│  holder → redemptionQueue.requestRedeem(agentId, shares, ThirtyDay)              │
│           - AGT custodied; unlockAt = now + 30 days                              │
│                                                                                  │
│  TimeProvider.advance(30 days)  [testnet]                                        │
│                                                                                  │
│  holder → redemptionQueue.claim(requestId)                                       │
│           - vault.fulfillRedemption(queue, shares) — burns + pays USDC at NAV    │
│           - redeem fee 0.5% → PlatformTreasury                                   │
│           - subordination auto-check: if founder share ratio crosses             │
│             threshold post-burn, queue triggers vault.triggerWindDown(...)       │
│                                                                                  │
├─ WIND-DOWN (any of 3 triggers) ─────────────────────────────────────────────────┤
│                                                                                  │
│  Trigger 1: founderVault subordination breach (auto via queue)                   │
│  Trigger 2: registry.slash(agentId, reason) — admin / reputation                 │
│  Trigger 3: founder → founderVault.triggerWindDown(reason) — manual              │
│                                                                                  │
│  vault.triggerWindDown(reason)                                                   │
│  - phase = WindDown, mints disabled                                              │
│  - preLossNavPerShare = totalNAV / supply  ← senior claim snapshot               │
│  - seniorWindowEnd = now + 90 days                                               │
│  - registry.markWindDown(agentId)  →  agentNFT.slash(2000 bps, "wind_down")     │
│                                                                                  │
│  anyone → vault.progressWindDown()  (call until 0 returned)                      │
│           - sells next non-zero position to USDC                                 │
│                                                                                  │
│  TimeProvider.advance(90 days)  [testnet]                                        │
│                                                                                  │
│  anyone → vault.settle()                                                         │
│           - seniorPay = min(seniorShares × preLossNavPerShare, cashUSDC)        │
│           - juniorPay = cash − seniorPay  (founder absorbs residual loss)        │
│           - phase = Settled; registry.markSettled(agentId)                       │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Appendix B — Event surface (BE indexer hook list)

Every state-changing action emits an event so the off-chain indexer is the audit log. Listed by emitter:

| Emitter | Event | Triggered by |
|---|---|---|
| HelmRegistry | `AgentRegistered(agentId, founder, deployment)` | `registerAgent` |
| HelmRegistry | `PhaseAdvanced(agentId, from, to)` | `advanceToPublic` |
| HelmRegistry | `AgentSlashed(agentId, reason)` | admin slash |
| HelmRegistry | `AgentWindDown(agentId)` | vault `markWindDown` |
| HelmRegistry | `AgentSettled(agentId)` | vault `markSettled` |
| AgentNFT | `AgentNFTMinted(agentId, founder, initialReputation)` | registry mint |
| AgentNFT | `ReputationSlashed(agentId, before, after, amountBps, reason)` | any slash |
| AgentNFT | `SlashTriggeredWindDown(agentId, finalScore)` | slash crosses threshold |
| AgentNFT | `TokenURISet(agentId, newURI)` | registry/admin |
| AgentVault | `Deposit(sender, receiver, assets, shares)` | `deposit`/`mint` |
| AgentVault | `Rebalanced(strategyHash, navAfter, timestamp)` | `executeRebalance` |
| AgentVault | `YieldDeposited(amount, newYieldPool)` | harvester push |
| AgentVault | `RedemptionFulfilled(holder, sharesBurned, usdcOut)` | queue claim |
| AgentVault | `PhaseChanged(from, to)` | every transition |
| AgentVault | `WindDownTriggered(by, reason)` | trigger |
| AgentVault | `WindDownProgressed(remainingPositions)` | `progressWindDown` |
| AgentVault | `Settled(seniorPaid, juniorPaid)` | `settle` |
| FounderVault | `SharesDeposited`, `SharesWithdrawn`, `CarryReceived`, `CarryClaimed` | self-explanatory |
| RedemptionQueue | `RedeemRequested(requestId, agentId, holder, shares, tier, unlockAt)` | request |
| RedemptionQueue | `RedeemClaimed(requestId, usdcOut)` | claim |
| RedemptionQueue | `RedeemCancelled(requestId)` | cancel |
| YieldHarvester | `YieldHarvested(agentId, source, amount)`, `SourceRegistered`, `SourceRemoved` | harvest + admin |
| DividendDistributor | `Distributed(agentId, epoch, total, holdersShare, carry, root)` | distribute |
| DividendDistributor | `Claimed(agentId, holder, epoch, amount)` | claim |
| PlatformTreasury | `FeeCollected(agentId, kind, amount)`, `FeeRateUpdated`, `Withdrawn`, `AdminTransferred` | fee push + admin |
| TimeProvider | `TimeAdvanced`, `TimeReset`, `AdminTransferred` | admin |
| MantleMETHAdapter | `Deposited(holder, usdcIn, mEthOut)`, `Withdrawn(holder, mEthIn, usdcOut)` | adapter mutations |
| OndoUSDYAdapter | `Deposited(holder, usdcIn, usdyOut)`, `Redeemed(holder, usdyIn, usdcOut)` | adapter mutations |
| SyntheticAsset | `Minted(to, syntheticOut, usdcCollateral, price)`, `Burned(from, syntheticIn, usdcOut, price)` | mint/burn |

## Appendix C — Deployment + verification commands

```sh
# Mantle Sepolia full redeploy (refreshes 5003.json with TimeProvider + AgentNFT)
export MANTLE_SEPOLIA_RPC=https://rpc.sepolia.mantle.xyz
export DEPLOYER_PRIVATE_KEY=0x...
# Optional: set USDC_ADDRESS if you want to use a real USDC contract rather
# than auto-deploying a fresh MockUSDC.
forge script script/Deploy.s.sol \
    --rpc-url $MANTLE_SEPOLIA_RPC \
    --broadcast \
    --slow

# Verify a single contract on Mantle Explorer (example for HelmRegistry)
forge verify-contract \
    --chain-id 5003 \
    --verifier-url https://explorer.sepolia.mantle.xyz/api \
    --etherscan-api-key $MANTLE_EXPLORER_API_KEY \
    <ADDRESS> src/system/HelmRegistry.sol:HelmRegistry

# Local dev (anvil)
anvil &
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Run the full suite
forge test -vvv
```

## Appendix D — File layout snapshot

```
contracts/
├── src/
│   ├── core/         AgentToken, AgentVault, FounderVault             (3 files, 932 LOC)
│   ├── system/       AgentNFT, HelmRegistry, PlatformTreasury,
│   │                 RedemptionQueue, TimeProvider                    (5 files, 961 LOC)
│   ├── yield/        YieldHarvester, DividendDistributor              (2 files, 307 LOC)
│   ├── adapters/     PythPriceAdapter, SyntheticAsset,
│   │                 MantleMETHAdapter, OndoUSDYAdapter               (4 files, 797 LOC)
│   └── interfaces/   14 interfaces                                    (14 files, 648 LOC)
├── test/             16 suites, 208 tests                             (15 files + 6 mocks, ~4 449 LOC)
├── script/           Deploy.s.sol, PythVerify.s.sol
└── deployments/      31337.json (current), 5003.json (stale)
```

## Appendix B — Hard-locked protocol constants

| Constant | Value | Where enforced |
|---|---|---|
| `carryBps` | 1000 (10%) | FounderVault.initialize reverts any other value; DividendDistributor uses `CARRY_BPS = 1000` |
| `MIN_SEED_USDC` | 1000 USDC (1000e6) | HelmRegistry.registerAgent |
| `INCUBATION_PERIOD` | 30 days | HelmRegistry |
| `founderShareBps` | [500, 3000] (5–30%) | FounderVault.initialize |
| `founderLockupDays` min | 90 | FounderVault.initialize |
| `DEFAULT_SENIOR_WINDOW` | 90 days | AgentVault |
| `MAX_FEE_BPS` | 1000 (10%) per kind | PlatformTreasury |
| Default mint / redeem / rebalance fee | 50 / 50 / 5 bps | PlatformTreasury constructor |
| `MAX_BPS` (reputation max) | 10000 | AgentNFT |
| `windDownThreshold` | 5000 bps (50%) | AgentNFT (admin-settable) |
| TIER_DAYS | [0, 30, 60, 90] | RedemptionQueue |
| `TimeProvider.devEnabled` | chainid ∈ {5003, 31337} | TimeProvider constructor (immutable) |

---

*End of report. For business logic source-of-truth see [IDEA.md](../IDEA.md); for engineering conventions see [CLAUDE.md](../CLAUDE.md).*
