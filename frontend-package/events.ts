// Helm protocol — event signatures + topic0 hashes for the events the FE
// commonly filters on. topic0 = keccak256(canonical_signature).
//
// Canonical signature = "EventName(t1,t2,...)" with no spaces and resolved
// types (tuple/uint256 etc., not the human-readable struct names). These are
// what eth_getLogs expects as the first topic when filtering.

export interface EventDescriptor {
  /** Source contract name (matches abis/<name>.json). */
  contract:
    | "AgentVault"
    | "HelmRegistry"
    | "AgentNFT"
    | "DividendDistributor"
    | "RedemptionQueue"
    | "PlatformTreasury";
  /** keccak256(signature). Use as topics[0] in eth_getLogs. */
  topic0: `0x${string}`;
  /** Canonical event signature. */
  signature: string;
  /** Friendly description for docs / dev tools. */
  description: string;
}

export const EVENTS = {
  // -----------------------------------------------------------------------
  // AgentVault (ERC-4626) — Deposit IS the mint event, Withdraw IS the redeem
  // event. Naming follows the underlying ERC-4626 spec; the README calls them
  // "Mint" / "Redeem" only in human-facing text.
  // -----------------------------------------------------------------------
  Deposit: {
    contract: "AgentVault",
    topic0: "0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7",
    signature: "Deposit(address,address,uint256,uint256)",
    description: "ERC-4626 deposit — user minted AGT shares from USDC.",
  },
  Withdraw: {
    contract: "AgentVault",
    topic0: "0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db",
    signature: "Withdraw(address,address,address,uint256,uint256)",
    description: "ERC-4626 withdraw — RedemptionQueue burned AGT for USDC.",
  },
  PhaseChanged: {
    contract: "AgentVault",
    topic0: "0xeeb345fea22465c927333e05d324ee5b476597701d8be7e5d9aacc60e7aefbaf",
    signature: "PhaseChanged(uint8,uint8)",
    description: "Vault phase transition (Incubation/PublicLaunch/WindDown/Settled).",
  },
  WindDownTriggered: {
    contract: "AgentVault",
    topic0: "0xedca7c1bd369fbde6a18289de469462b14511c3b9346359f5834781f846fb2c7",
    signature: "WindDownTriggered(address,string)",
    description: "Vault entered wind-down (manual call or slash cascade).",
  },
  Rebalanced: {
    contract: "AgentVault",
    topic0: "0x6be64df515f24f51ea8e3735bdc9788f1089c536704136682a136f1cc32f6dae",
    signature: "Rebalanced(bytes32,uint256,uint256)",
    description: "Executor rebalanced positions (sold/bought basket assets).",
  },
  Settled: {
    contract: "AgentVault",
    topic0: "0xf5b268a3ff315cc44ccceeef86259c9e8eef81ceecb14001543809115380dd62",
    signature: "Settled(uint256,uint256)",
    description: "Vault fully wound down; final USDC NAV recorded for claims.",
  },

  // -----------------------------------------------------------------------
  // HelmRegistry
  // -----------------------------------------------------------------------
  AgentRegistered: {
    contract: "HelmRegistry",
    topic0: "0xaf01a85dbf74fbfda869b3df92f2233273db6e6e551a0f5d105ff7a7f5f9f6f2",
    signature: "AgentRegistered(uint256,address,tuple)",
    description: "New agent registered; vault + token + NFT deployed.",
  },

  // -----------------------------------------------------------------------
  // AgentNFT
  // -----------------------------------------------------------------------
  AgentNFTMinted: {
    contract: "AgentNFT",
    topic0: "0xea2279465638ca852bd7f9c2150ea3da2363b4dad6c0abc10cbfad508e579292",
    signature: "AgentNFTMinted(uint256,address,uint256)",
    description: "Reputation NFT minted to the founder on registration.",
  },
  ReputationSlashed: {
    contract: "AgentNFT",
    topic0: "0xee704febe2eb1a693ebb94b0030a6643dd715725b63c2f6450e88c262395a474",
    signature: "ReputationSlashed(uint256,uint256,uint256,uint256,string)",
    description: "Reputation score reduced (mandate breach, poor performance, etc.).",
  },
  SlashTriggeredWindDown: {
    contract: "AgentNFT",
    topic0: "0xe5d8e19229d3080b4c2c8c6f342018e0769b884c791ecc0890ac288391ea2de2",
    signature: "SlashTriggeredWindDown(uint256,uint256)",
    description: "Slash threshold crossed; vault is being moved to WindDown.",
  },

  // -----------------------------------------------------------------------
  // DividendDistributor
  // -----------------------------------------------------------------------
  Distributed: {
    contract: "DividendDistributor",
    topic0: "0xfd90776b25b493b71087872e64e1eda50ed8b6c7dab4aa964f29683e6ae200df",
    signature: "Distributed(uint256,uint256,uint256,uint256,uint256,bytes32)",
    description: "Epoch dividend snapshot — yield/perf fees split into a claim tree.",
  },
  Claimed: {
    contract: "DividendDistributor",
    topic0: "0xd9cb1e2714d65a111c0f20f060176ad657496bd47a3de04ec7c3d4ca232112ac",
    signature: "Claimed(uint256,address,uint256,uint256)",
    description: "Holder claimed their epoch dividend.",
  },

  // -----------------------------------------------------------------------
  // RedemptionQueue
  // -----------------------------------------------------------------------
  RedeemRequested: {
    contract: "RedemptionQueue",
    topic0: "0x30a8eecbe96f2d70a26faa7f2fe199ae434715449a532a2c3ea972b6990e1f25",
    signature: "RedeemRequested(uint256,uint256,address,uint256,uint8,uint64)",
    description: "User locked AGT, requested redemption; unlock at the embedded timestamp.",
  },
  RedeemClaimed: {
    contract: "RedemptionQueue",
    topic0: "0x0868d8a19273a65b127e5f4e861778032a2eee0c1bf84595e252493bc84a9442",
    signature: "RedeemClaimed(uint256,uint256)",
    description: "User claimed the USDC payout after lockup elapsed.",
  },

  // -----------------------------------------------------------------------
  // PlatformTreasury
  // -----------------------------------------------------------------------
  FeeCollected: {
    contract: "PlatformTreasury",
    topic0: "0xdc072e626c3895013a694a72d1bcd1d6ace4c613dad7a6592154ee14b7e2b35a",
    signature: "FeeCollected(uint256,uint8,uint256)",
    description: "Platform fee accrued (Mint/Redeem/Rebalance, see FeeKind enum).",
  },
} as const satisfies Record<string, EventDescriptor>;

export type EventName = keyof typeof EVENTS;
