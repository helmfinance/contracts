#!/usr/bin/env bash
#
# verify-all.sh — Batch verify every deployed Helm contract on Mantle Sepolia.
#
# Usage:
#   bash script/verify-all.sh
#
# Reads addresses from deployments/5003.json, derives each contract's constructor
# args from script/Deploy.s.sol's hard-coded constants, then calls
# `forge verify-contract --chain mantle-sepolia --watch` for each.
#
# Requirements:
#   - foundry (forge, cast) on PATH
#   - jq
#   - .env at the repo root containing MANTLESCAN_KEY
#   - deployments/5003.json populated (run script/Deploy.s.sol first)
#
# Behaviour:
#   - Continues past individual failures.
#   - Prints "Verifying X (n/19)..." per contract.
#   - Prints "  ✅ Verified" or "  ❌ Failed: <reason>".
#   - Prints final "Verified: N/19, Failed: M/19" summary.
#   - Exits 0 if all succeeded, 1 if any failed.

set -u  # no `set -e` — we want to keep going on individual failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_JSON="$ROOT/deployments/5003.json"
ENV_FILE="$ROOT/.env"

# ─── prerequisites ──────────────────────────────────────────────────────────

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: '$1' not found on PATH." >&2
        exit 1
    fi
}
require forge
require cast
require jq

if [[ ! -f "$DEPLOY_JSON" ]]; then
    echo "ERROR: $DEPLOY_JSON not found. Deploy first:" >&2
    echo "  forge script script/Deploy.s.sol --rpc-url \$MANTLE_SEPOLIA_RPC --broadcast" >&2
    exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found. Need MANTLESCAN_KEY." >&2
    exit 1
fi

# shellcheck source=/dev/null
set -a; . "$ENV_FILE"; set +a

if [[ -z "${MANTLESCAN_KEY:-}" ]]; then
    echo "ERROR: MANTLESCAN_KEY not set in .env" >&2
    exit 1
fi

# ─── constants (must match script/Deploy.s.sol) ─────────────────────────────

# Deployer = vm.addr(DEPLOYER_PRIVATE_KEY). Hard-coded here so we don't have to
# re-derive it; if the key in .env changes, update this address too (or
# regenerate via: cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY").
DEPLOYER="0x648674aA2a0Cd6A8d57B19a7741072A6aBd8466E"

PYTH_MANTLE_SEPOLIA="0x98046Bd286715D3B0BC227Dd7a956b83D8978603"
MANTLE_SEPOLIA_METH="0x9EF6f9160Ba00B6621e5CB3217BB8b54a92B2828"

ETH_USD_FEED="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"
NVDA_FEED="0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593"
SPY_FEED="0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5"
AAPL_FEED="0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688"
TSLA_FEED="0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1"
MSFT_FEED="0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1"

EQUITY_MAX_STALE=345600   # 96 hours, from Deploy.s.sol's EQUITY_MAX_STALE
CRYPTO_MAX_STALE=60       # 60 s, from Deploy.s.sol's CRYPTO_MAX_STALE

# Registry params (from Deploy.s.sol RegistryParams struct literal).
DEFAULT_LOCKUP_DAYS=180
DEFAULT_SUBORDINATION_BPS=4000
DEFAULT_FOUNDER_SHARE_BPS=2000

# ─── addresses from deployments/5003.json ──────────────────────────────────

addr() { jq -r --arg k "$1" '.[$k] // empty' "$DEPLOY_JSON"; }

USDC=$(addr usdc)
TIME_PROVIDER=$(addr timeProvider)
TREASURY=$(addr treasury)
PYTH_ADAPTER=$(addr pythAdapter)
METH_ADAPTER=$(addr mEthAdapter)
USDY_ADAPTER=$(addr usdyAdapter)
AGENT_TOKEN_IMPL=$(addr agentTokenImpl)
AGENT_VAULT_IMPL=$(addr agentVaultImpl)
FOUNDER_VAULT_IMPL=$(addr founderVaultImpl)
AGENT_NFT=$(addr agentNFT)
HARVESTER=$(addr harvester)
DISTRIBUTOR=$(addr distributor)
REDEMPTION_QUEUE=$(addr redemptionQueue)
REGISTRY=$(addr registry)
S_NVDA=$(addr sNVDA)
S_SPY=$(addr sSPY)
S_AAPL=$(addr sAAPL)
S_TSLA=$(addr sTSLA)
S_MSFT=$(addr sMSFT)

# ─── verify driver ──────────────────────────────────────────────────────────

TOTAL=19
IDX=0
VERIFIED=0
FAILED=0

# Args: <display-name> <address> <source-path:ContractName> [<abi-encoded-args>]
verify_one() {
    local name="$1" address="$2" path="$3" ctor_args="${4:-}"
    IDX=$((IDX+1))
    echo ""
    echo "Verifying $name ($IDX/$TOTAL) — $address"

    if [[ -z "$address" || "$address" == "null" ]]; then
        echo "  ❌ Failed: address missing in deployments/5003.json"
        FAILED=$((FAILED+1))
        return
    fi

    local -a cmd=(forge verify-contract
        --chain mantle-sepolia
        --watch
        --etherscan-api-key "$MANTLESCAN_KEY")
    if [[ -n "$ctor_args" ]]; then
        cmd+=(--constructor-args "$ctor_args")
    fi
    cmd+=("$address" "$path")

    if "${cmd[@]}"; then
        echo "  ✅ Verified"
        VERIFIED=$((VERIFIED+1))
    else
        echo "  ❌ Failed: forge verify-contract returned non-zero (see output above)"
        FAILED=$((FAILED+1))
    fi
}

# Helper: encode constructor args with cast abi-encode, swallowing the trailing
# newline. Use single argument quoting from caller side.
enc() { cast abi-encode "$@"; }

# ─── 1. MockERC20 (USDC) ────────────────────────────────────────────────────
ARGS=$(enc 'constructor(string,string,uint8)' 'USD Coin' 'USDC' 6)
verify_one "MockERC20 (usdc)" "$USDC" "test/mocks/MockERC20.sol:MockERC20" "$ARGS"

# ─── 2. TimeProvider ────────────────────────────────────────────────────────
verify_one "TimeProvider" "$TIME_PROVIDER" "src/system/TimeProvider.sol:TimeProvider"

# ─── 3. PlatformTreasury ────────────────────────────────────────────────────
ARGS=$(enc 'constructor(address,address)' "$USDC" "$DEPLOYER")
verify_one "PlatformTreasury" "$TREASURY" "src/system/PlatformTreasury.sol:PlatformTreasury" "$ARGS"

# ─── 4. PythPriceAdapter ────────────────────────────────────────────────────
# Constructor takes (pyth, bytes32[5] feeds, uint64[5] staleness).
ARGS=$(enc 'constructor(address,bytes32[],uint64[])' \
    "$PYTH_MANTLE_SEPOLIA" \
    "[$NVDA_FEED,$SPY_FEED,$AAPL_FEED,$TSLA_FEED,$MSFT_FEED]" \
    "[$EQUITY_MAX_STALE,$EQUITY_MAX_STALE,$EQUITY_MAX_STALE,$EQUITY_MAX_STALE,$EQUITY_MAX_STALE]")
verify_one "PythPriceAdapter" "$PYTH_ADAPTER" "src/adapters/PythPriceAdapter.sol:PythPriceAdapter" "$ARGS"

# ─── 5. MantleMETHAdapter ───────────────────────────────────────────────────
ARGS=$(enc 'constructor(address,address,bytes32,address,uint64,address)' \
    "$USDC" "$PYTH_MANTLE_SEPOLIA" "$ETH_USD_FEED" "$MANTLE_SEPOLIA_METH" \
    "$CRYPTO_MAX_STALE" "$TIME_PROVIDER")
verify_one "MantleMETHAdapter" "$METH_ADAPTER" "src/adapters/MantleMETHAdapter.sol:MantleMETHAdapter" "$ARGS"

# ─── 6. OndoUSDYAdapter ─────────────────────────────────────────────────────
ARGS=$(enc 'constructor(address,address)' "$USDC" "$TIME_PROVIDER")
verify_one "OndoUSDYAdapter" "$USDY_ADAPTER" "src/adapters/OndoUSDYAdapter.sol:OndoUSDYAdapter" "$ARGS"

# ─── 7-9. Clone implementations (no constructor args) ──────────────────────
# Each calls _disableInitializers() in its constructor, no parameters.
verify_one "AgentToken impl" "$AGENT_TOKEN_IMPL" "src/core/AgentToken.sol:AgentToken"
verify_one "AgentVault impl" "$AGENT_VAULT_IMPL" "src/core/AgentVault.sol:AgentVault"
verify_one "FounderVault impl" "$FOUNDER_VAULT_IMPL" "src/core/FounderVault.sol:FounderVault"

# ─── 10. AgentNFT ───────────────────────────────────────────────────────────
# AgentNFT(registry_, admin_) — but Deploy.s.sol passes predictedRegistry which
# == the actual deployed REGISTRY address. We use REGISTRY here.
ARGS=$(enc 'constructor(address,address)' "$REGISTRY" "$DEPLOYER")
verify_one "AgentNFT" "$AGENT_NFT" "src/system/AgentNFT.sol:AgentNFT" "$ARGS"

# ─── 11. YieldHarvester ─────────────────────────────────────────────────────
# YieldHarvester(executor_, registry_, usdc_, timeProvider_)
ARGS=$(enc 'constructor(address,address,address,address)' \
    "$DEPLOYER" "$REGISTRY" "$USDC" "$TIME_PROVIDER")
verify_one "YieldHarvester" "$HARVESTER" "src/yield/YieldHarvester.sol:YieldHarvester" "$ARGS"

# ─── 12. DividendDistributor ────────────────────────────────────────────────
# DividendDistributor(harvester_, registry_, usdc_, timeProvider_)
ARGS=$(enc 'constructor(address,address,address,address)' \
    "$HARVESTER" "$REGISTRY" "$USDC" "$TIME_PROVIDER")
verify_one "DividendDistributor" "$DISTRIBUTOR" "src/yield/DividendDistributor.sol:DividendDistributor" "$ARGS"

# ─── 13. RedemptionQueue ────────────────────────────────────────────────────
# RedemptionQueue(admin_, registry_, timeProvider_)
ARGS=$(enc 'constructor(address,address,address)' \
    "$DEPLOYER" "$REGISTRY" "$TIME_PROVIDER")
verify_one "RedemptionQueue" "$REDEMPTION_QUEUE" "src/system/RedemptionQueue.sol:RedemptionQueue" "$ARGS"

# ─── 14. HelmRegistry ───────────────────────────────────────────────────────
# Constructor takes a single RegistryParams struct (16 fields). Field order
# must match the struct declaration in HelmRegistry.sol:
#   (admin, usdc, redemptionQueue, treasury, yieldHarvester, pythAdapter,
#    executor, distributor, agentNFT, timeProvider, agentTokenImpl,
#    agentVaultImpl, founderVaultImpl,
#    defaultLockupDays, defaultSubordinationBps, defaultFounderShareBps)
ARGS=$(enc 'constructor((address,address,address,address,address,address,address,address,address,address,address,address,address,uint64,uint16,uint16))' \
    "($DEPLOYER,$USDC,$REDEMPTION_QUEUE,$TREASURY,$HARVESTER,$PYTH_ADAPTER,$DEPLOYER,$DISTRIBUTOR,$AGENT_NFT,$TIME_PROVIDER,$AGENT_TOKEN_IMPL,$AGENT_VAULT_IMPL,$FOUNDER_VAULT_IMPL,$DEFAULT_LOCKUP_DAYS,$DEFAULT_SUBORDINATION_BPS,$DEFAULT_FOUNDER_SHARE_BPS)")
verify_one "HelmRegistry" "$REGISTRY" "src/system/HelmRegistry.sol:HelmRegistry" "$ARGS"

# ─── 15-19. SyntheticAsset × 5 ──────────────────────────────────────────────
# Constructor: (name, symbol, underlyingSymbol, pythFeedId, priceAdapter, usdc)
verify_synth() {
    local addr="$1" name="$2" symbol="$3" underlying="$4" feed="$5"
    local args
    args=$(enc 'constructor(string,string,string,bytes32,address,address)' \
        "$name" "$symbol" "$underlying" "$feed" "$PYTH_ADAPTER" "$USDC")
    verify_one "SyntheticAsset ($symbol)" "$addr" "src/adapters/SyntheticAsset.sol:SyntheticAsset" "$args"
}

verify_synth "$S_NVDA" "Synthetic NVIDIA"    "sNVDA" "NVDA" "$NVDA_FEED"
verify_synth "$S_SPY"  "Synthetic S&P 500"   "sSPY"  "SPY"  "$SPY_FEED"
verify_synth "$S_AAPL" "Synthetic Apple"     "sAAPL" "AAPL" "$AAPL_FEED"
verify_synth "$S_TSLA" "Synthetic Tesla"     "sTSLA" "TSLA" "$TSLA_FEED"
verify_synth "$S_MSFT" "Synthetic Microsoft" "sMSFT" "MSFT" "$MSFT_FEED"

# ─── summary ────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "Verified: $VERIFIED/$TOTAL, Failed: $FAILED/$TOTAL"
echo "============================================================"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
