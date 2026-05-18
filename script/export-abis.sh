#!/usr/bin/env bash
# Regenerate frontend-package/abis/<Name>.json from Foundry's out/<Name>.sol/<Name>.json,
# keeping only the `abi` field (no bytecode, no metadata).
#
# Run after every `forge build` if any ABI surface changed:
#   ./script/export-abis.sh
#
# Adding a contract: append its name to CONTRACTS below.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/out"
DEST_DIR="$ROOT/frontend-package/abis"

CONTRACTS=(
  AgentToken
  AgentVault
  FounderVault
  HelmRegistry
  RedemptionQueue
  DividendDistributor
  YieldHarvester
  PlatformTreasury
  PythPriceAdapter
  SyntheticAsset
  MantleMETHAdapter
  OndoUSDYAdapter
  MockERC20
  AgentNFT
  TimeProvider
)

mkdir -p "$DEST_DIR"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

missing=()
for name in "${CONTRACTS[@]}"; do
  src="$OUT_DIR/$name.sol/$name.json"
  dst="$DEST_DIR/$name.json"
  if [[ ! -f "$src" ]]; then
    missing+=("$name")
    continue
  fi
  jq '.abi' "$src" > "$dst"
  echo "wrote $dst"
done

if (( ${#missing[@]} > 0 )); then
  echo
  echo "warning: the following ABIs were not found (run 'forge build' first):" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

echo
echo "done — ${#CONTRACTS[@]} ABIs exported to $DEST_DIR"
