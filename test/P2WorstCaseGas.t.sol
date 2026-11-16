// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// Phase 2: worst-case gas of the user and owner paths whose cost grows with a list
// (heirs, recovery users, treasuries), with every list at its maximum (40 heirs,
// 50 recovery users, 40 treasuries), compared
// with the EIP-7825 per-transaction gas cap (16,777,216). Delegates are measured in
// M06GasMeasure. Each value is the execution gas of one call, measured like
// M06GasMeasure. It reports values and only asserts that every call succeeds and stays
// under the cap.
contract P2WorstCaseGasTest is Test {
    InheritfiV1ETH eth;
    uint256 constant TX_CAP = 16_777_216;
    uint256 constant N = 40; // cap of setMaxHeirs and setMaxTreasuries
    uint256 constant NR = 50; // cap of setMaxRecoveryUsers
    address T = makeAddr("testator");

    function setUp() public {
        eth = new InheritfiV1ETH();
        eth.setMaxHeirs(N);
        eth.setMaxRecoveryUsers(NR);
        eth.setMaxTreasuries(N);
        vm.deal(T, 1_000 ether);
        vm.prank(T);
        eth.wrap{value: 1_000 ether}();
    }

    function _a(string memory p, uint256 i) internal returns (address) {
        return makeAddr(string.concat(p, vm.toString(i)));
    }

    function _list(string memory p, uint256 n) internal returns (address[] memory w, uint256[] memory pct) {
        w = new address[](n);
        pct = new uint256[](n);
        for (uint256 i; i < n; i++) {
            w[i] = _a(p, i);
            pct[i] = 10_000 / n;
        }
    }

    function _measure(string memory label, address from, bytes memory data) internal returns (uint256 used) {
        vm.prank(from);
        uint256 g = gasleft();
        (bool ok,) = address(eth).call(data);
        used = g - gasleft();
        emit log_named_uint(label, used);
        assertTrue(ok, string.concat(label, ": reverted"));
        assertLt(used, TX_CAP, string.concat(label, ": above the EIP-7825 cap"));
    }

    function _heirs() internal {
        (address[] memory w, uint256[] memory p) = _list("heir", N);
        vm.prank(T);
        eth.setHeirs(w, p);
    }

    function _started() internal {
        _heirs();
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(_a("heir", 0));
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
    }

    function _claim(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; i++) {
            vm.prank(_a("heir", i));
            eth.executeInheritance(T);
        }
    }

    function test_heirs_set() public {
        (address[] memory w, uint256[] memory p) = _list("heir", N);
        _measure("setHeirs, 40 new heirs", T, abi.encodeCall(eth.setHeirs, (w, p)));
        (address[] memory w2, uint256[] memory p2) = _list("other", N);
        _measure("setHeirs, replace 40 heirs with 40 others", T, abi.encodeCall(eth.setHeirs, (w2, p2)));
    }

    function test_recoveryUsers_set() public {
        (address[] memory w,) = _list("contact", NR);
        _measure("setRecoveryUsers, 50 new", T, abi.encodeCall(eth.setRecoveryUsers, (w)));
        (address[] memory w2,) = _list("other", NR);
        _measure("setRecoveryUsers, replace 50 with 50 others", T, abi.encodeCall(eth.setRecoveryUsers, (w2)));
    }

    function test_inheritance_paths() public {
        _heirs();
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        _measure("startInheritance, 40 heirs", _a("heir", 0), abi.encodeCall(eth.startInheritance, (T)));
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        _measure("executeInheritance, first of 40", _a("heir", 0), abi.encodeCall(eth.executeInheritance, (T)));
        _claim(1, N - 2);
        _measure("executeInheritance, 39th of 40", _a("heir", N - 2), abi.encodeCall(eth.executeInheritance, (T)));
    }

    function test_inheritance_last() public {
        _started();
        _claim(0, N - 1);
        _measure("executeInheritance, last of 40 (receives the whole balance)", _a("heir", N - 1), abi.encodeCall(eth.executeInheritance, (T)));
    }

    function test_inheritance_remaining() public {
        _started();
        _claim(0, N - 1);
        vm.warp(vm.getBlockTimestamp() + eth.inheritRemainingWaitingTime());
        _measure("executeInheritanceRemaining, 39 of 40 claimed (pays 39)", _a("heir", 0), abi.encodeCall(eth.executeInheritanceRemaining, (T)));
    }

    function test_testator_returns() public {
        _started();
        _claim(0, N - 1);
        _measure("checkActivity, clears an inheritance with 39 claims", T, abi.encodeCall(eth.checkActivity, ()));
    }

    function test_recovery_paths() public {
        (address[] memory w,) = _list("contact", NR);
        vm.prank(T);
        eth.setRecoveryUsers(w);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryInactivityPeriod());
        _measure("startRecovery, 50 recovery users", w[NR - 1], abi.encodeCall(eth.startRecovery, (T)));
        vm.warp(vm.getBlockTimestamp() + eth.recoveryWaitingTime());
        _measure("executeRecovery, 50 recovery users", w[NR - 1], abi.encodeCall(eth.executeRecovery, (T)));
    }

    function test_treasuries() public {
        (address[] memory w, uint256[] memory p) = _list("treasury", N);
        _measure("setTreasuries, 40 new", address(this), abi.encodeCall(eth.setTreasuries, (w, p)));
        (address[] memory w2, uint256[] memory p2) = _list("other", N);
        _measure("setTreasuries, replace 40 with 40 others", address(this), abi.encodeCall(eth.setTreasuries, (w2, p2)));
        vm.prank(T);
        eth.unwrap(1 ether); // accumulates unwrapping tax
        vm.warp(vm.getBlockTimestamp() + eth.taxCollectionWaitingTime());
        assertGt(eth.accumulatedTax(), 0);
        _measure("collectTax, 40 treasuries", address(this), abi.encodeCall(eth.collectTax, ()));
    }
}
