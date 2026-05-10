// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Minimal IPyth surface for verification. The full SDK lives in
///         lib/pyth-sdk-solidity once forge install runs, but for an isolated
///         verification we keep a local interface to avoid the install dance.
interface IPythMinimal {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);
}

/// @title PythVerify
/// @notice Reads ./pyth_update.json (produced by verify.py), pushes the bundled
///         update payload to the Mantle Sepolia Pyth contract, and reads back
///         NVDA + SPY prices to confirm the full loop works end-to-end.
/// @dev    Run with:
///           forge script script/PythVerify.s.sol \
///             --rpc-url $MANTLE_SEPOLIA_RPC \
///             --broadcast \
///             --skip-simulation
///
///         `--skip-simulation` is important: forge's local sim doesn't have the
///         Pyth contract state, so it would revert. The actual broadcast against
///         Mantle Sepolia works fine.
contract PythVerify is Script {
    function run() external {
        // --- 1. Load JSON produced by verify.py -------------------------------
        string memory json = vm.readFile("./pyth_update.json");

        address pythAddr = vm.parseJsonAddress(json, ".pyth_contract_mantle_sepolia");
        IPythMinimal pyth = IPythMinimal(pythAddr);

        bytes32 nvdaId = vm.parseJsonBytes32(json, ".feeds.NVDA.feed_id");
        bytes32 spyId  = vm.parseJsonBytes32(json, ".feeds.SPY.feed_id");

        // binary_update_hex is a JSON array of hex strings (each is a VAA).
        bytes[] memory updateData = vm.parseJsonBytesArray(json, ".binary_update_hex");

        console2.log("Pyth contract:", pythAddr);
        console2.log("NVDA feed:");
        console2.logBytes32(nvdaId);
        console2.log("SPY feed:");
        console2.logBytes32(spyId);
        console2.log("Update VAA count:", updateData.length);

        // --- 2. Push the update on-chain --------------------------------------
        uint256 fee = pyth.getUpdateFee(updateData);
        console2.log("Update fee (wei):", fee);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        pyth.updatePriceFeeds{value: fee}(updateData);
        vm.stopBroadcast();

        // --- 3. Read prices back ----------------------------------------------
        IPythMinimal.Price memory nvda = pyth.getPriceUnsafe(nvdaId);
        IPythMinimal.Price memory spy  = pyth.getPriceUnsafe(spyId);

        console2.log("");
        console2.log("=== Result ===");
        console2.log("NVDA price (raw):", uint256(uint64(nvda.price)));
        console2.log("NVDA expo:", int256(nvda.expo));
        console2.log("NVDA publishTime:", nvda.publishTime);
        console2.log("SPY price (raw):", uint256(uint64(spy.price)));
        console2.log("SPY expo:", int256(spy.expo));
        console2.log("SPY publishTime:", spy.publishTime);

        // --- 4. Liveness check ----------------------------------------------
        // Equity feeds (NVDA/SPY/...) freeze at last close when US markets are
        // shut, so a 60s window would revert on weekends/holidays. 4 days
        // covers any normal market closure. In production, PythPriceAdapter
        // sets per-feed staleness: 60s for crypto, 4 days for equities.
        uint256 maxAgeEquity = 4 days;
        IPythMinimal.Price memory nvdaFresh = pyth.getPriceNoOlderThan(nvdaId, maxAgeEquity);
        console2.log("NVDA fresh-read OK, raw price:", uint256(uint64(nvdaFresh.price)));
        console2.log("");
        console2.log("VERIFICATION PASSED.");
    }
}
