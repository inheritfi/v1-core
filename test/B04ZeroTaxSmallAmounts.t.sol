// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";
import "../src/InheritfiV1UNI.sol";
import "../src/InheritfiV1WBTC.sol";

// Minimal ERC-20 with configurable decimals, used as the UNI (18) and WBTC (8) underlying.
contract B04MockToken is ERC20 {
    uint8 private immutable dec;
    constructor(uint8 d) ERC20("Mock", "MCK") { dec = d; }
    function decimals() public view override returns (uint8) { return dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// B-04: wrap and unwrap no longer require a non-zero tax. Amounts whose tax rounds
// down to zero go through tax-free, as already happens in the inheritance and
// recovery paths; a zero amount still reverts.
contract B04ZeroTaxSmallAmountsTest is Test {
    InheritfiV1ETH eth;
    InheritfiV1UNI uni;
    InheritfiV1WBTC wbtc;
    B04MockToken mUni;
    B04MockToken mBtc;
    address U = makeAddr("user");

    function setUp() public {
        eth = new InheritfiV1ETH();
        mUni = new B04MockToken(18);
        mBtc = new B04MockToken(8);
        uni = new InheritfiV1UNI(address(mUni));
        wbtc = new InheritfiV1WBTC(address(mBtc));
        vm.deal(U, 1 ether);
        mUni.mint(U, 1e18);
        mBtc.mint(U, 1e8);
        vm.startPrank(U);
        mUni.approve(address(uni), type(uint256).max);
        mBtc.approve(address(wbtc), type(uint256).max);
        vm.stopPrank();
    }

    // Largest amount whose tax rounds down to zero for both rates (basis points).
    function _tiny(uint256 r1, uint256 r2) internal pure returns (uint256) {
        uint256 r = r1 > r2 ? r1 : r2;
        return (10_000 - 1) / r;
    }

    // ETH: a tiny wrap and unwrap go through with zero tax.
    function test_eth_smallAmounts_taxFree() public {
        uint256 a = _tiny(eth.wrappingTax(), eth.unwrappingTax());
        vm.prank(U);
        eth.wrap{value: a}();
        assertEq(eth.balanceOf(U), a, "wrap: full amount, zero tax");
        uint256 before = U.balance;
        vm.prank(U);
        eth.unwrap(a);
        assertEq(U.balance - before, a, "unwrap: full amount, zero tax");
        assertEq(eth.accumulatedTax(), 0);
    }

    // ERC-20 (18 decimals): same behaviour.
    function test_uni_smallAmounts_taxFree() public {
        uint256 a = _tiny(uni.wrappingTax(), uni.unwrappingTax());
        vm.prank(U);
        uni.wrap(a);
        assertEq(uni.balanceOf(U), a, "wrap: full amount, zero tax");
        vm.prank(U);
        uni.unwrap(a);
        assertEq(mUni.balanceOf(U), 1e18, "unwrap: full amount back, zero tax");
        assertEq(uni.accumulatedTax(), 0);
    }

    // WBTC (8 decimals) at 1 basis point: the former 10,000-satoshi minimum is gone.
    function test_wbtc_lowRate_noGrowingMinimum() public {
        wbtc.setWrappingTax(1);
        wbtc.setUnwrappingTax(1);
        uint256 a = _tiny(wbtc.wrappingTax(), wbtc.unwrappingTax());
        assertEq(a, 9_999);
        vm.prank(U);
        wbtc.wrap(a);
        assertEq(wbtc.balanceOf(U), a, "wrap: full amount, zero tax");
        vm.prank(U);
        wbtc.unwrap(a);
        assertEq(mBtc.balanceOf(U), 1e8, "all satoshis back");
        assertEq(wbtc.accumulatedTax(), 0);
    }

    // Amounts above the rounding threshold are still taxed.
    function test_aboveThreshold_stillTaxed() public {
        vm.prank(U);
        eth.wrap{value: 1 ether}();
        uint256 expectedTax = (1 ether * eth.wrappingTax()) / 10_000;
        assertGt(expectedTax, 0);
        assertEq(eth.accumulatedTax(), expectedTax);
        assertEq(eth.balanceOf(U), 1 ether - expectedTax);
    }

    // A zero amount still reverts.
    function test_zeroAmounts_stillRevert() public {
        vm.prank(U);
        vm.expectRevert(bytes("No ETH"));
        eth.wrap{value: 0}();
        vm.prank(U);
        vm.expectRevert(bytes("Zero amount"));
        eth.unwrap(0);
        vm.prank(U);
        vm.expectRevert(bytes("Zero amount"));
        uni.wrap(0);
        vm.prank(U);
        vm.expectRevert(bytes("Zero amount"));
        wbtc.unwrap(0);
    }
}
