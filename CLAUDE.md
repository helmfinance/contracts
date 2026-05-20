# Helm Smart Contracts — Claude Code Context

This is the smart contracts repo for **Helm**, an AI Agent ETF marketplace on Mantle (REIT model).

## Project model

- Each agent = ERC-20 share token + ERC-8004 NFT identity + ERC-4626-style vault holding USDC, mETH, USDY, and Pyth-priced synthetic equities (sNVDA, sSPY, sAAPL, sTSLA, sMSFT).
- **Yield** (USDY interest, mETH staking) → 90% to share holders as USDC dividend, 10% to founder as carry.
- **Capital gain** (synthetic equity price moves) → stays in NAV (no forced sell, no HWM).
- **Trading fees** (mint 0.5%, redeem 0.5%, rebalance 0.05%) → Helm platform treasury.
- **Founder shares are subordinated** — on wind-down, external holders (senior) redeem first, founder (junior) gets the rest. Founder cannot withdraw if cumulative withdrawals exceed `subordinationThresholdBps`.
- **Redemption queue** has lockup tiers (0/30/60/90 days) declared in the agent's mandate.

Full spec: see uploaded `IDEA__2_.md` for business logic. Treat it as authoritative.

## Stack

- Solidity 0.8.24, optimizer on (200 runs)
- Foundry (`forge build`, `forge test -vvv`)
- OpenZeppelin Contracts v5
- Pyth SDK (pyth-network/pyth-sdk-solidity)
- Network target: Mantle Sepolia (chainId 5003), Pyth contract `0x98046Bd286715D3B0BC227Dd7a956b83D8978603`

## Layout

```
src/
├── core/         AgentNFT, AgentToken, AgentVault, FounderVault
├── system/       HelmRegistry, RedemptionQueue, PlatformTreasury
├── yield/        YieldHarvester, DividendDistributor
├── adapters/     PythPriceAdapter, MantleMETHAdapter, OndoUSDYAdapter, SyntheticAsset
└── interfaces/   I*.sol — these EXIST already, do not modify their public API.
```

Implementations import the matching interface and inherit it (`is IFoo`).

## Conventions

- **One contract per file**, filename matches contract name.
- **NatSpec** on every external/public function (`@notice`, `@param`, `@return`).
- **Custom errors over require strings**: `error InsufficientBalance(uint256 have, uint256 want);`
- **Events for every state-changing action** — the BE indexer is the audit log. Always emit before returning.
- **Reentrancy**: use OZ `ReentrancyGuard` on any function that does external token transfers.
- **Access control**: explicit `onlyVault`, `onlyHarvester`, `onlyRegistry` modifiers. No `Ownable` unless the interface requires it.
- **No `tx.origin`, no `transfer()`/`send()` for ETH** — use `call`.
- **Decimals**: USDC = 6, AGT shares = 18, mETH = 18, MNT = 18, Pyth price normalized to 6, basis points are integers (`10000` = 100%).

## Tests

- Foundry tests in `test/`, one `<Contract>Test.t.sol` per implementation.
- Use `vm.warp(uint256)` and `vm.roll(uint256)` for time-based logic (lockups, dividend epochs, wind-down windows).
- For Pyth, use a `MockPyth` that implements `IPythPriceAdapter` returning canned prices — do not hit live Pyth in tests.
- Cover happy path + every revert path for each external function.
- Run `forge test -vvv` before committing. **All tests must pass.**

## Commits

- **One commit per task**, English, single line, Conventional Commits format.
- Examples: `feat: implement PythPriceAdapter with per-feed staleness`, `test: add AgentVault redemption tests`, `fix: handle Pyth confidence interval in NAV calc`.
- After each task: `git add . && git commit -m "..." && git push`.
- Do not amend or force-push without explicit instruction.

## Hard constraints

- `carryBps` is protocol-locked at `1000` (10%) — reject any other value.
- `maxLeverage` is protocol-locked at `1.0` — agents cannot borrow.
- `founderLockupDays` minimum is `90`.
- `founderShareBps` range is `[500, 3000]` (5-30%).
- Agent vault can only hold whitelisted assets — registered synthetic equities, mETH, USDY, and USDC. Reject anything else.

## When in doubt

- Follow the interface in `src/interfaces/I<Name>.sol` exactly.
- Reference `IDEA.md` for business logic decisions.
- Prefer fewer assumptions over guesses — if the spec is ambiguous, leave a `// TODO(human):` comment and continue.
