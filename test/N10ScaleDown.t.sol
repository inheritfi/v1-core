// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// N-10: _scaleDown must keep the three delegate-weight rules after any shrink:
// (1) active weights sum exactly 100, (2) every weight >= 1, (3) every weight <= 50.
contract N10ScaleDownTest is Test {
    InheritfiV1ETH eth;

    function setUp() public {
        eth = new InheritfiV1ETH();
        eth.setMaxDelegates(50);
    }

    function _d(uint256 i) internal returns (address) {
        return makeAddr(string.concat("delegate", vm.toString(i)));
    }

    // Builds a roster of n delegates with the same weight pattern as M06GasMeasure.
    function _build(uint256 n) internal {
        for (uint256 k; k < n; k++) {
            address d = _d(k);
            eth.addDelegate(d, k < 2 ? 50 : 100 / (k + 1));
            vm.prank(d);
            eth.acceptDelegate();
        }
    }

    function _assertRules() internal view {
        address[] memory list = eth.getDelegates();
        uint256 sum;
        for (uint256 i; i < list.length; i++) {
            (,, uint256 w,,,) = eth.delegates(list[i]);
            assertGe(w, 1, "rule 2: weight >= 1");
            assertLe(w, 50, "rule 3: weight <= 50");
            sum += w;
        }
        assertEq(sum, 100, "rule 1: sum == 100");
    }

    // Formerly reverted (before N-10): raising a delegate to 50 in a 40-delegate roster.
    function test_raiseToMax_n40() public {
        _build(40);
        eth.setDelegateWeight(_d(39), 50);
        (,, uint256 w,,,) = eth.delegates(_d(39));
        assertEq(w, 50);
        _assertRules();
    }

    // Formerly reverted (before N-10): one delegate at 50, the rest near 1, then a second raised to 50.
    function test_twoAtMax_n49() public {
        _build(49);
        eth.setDelegateWeight(_d(0), 50);
        _assertRules();
        eth.setDelegateWeight(_d(1), 50);
        _assertRules();
    }

    // A newcomer offered the maximum weight joins a 40-delegate roster.
    function test_acceptHeavy_n40() public {
        _build(40);
        address d = _d(40);
        eth.addDelegate(d, 50);
        vm.prank(d);
        eth.acceptDelegate();
        _assertRules();
    }

    // Random weight changes (up and down) on rosters of 10 to 50 delegates.
    function testFuzz_rulesHold(uint256 seed) public {
        uint256 n = 10 + (seed % 41);
        _build(n);
        _assertRules();
        for (uint256 k; k < 12; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address d = _d(r % n);
            uint256 w = 1 + ((r >> 8) % 50);
            eth.setDelegateWeight(d, w);
            (,, uint256 got,,,) = eth.delegates(d);
            assertEq(got, w, "requested weight applied");
            _assertRules();
        }
    }
}
