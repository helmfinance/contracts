# Helm Smart Contracts

Foundry project for **Helm** — an AI Agent ETF marketplace on Mantle, modelled
as a tokenised REIT. Each agent is a per-agent ERC-20 share token + ERC-8004
NFT identity + ERC-4626-style vault holding USDC, Pyth-priced synthetic
equities, mETH, and USDY. Yield on yield-bearing positions is split 90% to
holders (USDC dividend) / 10% to founder carry. Capital gains stay in NAV.

## Setup

1. Install Foundry: https://getfoundry.sh
2. From inside `contracts/`:

```bash
./setup.sh                    # forge install OZ + Pyth + forge-std, then forge build
cp .env.example .env          # fill in DEPLOYER_PRIVATE_KEY, MANTLE_SEPOLIA_RPC, MANTLESCAN_KEY
forge test -vvv               # 208 tests, all passing
```

## Architecture

The system is split into **system-wide singletons** (deployed once) and
**per-agent clones** (EIP-1167 minimal proxies, 3 per agent). Adapters
abstract over Pyth-priced synthetics, mETH staking, and USDY T-bill yield.

```
┌──── system singletons (1× each) ───────────────────────────────┐
│                                                                 │
│   HelmRegistry ──── factory; owns the phase machine             │
│   AgentNFT     ──── ERC-8004 identity + reputation              │
│   TimeProvider ──── chainId-gated demo clock                    │
│   PlatformTreasury, RedemptionQueue, YieldHarvester,            │
│   DividendDistributor, PythPriceAdapter,                        │
│   MantleMETHAdapter, OndoUSDYAdapter                            │
│                                                                 │
│   SyntheticAsset × 5  (sNVDA, sSPY, sAAPL, sTSLA, sMSFT)        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
            ▲                                ▲
            │ registerAgent                  │
            │                                │
┌───────────┴───── per-agent clones (3× per agent) ──────────────┐
│                                                                 │
│   AgentToken     — ERC-20 shares (AGT-N), mint/burn by vault    │
│   AgentVault     — ERC-4626 NAV hub + phase machine             │
│   FounderVault   — subordinated founder shares + 10% carry      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Source layout

```
src/
├── core/         Per-agent contracts (clone-deployed)
│   ├── AgentToken.sol         (ERC-20 shares)
│   ├── AgentVault.sol         (ERC-4626 NAV hub + wind-down state machine)
│   └── FounderVault.sol       (lockup + subordination + dev carry)
├── system/       Singletons
│   ├── HelmRegistry.sol       (factory + 30-day vetting + phase machine)
│   ├── AgentNFT.sol           (ERC-8004 identity + reputation slash)
│   ├── RedemptionQueue.sol    (0 / 30 / 60 / 90-day lockup tiers)
│   ├── PlatformTreasury.sol   (Mint/Redeem/Rebalance fee sink)
│   └── TimeProvider.sol       (testnet-only demo fast-forward)
├── yield/
│   ├── YieldHarvester.sol     (adapter → vault yield pool)
│   └── DividendDistributor.sol (90/10 split, epoch-based pro-rata)
├── adapters/
│   ├── PythPriceAdapter.sol      (Pyth pull oracle, per-feed staleness)
│   ├── MantleMETHAdapter.sol     (real ETH/USD oracle + simulated stake yield)
│   ├── OndoUSDYAdapter.sol       (production-aware mock, ~5% APY)
│   └── SyntheticAsset.sol        (sNVDA, sSPY, ... — USDC-collateralised, Pyth-priced)
└── interfaces/   Public ABI for everything above (BE imports these)
```

## Deployed addresses (Mantle Sepolia, chainId 5003)

All 19 contracts verified on Mantlescan. Click an address for source +
verified flag. Canonical JSON: [`deployments/5003.json`](./deployments/5003.json) —
the frontend integration package mirrors these at
[`frontend-package/addresses.json`](./frontend-package/addresses.json).

### System

| Contract | Address |
|---|---|
| HelmRegistry | [`0x3650636cA81d0e17ED0555d0BDD06c3576bEF9f1`](https://sepolia.mantlescan.xyz/address/0x3650636cA81d0e17ED0555d0BDD06c3576bEF9f1#code) |
| AgentNFT | [`0x0E39C35936E7862E3D38F3d3731B41C14012A349`](https://sepolia.mantlescan.xyz/address/0x0E39C35936E7862E3D38F3d3731B41C14012A349#code) |
| TimeProvider | [`0xeE2EE0131CCC97278FDb62B0DD38aAC7E80bF5AA`](https://sepolia.mantlescan.xyz/address/0xeE2EE0131CCC97278FDb62B0DD38aAC7E80bF5AA#code) |
| PlatformTreasury | [`0x21dE0b4097ea548AbC484Ea26DccCb8c04DE1b30`](https://sepolia.mantlescan.xyz/address/0x21dE0b4097ea548AbC484Ea26DccCb8c04DE1b30#code) |
| RedemptionQueue | [`0x6ed60895d45f7E8edF1d948e855624D4ba3672b3`](https://sepolia.mantlescan.xyz/address/0x6ed60895d45f7E8edF1d948e855624D4ba3672b3#code) |
| YieldHarvester | [`0x8fa5cF1B5026359D0C505fC11Fba18E7a3E5f40F`](https://sepolia.mantlescan.xyz/address/0x8fa5cF1B5026359D0C505fC11Fba18E7a3E5f40F#code) |
| DividendDistributor | [`0xB01Dc283B6e0f00CAE786205B0DA0b58D431660a`](https://sepolia.mantlescan.xyz/address/0xB01Dc283B6e0f00CAE786205B0DA0b58D431660a#code) |

### Adapters

| Contract | Address |
|---|---|
| PythPriceAdapter | [`0x73032888240D85dfC8e65c5bFcdfc1FfFB960D94`](https://sepolia.mantlescan.xyz/address/0x73032888240D85dfC8e65c5bFcdfc1FfFB960D94#code) |
| MantleMETHAdapter | [`0x73F040de5fdF22f8d54e9ceDe3618DC8CA960184`](https://sepolia.mantlescan.xyz/address/0x73F040de5fdF22f8d54e9ceDe3618DC8CA960184#code) |
| OndoUSDYAdapter | [`0x7D71111baF3DB5Fb32a02A8463d6A79D5d421C4B`](https://sepolia.mantlescan.xyz/address/0x7D71111baF3DB5Fb32a02A8463d6A79D5d421C4B#code) |

### Clone implementations

These are the *implementation* contracts used by `Clones.clone(...)`. Each
agent registered via the registry gets its own pair of clones pointing here.

| Contract | Address |
|---|---|
| AgentToken impl | [`0xEdBBB95F671AfC21037fc711968fd0788A699664`](https://sepolia.mantlescan.xyz/address/0xEdBBB95F671AfC21037fc711968fd0788A699664#code) |
| AgentVault impl | [`0x38dE0d93CB68d321E103Dd59556Ace547F8c300b`](https://sepolia.mantlescan.xyz/address/0x38dE0d93CB68d321E103Dd59556Ace547F8c300b#code) |
| FounderVault impl | [`0x30b26845b79EdA49D20FD2A89570c3905aF350Fd`](https://sepolia.mantlescan.xyz/address/0x30b26845b79EdA49D20FD2A89570c3905aF350Fd#code) |

### Synthetic assets

| Symbol | Address |
|---|---|
| sNVDA | [`0x104A82f00F052639543398593B886400a04DaCcD`](https://sepolia.mantlescan.xyz/address/0x104A82f00F052639543398593B886400a04DaCcD#code) |
| sSPY | [`0xE363f9424c9d61764980464Af70A8DC35A7E2eB5`](https://sepolia.mantlescan.xyz/address/0xE363f9424c9d61764980464Af70A8DC35A7E2eB5#code) |
| sAAPL | [`0xeBdf0A167477ed442924ddf08Fd5582a6b8F8280`](https://sepolia.mantlescan.xyz/address/0xeBdf0A167477ed442924ddf08Fd5582a6b8F8280#code) |
| sTSLA | [`0x4f8c5Ce61a8974AE4b2d9A52D5E7CE8490c4414B`](https://sepolia.mantlescan.xyz/address/0x4f8c5Ce61a8974AE4b2d9A52D5E7CE8490c4414B#code) |
| sMSFT | [`0xb1421B27345F4f5a8a1fD09beb30860e0fa2a551`](https://sepolia.mantlescan.xyz/address/0xb1421B27345F4f5a8a1fD09beb30860e0fa2a551#code) |

### Token + external

| Contract | Address |
|---|---|
| MockUSDC (testnet) | [`0x69Bf37d6957f996C2De5d8406D250d9fB66afb1b`](https://sepolia.mantlescan.xyz/address/0x69Bf37d6957f996C2De5d8406D250d9fB66afb1b#code) |
| Pyth (external) | [`0x98046Bd286715D3B0BC227Dd7a956b83D8978603`](https://sepolia.mantlescan.xyz/address/0x98046Bd286715D3B0BC227Dd7a956b83D8978603) |

## Key mechanisms

### REIT-model 90/10 carry split

`DividendDistributor.distribute(agentId)` is the only path that pays out
harvested yield. `CARRY_BPS` is **hard-locked at 1000 (10%)** in both
`DividendDistributor` and `FounderVault.initialize` — any other value reverts
at init.

```
yield pool ──► 90% holdersShare (epoch snapshot, pro-rata claim by AGT balance)
            └─ 10% carry        (pushed into FounderVault.carryBalance, founder claims)
```

Capital gains on synthetic-equity positions are **never auto-distributed** —
they accrue in NAV and flow to all holders (including the founder) through
share-price appreciation.

### Preventive subordination (4000 bps default)

The founder's AGT shares are custodied in `FounderVault`. Two distinct
threshold checks defend against rug-pull patterns:

1. **On founder withdraw** — `(cumulative withdrawn) / (total deposited) > subordinationThresholdBps` reverts with `SubordinationBreached`. With the default 4000 bps the founder can never exit more than 40% of their initial allocation.
2. **On user redemption claim** — as outside holders redeem, `RedemptionQueue` recomputes `(founder held) / (current supply)`. If that ratio crosses the threshold, the queue automatically calls `vault.triggerWindDown("subordination_breach_via_redemption")` — protecting remaining seniors before the founder becomes dominant.

Both checks share the same `subordinationThresholdBps` storage slot, configured
at agent registration.

### Lockup tiers (0 / 30 / 60 / 90 days)

Per-agent allowed tiers are gated by `RedemptionQueue.tierAllowed[agentId][tier]`,
set by admin via `setAllowedTiers`. The redemption flow is:

```
holder ─► requestRedeem(agentId, shares, ThirtyDay)   ─► AGT custodied, unlockAt = now + 30d
                                                       ─► (RedemptionQueue.RedeemRequested event)
... 30 days later ...
holder ─► claim(requestId)   ─► vault.fulfillRedemption
                              ─► burns AGT, pays USDC at NAV, takes 0.5% redeem fee
                              ─► auto-checks subordination → may trigger wind-down
```

Longer lockups create more room between market price and NAV, so high-trust
agents can develop a reputation premium without immediate arb pressure.

### Wind-down senior priority

Wind-down has three triggers: founder-manual (`founderVault.triggerWindDown`),
registry slash, and subordination breach from a user redemption (above).
On any trigger:

```solidity
preLossNavPerShare = (totalNAV × 1e18) / totalSupply;   // ← snapshot
seniorWindowEnd    = now + 90 days;
phase = WindDown;
```

After 90 days of senior-only redemptions plus full position liquidation
(`progressWindDown` loop), `settle()` divides remaining cash:

```
seniorOwed = seniorShares × preLossNavPerShare / 1e18
seniorPay  = min(seniorOwed, cashUSDC)
juniorPay  = cashUSDC − seniorPay          ← founder absorbs any further losses
```

**The founder's tranche absorbs losses incurred during the wind-down window
before any senior holder takes a haircut**, which is the structural rug-pull
defense.

### Reputation slash + auto wind-down threshold

`AgentNFT` is a singleton ERC-721 keyed by `agentId`, with
`reputationScore[agentId]` starting at `MAX_BPS = 10000` and a configurable
`windDownThreshold` (default 5000 bps).

| Event | Slash | Reason tag |
|---|---|---|
| Wind-down triggered | 2000 bps | `"wind_down"` |
| Mandate breach (rebalance violates weight bounds) | 1000 bps | `"mandate_breach"` |

When `slash` drops the score below `windDownThreshold`,
`SlashTriggeredWindDown(agentId, finalScore)` fires — the BE indexer reacts to
that event (the on-chain wind-down itself is triggered separately so the
revert + slash don't need to be atomic). The NFT is transferable, and the
reputation history travels with ownership.

## Test

```bash
forge test                              # 208 tests
forge test --match-contract AgentVaultTest -vvv
forge coverage --report summary
```

### Current coverage (as of last `forge coverage` run)

**208 / 208 tests passing, 0 failed, 0 skipped.**

| Contract | Lines | Branches | Funcs |
|---|---|---|---|
| AgentToken / FounderVault / AgentNFT / TimeProvider / DividendDistributor / PlatformTreasury | 100% | 67–100% | 100% |
| RedemptionQueue | 97.6% | 66.7% | 100% |
| OndoUSDYAdapter / PythPriceAdapter | 100% | 73–79% | 100% |
| MantleMETHAdapter | 99.0% | 61.1% | 100% |
| HelmRegistry | 93.6% | 83.3% | 93.3% |
| YieldHarvester | 93.5% | 62.5% | 100% |
| SyntheticAsset | 91.7% | 80.0% | 86.7% |
| **AgentVault** | **71.7%** | **35.1%** | **52.7%** |
| **Total (src/ + test/mocks)** | **79.7%** | **56.6%** | **84.1%** |

> AgentVault is the most stateful contract — most uncovered branches are
> wind-down progression edge cases and ERC-4626 facade reverts that the
> integration suite touches end-to-end but the per-contract suite does not
> enumerate individually.

For time-based logic (30-day incubation, 180-day founder lockup, monthly
dividend epochs, 90-day wind-down window) use `vm.warp(uint256)` plus
`TimeProvider.advance(seconds)` to fast-forward both `block.timestamp` and
the protocol's logical clock.

## Deploy

```bash
# .env must have DEPLOYER_PRIVATE_KEY, MANTLE_SEPOLIA_RPC, MANTLESCAN_KEY
forge script script/Deploy.s.sol \
  --rpc-url $MANTLE_SEPOLIA_RPC \
  --broadcast \
  --verify
```

After deploy:

```bash
./script/export-abis.sh        # refresh frontend-package/abis/
bash script/verify-all.sh      # re-verify any contracts the --verify flag missed
```

The deploy script writes addresses to `deployments/<chainId>.json`. The
frontend integration package reads `deployments/5003.json` and republishes a
chain-typed copy at `frontend-package/addresses.json`.

## Conventions

- Solidity 0.8.24, optimizer on (200 runs)
- All contracts have a matching `I*.sol` interface in `src/interfaces/`
- Implementations import the interface and inherit it (`is I*`)
- NatSpec on every external/public function
- Events for every state-changing action (the BE indexer is the audit log)
- Custom errors over `require` strings (gas + clarity)
- `_now()` reads `TimeProvider.currentTime()`, never `block.timestamp` directly,
  so testnet demos can fast-forward all time-gated logic in one admin call

## Further reading

- [`docs/CONTRACT_STATUS.md`](./docs/CONTRACT_STATUS.md) — hackathon-judge-oriented status report: what's implemented, IDEA.md coverage, hackathon-submission readiness checklist
- [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) — visual architecture guide (mermaid diagrams, sequence flows, permission matrix, money-flow scenarios, error decoder)
- [`docs/ARCHITECTURE.ko.md`](./docs/ARCHITECTURE.ko.md) — Korean translation of the architecture guide
- [`IDEA.md`](./IDEA.md) — business spec, REIT-model decisions, hackathon track positioning (authoritative for business logic)
- [`frontend-package/README.md`](./frontend-package/README.md) — wagmi v2 + viem integration guide, mint/redeem/dividend flows, common-error decoder for FE
- [`CLAUDE.md`](./CLAUDE.md) — coding conventions for Claude Code working on this repo
