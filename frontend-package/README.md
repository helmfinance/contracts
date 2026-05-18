# Helm — Frontend Integration Package

Everything the FE needs to integrate with the deployed Helm protocol on
**Mantle Sepolia (chain id 5003)**.

```
frontend-package/
├── addresses.json     deployed contract addresses + chain metadata
├── abis/              one JSON per contract; bare ABI arrays
├── constants.ts       enums + fee rates + decimals + Pyth feed ids
├── events.ts          event signatures + topic0 hashes
└── README.md          this file
```

Regenerate the ABIs after any `forge build`:

```bash
./script/export-abis.sh
```

---

## Quick start (wagmi v2 + viem)

```ts
import { defineChain, createPublicClient, http } from "viem";
import { createConfig } from "wagmi";
import addresses from "./addresses.json";
import vaultAbi from "./abis/AgentVault.json";
import registryAbi from "./abis/HelmRegistry.json";

export const mantleSepolia = defineChain({
  id: addresses.chain.id,                  // 5003
  name: addresses.chain.name,              // Mantle Sepolia
  nativeCurrency: addresses.chain.nativeCurrency,
  rpcUrls: { default: { http: [addresses.chain.rpcUrl] } },
  blockExplorers: {
    default: { name: "Explorer", url: addresses.chain.explorerUrl },
  },
  testnet: true,
});

export const config = createConfig({
  chains: [mantleSepolia],
  transports: { [mantleSepolia.id]: http() },
});
```

### Wallet → "Add network" prompt

```ts
await window.ethereum.request({
  method: "wallet_addEthereumChain",
  params: [{
    chainId: "0x138B",   // 5003
    chainName: "Mantle Sepolia",
    nativeCurrency: { name: "MNT", symbol: "MNT", decimals: 18 },
    rpcUrls: ["https://rpc.sepolia.mantle.xyz"],
    blockExplorerUrls: ["https://explorer.sepolia.mantle.xyz"],
  }],
});
```

Test MNT (gas): **https://faucet.sepolia.mantle.xyz**. Test USDC is the mock
deployed at the `usdc` address in `addresses.json` — call `mint` on
`MockERC20.json` to fund a wallet during dev.

---

## Mint flow (USDC → AGT shares)

Two transactions: USDC approve, then `vault.deposit`. The agent's vault
address is *per-agent* — read it from `registry.deployments(agentId)`.

```ts
import { parseUnits, erc20Abi } from "viem";
import { writeContract, readContract } from "@wagmi/core";
import { USDC_DECIMALS } from "./constants";

const agentId = 1n;
const usdcAmount = parseUnits("100", USDC_DECIMALS); // 100 USDC

const deployment = await readContract(config, {
  abi: registryAbi,
  address: addresses.contracts.registry,
  functionName: "deployments",
  args: [agentId],
});
const vault = deployment.vault;

await writeContract(config, {
  abi: erc20Abi,
  address: addresses.contracts.usdc,
  functionName: "approve",
  args: [vault, usdcAmount],
});

await writeContract(config, {
  abi: vaultAbi,
  address: vault,
  functionName: "deposit",
  args: [usdcAmount, userAddress],   // ERC-4626 deposit(assets, receiver)
});
```

`Deposit` event fires; FE updates the user's AGT balance from
`vault.balanceOf(user)`.

---

## Redeem flow (AGT shares → USDC, with lockup)

Three steps: approve AGT to the queue, request, wait for unlock, claim.

```ts
import { LockupTier } from "./constants";
import queueAbi from "./abis/RedemptionQueue.json";
import tokenAbi from "./abis/AgentToken.json";

const shares = parseUnits("50", 18);
const tier = LockupTier.Day30;

// 1. Approve AGT → RedemptionQueue
await writeContract(config, {
  abi: tokenAbi,
  address: deployment.token,
  functionName: "approve",
  args: [addresses.contracts.redemptionQueue, shares],
});

// 2. Lock the shares in the queue. Returns a requestId via the
//    RedeemRequested event (topic0 in events.ts).
const txHash = await writeContract(config, {
  abi: queueAbi,
  address: addresses.contracts.redemptionQueue,
  functionName: "requestRedeem",
  args: [agentId, shares, tier],
});

// 3. After `unlockAt` (in the RedeemRequested log) has passed, claim.
await writeContract(config, {
  abi: queueAbi,
  address: addresses.contracts.redemptionQueue,
  functionName: "claim",
  args: [requestId],
});
```

The `Instant` tier may be disabled by the agent's mandate — if so,
`requestRedeem` reverts with `LockupTierDisabled`. Surface tier
availability up-front by reading the mandate.

---

## Dividend claim flow

Distributor publishes per-agent epoch snapshots. Users claim multiple
epochs in one call.

```ts
import distributorAbi from "./abis/DividendDistributor.json";

const epochs = [3n, 4n, 5n]; // epochs the user hasn't claimed yet
await writeContract(config, {
  abi: distributorAbi,
  address: addresses.contracts.distributor,
  functionName: "claim",
  args: [agentId, epochs],
});
```

`Claimed` event fires; `Distributed` is the snapshot you indexed off.

---

## Mandate registration flow (founder)

Founder posts the seed USDC (`MIN_SEED_USDC` ≥ 1000 USDC), declares the
asset basket + weight constraints, and pins the mandate URI. Registry
clones the four agent contracts and emits `AgentRegistered`.

```ts
import { MIN_SEED_USDC } from "./constants";

const seedUSDC = MIN_SEED_USDC;             // 1000 USDC, or more
const mandateURI = "ipfs://..../mandate.json";
const mandateHash = keccak256(toBytes(JSON.stringify(mandate)));

const assets = [
  { asset: addresses.syntheticAssets.sNVDA, kind: 0 }, // Synthetic
  { asset: addresses.contracts.mEthAdapter, kind: 1 }, // METHAdapter
];
const weightConstraints = [
  { asset: addresses.syntheticAssets.sNVDA, minBps: 0, maxBps: 6000 },
  { asset: addresses.contracts.mEthAdapter, minBps: 0, maxBps: 4000 },
];

await writeContract(config, {
  abi: erc20Abi,
  address: addresses.contracts.usdc,
  functionName: "approve",
  args: [addresses.contracts.registry, seedUSDC],
});

await writeContract(config, {
  abi: registryAbi,
  address: addresses.contracts.registry,
  functionName: "registerAgent",
  args: [mandateHash, mandateURI, seedUSDC, assets, weightConstraints],
});
```

The new `agentId` is in the `AgentRegistered` log. The vault is in
Incubation for `INCUBATION_PERIOD_DAYS` (30); the registry can then
advance to PublicLaunch.

---

## NAV reading

`vault.totalNAV()` returns the protocol-defined NAV in USDC units (6
decimals). Per-share NAV is just the ratio.

```ts
const [nav, supply] = await Promise.all([
  readContract(config, { abi: vaultAbi, address: vault, functionName: "totalNAV" }),
  readContract(config, { abi: vaultAbi, address: vault, functionName: "totalSupply" }),
]);
// Both are bigints. NAV is USDC (1e6); supply is AGT (1e18).
const navPerShare = supply === 0n
  ? 0n
  : (nav * 10n ** 18n) / supply;            // USDC-1e6 per AGT-1e18
```

---

## Pyth price update flow

Synthetic asset valuations + rebalance arithmetic call into
`PythPriceAdapter`, which keeps a freshness window. When you submit a
transaction that depends on an asset price and the FE knows the on-chain
price is stale, fetch a Hermes update and prepend it.

```ts
import pythAbi from "./abis/PythPriceAdapter.json";
import { PYTH_PRICE_FEEDS } from "./constants";

const feedIds = [PYTH_PRICE_FEEDS.NVDA, PYTH_PRICE_FEEDS.SPY];
const url = `https://hermes.pyth.network/v2/updates/price/latest?ids[]=${feedIds.join("&ids[]=")}`;
const { binary } = await (await fetch(url)).json();
const updateData = binary.data.map((d: string) => `0x${d}` as const);

// Pyth charges a small fee per feed in native MNT.
const fee = await readContract(config, {
  abi: pythAbi,
  address: addresses.contracts.pythAdapter,
  functionName: "getUpdateFee",
  args: [updateData],
});

await writeContract(config, {
  abi: pythAbi,
  address: addresses.contracts.pythAdapter,
  functionName: "updatePriceFeeds",
  args: [updateData],
  value: fee,
});
```

For read-only price freshness checks, use `pythAdapter.getPrice(feedId)`.

---

## Common errors

| Custom error                       | Where                  | Meaning |
| ---------------------------------- | ---------------------- | ------- |
| `NotAdmin()`                       | several                | Caller is not the protocol admin. |
| `OnlyVault()`                      | AgentToken, FounderVault, harvester | Only the agent's vault may call. |
| `OnlyRegistry()`                   | AgentNFT, AgentVault   | Only HelmRegistry may call. |
| `OnlyExecutor()`                   | AgentVault, distributor | Caller is not the executor key. |
| `OnlyHarvester()`                  | AgentVault             | Only the yield harvester. |
| `OnlyRedemptionQueue()`            | AgentVault             | Only the redemption queue. |
| `OnlyRegisteredVault()`            | adapters, treasury     | Caller is not a registered agent vault. |
| `OnlyReporter()`                   | AgentNFT               | Reputation reporter role missing. |
| `OnlyFounder()`                    | FounderVault           | Caller is not the agent's founder. |
| `OnlyDistributor()`                | FounderVault           | Only the dividend distributor. |
| `WrongPhase()`                     | AgentVault             | Action illegal in current phase (e.g. deposit during WindDown). |
| `MandateBreach()`                  | AgentVault, registry   | Proposed action would violate the mandate's weight constraints. |
| `IncubationPeriodNotElapsed()`     | HelmRegistry           | Can't advance to PublicLaunch before the 30-day vetting window. |
| `InsufficientCash()`               | AgentVault             | Vault USDC short of what the redeemer needs; wait or rebalance. |
| `InsufficientSeed()`               | HelmRegistry           | Founder seed below `MIN_SEED_USDC`. |
| `LockupTierDisabled(uint8)`        | RedemptionQueue        | The agent's mandate doesn't permit this lockup tier. |
| `RedeemNotUnlocked(uint64,uint64)` | RedemptionQueue        | `unlockAt` not reached yet. |
| `RedeemAlreadyClaimed()`           | RedemptionQueue        | This request was already claimed. |
| `AlreadyClaimed(...)`              | DividendDistributor    | This (agent, epoch, holder) was already claimed. |
| `EpochNotFinalized(...)`           | DividendDistributor    | Snapshot exists but isn't claimable yet. |
| `PriceStale(...)`                  | PythPriceAdapter       | Price is older than the freshness window — call `updatePriceFeeds`. |
| `SlippageTooHigh(...)`             | mETH / USDY adapters   | Adapter swap min-out not met. |
| `TransfersFrozen()`                | AgentToken             | Agent in WindDown / Settled phase, transfers paused. |
| `MandateLockedAfterIncubation()`   | AgentNFT               | Mandate can't be edited once PublicLaunch starts. |

When an unrecognised custom error returns, decode the 4-byte selector
against the ABIs in `abis/` to identify the source.

---

## Deployed addresses

All on **Mantle Sepolia (chainId 5003)**. Full canonical source:
[`addresses.json`](./addresses.json).

| Contract           | Address |
| ------------------ | ------- |
| HelmRegistry       | `0x3650636cA81d0e17ED0555d0BDD06c3576bEF9f1` |
| AgentNFT           | `0x0E39C35936E7862E3D38F3d3731B41C14012A349` |
| DividendDistributor| `0xB01Dc283B6e0f00CAE786205B0DA0b58D431660a` |
| RedemptionQueue    | `0x6ed60895d45f7E8edF1d948e855624D4ba3672b3` |
| PlatformTreasury   | `0x21dE0b4097ea548AbC484Ea26DccCb8c04DE1b30` |
| YieldHarvester     | `0x8fa5cF1B5026359D0C505fC11Fba18E7a3E5f40F` |
| PythPriceAdapter   | `0x73032888240D85dfC8e65c5bFcdfc1FfFB960D94` |
| TimeProvider       | `0xeE2EE0131CCC97278FDb62B0DD38aAC7E80bF5AA` |
| MantleMETHAdapter  | `0x73F040de5fdF22f8d54e9ceDe3618DC8CA960184` |
| OndoUSDYAdapter    | `0x7D71111baF3DB5Fb32a02A8463d6A79D5d421C4B` |
| USDC (mock)        | `0x69Bf37d6957f996C2De5d8406D250d9fB66afb1b` |
| AgentToken impl    | `0xEdBBB95F671AfC21037fc711968fd0788A699664` |
| AgentVault impl    | `0x38dE0d93CB68d321E103Dd59556Ace547F8c300b` |
| FounderVault impl  | `0x30b26845b79EdA49D20FD2A89570c3905aF350Fd` |
| Pyth (external)    | `0x98046Bd286715D3B0BC227Dd7a956b83D8978603` |

**Synthetic assets** (each is its own SyntheticAsset clone):

| Symbol | Address |
| ------ | ------- |
| sNVDA  | `0x104A82f00F052639543398593B886400a04DaCcD` |
| sSPY   | `0xE363f9424c9d61764980464Af70A8DC35A7E2eB5` |
| sAAPL  | `0xeBdf0A167477ed442924ddf08Fd5582a6b8F8280` |
| sTSLA  | `0x4f8c5Ce61a8974AE4b2d9A52D5E7CE8490c4414B` |
| sMSFT  | `0xb1421B27345F4f5a8a1fD09beb30860e0fa2a551` |

Per-agent contracts (token, vault, founderVault) live behind the
registry — read them via `registry.deployments(agentId)`.
