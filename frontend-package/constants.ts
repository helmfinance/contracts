// Helm protocol — shared frontend constants.
// Numeric enum values are on-chain (uint8) and MUST match the Solidity layout.

/** Lockup tier the user selects when requesting a redemption. */
export enum LockupTier {
  Instant = 0,
  Day30 = 1,
  Day60 = 2,
  Day90 = 3,
}

/** Agent lifecycle phase as exposed by AgentVault. */
export enum Phase {
  Incubation = 0,
  PublicLaunch = 1,
  WindDown = 2,
  Settled = 3,
}

/** Platform fee classes accrued in USDC by PlatformTreasury. */
export enum FeeKind {
  Mint = 0,
  Redeem = 1,
  Rebalance = 2,
}

/** Default fee rates in basis points. Read on-chain for the live values. */
export const FEE_RATES = {
  mint: 50,
  redeem: 50,
  rebalance: 5,
} as const;

/** Basis-points denominator (10_000 = 100.00%). */
export const BPS_SCALE = 10_000;

/** Token decimals. */
export const USDC_DECIMALS = 6;
export const AGT_DECIMALS = 18;

/** Lifecycle windows (days). */
export const INCUBATION_PERIOD_DAYS = 30;
export const DEFAULT_LOCKUP_DAYS = 180;
export const SENIOR_WINDOW_DAYS = 90;

/** Minimum founder seed required at incubation start. 1000 USDC = 1_000e6. */
export const MIN_SEED_USDC = 1_000n * 10n ** BigInt(USDC_DECIMALS);

/** Chain. */
export const MANTLE_SEPOLIA_CHAIN_ID = 5003;

/** Pyth price feed IDs (bytes32). Use with PythPriceAdapter / Pyth.getPrice. */
export const PYTH_PRICE_FEEDS = {
  NVDA:    "0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593",
  SPY:     "0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5",
  AAPL:    "0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688",
  TSLA:    "0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1",
  MSFT:    "0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1",
  ETH_USD: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
} as const;
