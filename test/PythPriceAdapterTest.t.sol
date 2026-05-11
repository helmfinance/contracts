// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/adapters/PythPriceAdapter.sol";
import "./mocks/MockPyth.sol";

contract PythPriceAdapterTest is Test {
    PythPriceAdapter adapter;
    MockPyth mockPyth;

    bytes32 constant CRYPTO_FEED = keccak256("ETH/USD");
    bytes32 constant EQUITY_FEED = keccak256("sNVDA/USD");
    bytes32 constant UNKNOWN_FEED = keccak256("UNKNOWN");

    uint64 constant CRYPTO_STALENESS = 60;
    uint64 constant EQUITY_STALENESS = 96 hours;
    uint256 constant UPDATE_FEE = 1 wei;

    function setUp() public {
        mockPyth = new MockPyth(UPDATE_FEE);

        bytes32[] memory feedIds = new bytes32[](2);
        uint64[] memory maxStale = new uint64[](2);
        feedIds[0] = CRYPTO_FEED;
        maxStale[0] = CRYPTO_STALENESS;
        feedIds[1] = EQUITY_FEED;
        maxStale[1] = EQUITY_STALENESS;

        adapter = new PythPriceAdapter(address(mockPyth), feedIds, maxStale);
    }

    // ---------------------------------------------------------------
    // getPrice — fresh feed returns normalized 1e18 price
    // ---------------------------------------------------------------

    function test_getPrice_freshFeed_negativeExpo() public {
        // ETH = 3123.45678900 USD (expo=-8, raw=312345678900)
        // But int64 max is ~9.2e18, so use a smaller example:
        // ETH = 3123.45 USD → raw=312345, expo=-2
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 312345, 100, -2, 1000);

        (uint256 price, uint8 decimals, uint64 publishTime) = adapter.getPrice(CRYPTO_FEED);

        // 312345 * 10^(-2+18) = 312345 * 10^16 = 3_123_450_000_000_000_000_000
        assertEq(price, 312345 * 1e16);
        assertEq(decimals, 18);
        assertEq(publishTime, 1000);
    }

    // ---------------------------------------------------------------
    // getPriceUsdc — normalized to 6 decimals
    // ---------------------------------------------------------------

    function test_getPriceUsdc_freshFeed() public {
        // NVDA = 950.12 USD → raw=95012, expo=-2
        vm.warp(1000);
        mockPyth.setPrice(EQUITY_FEED, 95012, 50, -2, 1000);

        uint256 price = adapter.getPriceUsdc(EQUITY_FEED);

        // 95012 * 10^(-2+6) = 95012 * 10^4 = 950_120_000
        assertEq(price, 950_120_000);
    }

    // ---------------------------------------------------------------
    // Negative expo (standard case, expo=-5)
    // ---------------------------------------------------------------

    function test_getPriceUsdc_negativeExpo5() public {
        // price=12345, expo=-5 → actual = 0.12345 USD
        // USDC: 0.12345 * 1e6 = 123_450
        // formula: 12345 * 10^(-5+6) = 12345 * 10^1 = 123_450
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 12345, 10, -5, 1000);

        uint256 price = adapter.getPriceUsdc(CRYPTO_FEED);
        assertEq(price, 123_450);
    }

    function test_getPrice_negativeExpo5() public {
        // Same feed but in 1e18: 12345 * 10^(-5+18) = 12345 * 10^13
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 12345, 10, -5, 1000);

        (uint256 price,,) = adapter.getPrice(CRYPTO_FEED);
        assertEq(price, 12345 * 1e13);
    }

    // ---------------------------------------------------------------
    // Negative expo resulting in truncation (expo=-8, target=6)
    // ---------------------------------------------------------------

    function test_getPriceUsdc_negativeExpo8_truncates() public {
        // price=312345678, expo=-8 → actual = 3.12345678 USD
        // USDC: 3.12345678 * 1e6 = 3_123_456.78 → truncates to 3_123_456
        // formula: 312345678 * 10^(-8+6) = 312345678 / 100 = 3_123_456
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 312345678, 10, -8, 1000);

        uint256 price = adapter.getPriceUsdc(CRYPTO_FEED);
        assertEq(price, 3_123_456);
    }

    // ---------------------------------------------------------------
    // Positive expo (edge case for very small-unit prices)
    // ---------------------------------------------------------------

    function test_getPriceUsdc_positiveExpo() public {
        // price=5, expo=2 → actual = 500 USD
        // USDC: 500 * 1e6 = 500_000_000
        // formula: 5 * 10^(2+6) = 5 * 10^8 = 500_000_000
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 5, 1, 2, 1000);

        uint256 price = adapter.getPriceUsdc(CRYPTO_FEED);
        assertEq(price, 500_000_000);
    }

    function test_getPrice_positiveExpo() public {
        // 1e18 scale: 5 * 10^(2+18) = 5 * 10^20 = 500_000_000_000_000_000_000
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 5, 1, 2, 1000);

        (uint256 price,,) = adapter.getPrice(CRYPTO_FEED);
        assertEq(price, 5 * 1e20);
    }

    // ---------------------------------------------------------------
    // Stale feed — per-feed window
    // ---------------------------------------------------------------

    function test_getPrice_revertsStaleCrypto() public {
        vm.warp(1000);
        // Published 61 seconds ago (> 60s crypto window)
        mockPyth.setPrice(CRYPTO_FEED, 312345, 100, -2, 939);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPythPriceAdapter.PriceStale.selector,
                CRYPTO_FEED,
                uint64(939),
                uint64(CRYPTO_STALENESS)
            )
        );
        adapter.getPrice(CRYPTO_FEED);
    }

    function test_getPrice_equityFeedNotStaleWithinWindow() public {
        uint256 now_ = 500_000;
        vm.warp(now_);
        // Published 95 hours ago — within the 96h equity window
        uint256 publishTime = now_ - 95 hours;
        mockPyth.setPrice(EQUITY_FEED, 95012, 50, -2, publishTime);

        (uint256 price,,) = adapter.getPrice(EQUITY_FEED);
        assertGt(price, 0);
    }

    function test_getPrice_equityFeedStaleOutsideWindow() public {
        uint256 base = 500_000;
        vm.warp(base + 97 hours);
        // Published at t=base, now t=base+97h → 97h > 96h
        mockPyth.setPrice(EQUITY_FEED, 95012, 50, -2, base);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPythPriceAdapter.PriceStale.selector,
                EQUITY_FEED,
                uint64(base),
                uint64(EQUITY_STALENESS)
            )
        );
        adapter.getPrice(EQUITY_FEED);
    }

    function test_getPriceUsdc_revertsStale() public {
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 312345, 100, -2, 900);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPythPriceAdapter.PriceStale.selector,
                CRYPTO_FEED,
                uint64(900),
                uint64(CRYPTO_STALENESS)
            )
        );
        adapter.getPriceUsdc(CRYPTO_FEED);
    }

    // ---------------------------------------------------------------
    // Unknown feed
    // ---------------------------------------------------------------

    function test_getPrice_revertsUnknownFeed() public {
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceAdapter.UnknownFeed.selector, UNKNOWN_FEED)
        );
        adapter.getPrice(UNKNOWN_FEED);
    }

    function test_getPriceUsdc_revertsUnknownFeed() public {
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceAdapter.UnknownFeed.selector, UNKNOWN_FEED)
        );
        adapter.getPriceUsdc(UNKNOWN_FEED);
    }

    function test_getPriceWithMaxAge_revertsUnknownFeed() public {
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceAdapter.UnknownFeed.selector, UNKNOWN_FEED)
        );
        adapter.getPriceWithMaxAge(UNKNOWN_FEED, 60);
    }

    // ---------------------------------------------------------------
    // Negative price
    // ---------------------------------------------------------------

    function test_getPrice_revertsNegativePrice() public {
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, -100, 10, -2, 1000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPythPriceAdapter.PriceNegative.selector,
                CRYPTO_FEED,
                int256(-100)
            )
        );
        adapter.getPrice(CRYPTO_FEED);
    }

    // ---------------------------------------------------------------
    // getPriceWithMaxAge
    // ---------------------------------------------------------------

    function test_getPriceWithMaxAge_fresh() public {
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 312345, 100, -2, 995);

        uint256 price = adapter.getPriceWithMaxAge(CRYPTO_FEED, 10);
        assertEq(price, 312345 * 1e16);
    }

    function test_getPriceWithMaxAge_revertsStale() public {
        vm.warp(1000);
        mockPyth.setPrice(CRYPTO_FEED, 312345, 100, -2, 980);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPythPriceAdapter.PriceStale.selector,
                CRYPTO_FEED,
                uint64(980),
                uint64(10)
            )
        );
        adapter.getPriceWithMaxAge(CRYPTO_FEED, 10);
    }

    // ---------------------------------------------------------------
    // updatePriceFeeds — forwards msg.value
    // ---------------------------------------------------------------

    function test_updatePriceFeeds_forwardsValue() public {
        bytes[] memory data = new bytes[](1);
        data[0] = hex"01";

        adapter.updatePriceFeeds{value: UPDATE_FEE}(data);

        assertEq(mockPyth.lastUpdateValue(), UPDATE_FEE);
    }

    function test_updatePriceFeeds_revertsInsufficientFee() public {
        bytes[] memory data = new bytes[](1);
        data[0] = hex"01";

        vm.expectRevert(
            abi.encodeWithSelector(
                IPythPriceAdapter.InsufficientUpdateFee.selector,
                uint256(0),
                UPDATE_FEE
            )
        );
        adapter.updatePriceFeeds{value: 0}(data);
    }

    function test_updatePriceFeeds_forwardsExcessValue() public {
        bytes[] memory data = new bytes[](1);
        data[0] = hex"01";

        uint256 excess = 100 wei;
        adapter.updatePriceFeeds{value: excess}(data);

        // All msg.value forwarded to pyth
        assertEq(mockPyth.lastUpdateValue(), excess);
    }

    // ---------------------------------------------------------------
    // getUpdateFee
    // ---------------------------------------------------------------

    function test_getUpdateFee() public view {
        bytes[] memory data = new bytes[](1);
        data[0] = hex"01";

        uint256 fee = adapter.getUpdateFee(data);
        assertEq(fee, UPDATE_FEE);
    }
}
