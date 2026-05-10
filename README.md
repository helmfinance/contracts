# Helm Smart Contracts

Foundry project for the Helm AI Agent ETF on Mantle.

## Setup

1. Install Foundry: https://getfoundry.sh
2. From inside `contracts/`:

```bash
./setup.sh                    # forge install OZ + Pyth + forge-std, then forge build
cp .env.example .env          # fill in deployer key + RPC URLs
forge test -vvv               # run tests (none yet, just verifies the toolchain)
```

## Layout

```
src/
├── core/         # Paired 4 contracts per agent
│   ├── AgentNFT.sol          (ERC-8004 identity)
│   ├── AgentToken.sol        (ERC-20 shares)
│   ├── AgentVault.sol        (ERC-4626 hub)
│   └── FounderVault.sol      (subordinated dev shares + carry)
├── system/       # Singletons (one instance for the whole platform)
│   ├── HelmRegistry.sol      (factory + vetting state machine)
│   ├── RedemptionQueue.sol   (0/30/60/90 day lockup)
│   └── PlatformTreasury.sol  (fee sink)
├── yield/
│   ├── YieldHarvester.sol    (cash yield → vault pool)
│   └── DividendDistributor.sol (90% holders / 10% FounderVault)
├── adapters/
│   ├── PythPriceAdapter.sol
│   ├── MantleMETHAdapter.sol
│   ├── OndoUSDYAdapter.sol
│   └── SyntheticAsset.sol    (sNVDA, sSPY backed by USDC + Pyth)
└── interfaces/   # Public ABI for everything above (BE imports these)
```

## Test

```bash
forge test -vvv
forge test --match-contract AgentVaultTest -vvv
forge coverage
```

For time-based logic (30d incubation, 6mo lockup, monthly dividends, 90d wind-down)
use `vm.warp(uint256)` and `vm.roll(uint256)` to fast-forward block time and number.

## Deploy

```bash
# .env must have DEPLOYER_PRIVATE_KEY, MANTLE_SEPOLIA_RPC, MANTLESCAN_KEY
forge script script/Deploy.s.sol \
  --rpc-url mantle_sepolia \
  --broadcast \
  --verify
```

After deploy, run `../scripts/sync-abis.sh` (set up later) to push ABIs to BE/FE.

## Conventions

- Solidity 0.8.24, optimizer on (200 runs)
- All contracts have a corresponding `I*.sol` interface in `src/interfaces/`
- Implementations import the interface and inherit it (`is I*`)
- NatSpec on every external/public function
- Events for every state-changing action (the BE indexer is the audit log)
- Custom errors over `require` strings (gas + clarity)
