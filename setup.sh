#!/usr/bin/env bash
# Run from inside contracts/ directory.
# Installs all forge dependencies and verifies the project builds.
# Compatible with Foundry 1.x (no-commit is the default behavior).
set -euo pipefail

if ! command -v forge &> /dev/null; then
  echo "✗ forge not found. Install Foundry first: https://getfoundry.sh"
  exit 1
fi

cd "$(dirname "$0")"

if [ ! -d lib/forge-std ]; then
  echo "→ Installing forge-std..."
  forge install foundry-rs/forge-std
fi

if [ ! -d lib/openzeppelin-contracts ]; then
  echo "→ Installing OpenZeppelin Contracts v5..."
  forge install OpenZeppelin/openzeppelin-contracts
fi

if [ ! -d lib/pyth-sdk-solidity ]; then
  echo "→ Installing Pyth SDK..."
  forge install pyth-network/pyth-sdk-solidity
fi

echo "→ Building..."
forge build

echo ""
echo "✓ contracts/ ready."
echo "  Next: forge test -vvv"