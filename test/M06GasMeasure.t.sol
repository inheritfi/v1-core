// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// M-06 part 2: measures governance gas for rosters of 10 to 50 delegates and compares it
// with the EIP-7825 per-transaction gas cap (16,777,216). It only reports values; it does
// not assert any expected gas figure.
contract M06GasMeasureTest is Test {
    InheritfiV1ETH eth;
    uint256 constant TX_CAP = 16_777_216;

    function setUp() public {
        eth = new InheritfiV1ETH();
        eth.setMaxDelegates(50);
    }

    function _d(uint256 i) internal returns (address) {
        return makeAddr(string.concat("delegate", vm.toString(i)));
    }

    // Calls `data` as `from`, logs the gas used (or REVERTED) and flags values above the cap.
    function _measure(string memory label, address from, bytes memory data) internal returns (bool ok) {
        vm.prank(from);
        uint256 g = gasleft();
        (ok,) = address(eth).call(data);
        uint256 used = g - gasleft();
        if (ok) emit log_named_uint(label, used);
        else emit log_named_string(label, "REVERTED");
        if (used > TX_CAP) emit log_named_string(label, "ABOVE EIP-7825 CAP");
    }

    // Builds a roster of n delegates (weights sum 100) and measures the last acceptDelegate.
    function _build(uint256 n) internal {
        for (uint256 k; k < n; k++) {
            address d = _d(k);
            eth.addDelegate(d, k < 2 ? 50 : 100 / (k + 1));
            if (k == n - 1) {
                _measure(string.concat("n=", vm.toString(n), " acceptDelegate (last)"), d, abi.encodeCall(eth.acceptDelegate, ()));
            } else {
                vm.prank(d);
                eth.acceptDelegate();
            }
        }
    }

    function _run(uint256 n) internal {
        _build(n);
        uint256 built = vm.snapshotState();
        string memory p = string.concat("n=", vm.toString(n), " ");

        _measure(string.concat(p, "removeDelegate"), address(this), abi.encodeCall(eth.removeDelegate, (_d(0))));
        vm.revertToState(built);
        _measure(string.concat(p, "setDelegateWeight down to 1"), address(this), abi.encodeCall(eth.setDelegateWeight, (_d(n - 1), 1)));
        vm.revertToState(built);
        _measure(string.concat(p, "setDelegateWeight up to 50"), address(this), abi.encodeCall(eth.setDelegateWeight, (_d(n - 1), 50)));
        vm.revertToState(built);
        _quorate(n, p);
        vm.revertToState(built);
        _ownerActionWithCandidates(n, p);
        vm.revertToState(built);
        _quorateWithCandidates(n, p);
    }

    // Quorum roll-call where only the first half of the roster confirms presence.
    function _quorate(uint256 n, string memory p) internal {
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(_d(0));
        eth.quorumCall();
        for (uint256 i = 1; i < n / 2; i++) {
            vm.prank(_d(i));
            eth.present();
        }
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        _measure(string.concat(p, "quorate (half absent)"), _d(0), abi.encodeCall(eth.quorate, ()));
    }

    // Every delegate nominates a distinct candidate; then an owner action clears them all.
    function _ownerActionWithCandidates(uint256 n, string memory p) internal {
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        for (uint256 i; i < n; i++) {
            vm.prank(_d(i));
            eth.nominateOwnerCandidate(makeAddr(string.concat("candidate", vm.toString(i))));
        }
        _measure(string.concat(p, "owner action with n pending candidates"), address(this), abi.encodeCall(eth.setWrappingTax, (30)));
    }

    // N-13 worst case: every delegate nominates a distinct candidate that accepts, so every
    // delegate holds a live vote; then only the first half confirms presence and quorate
    // retracts the absent votes, redistributes the weight, and resets every candidacy.
    function _quorateWithCandidates(uint256 n, string memory p) internal {
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        for (uint256 i; i < n; i++) {
            address c = makeAddr(string.concat("candidate", vm.toString(i)));
            vm.prank(_d(i));
            eth.nominateOwnerCandidate(c);
            vm.prank(c);
            eth.acceptOwnerCandidacy();
        }
        assertFalse(eth.ownerElected(), "no candidate reaches the threshold alone");
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(_d(0));
        eth.quorumCall();
        for (uint256 i = 1; i < n / 2; i++) {
            vm.prank(_d(i));
            eth.present();
        }
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        _measure(string.concat(p, "quorate (half absent, n accepted candidates)"), _d(0), abi.encodeCall(eth.quorate, ()));
        assertEq(eth.getOwnerCandidates().length, 0, "every candidacy reset");
    }

    function test_gas_n10() public { _run(10); }
    function test_gas_n20() public { _run(20); }
    function test_gas_n30() public { _run(30); }
    function test_gas_n40() public { _run(40); }
    function test_gas_n50() public { _run(50); }

    // Edge case for _scaleDown: one delegate at 50, the rest near 1, then another is raised to 50.
    function test_scaleDownEdge_n49() public {
        _build(49);
        eth.setDelegateWeight(_d(0), 50);
        _measure("n=49 edge: raise a second delegate to 50", address(this), abi.encodeCall(eth.setDelegateWeight, (_d(1), 50)));
    }
}
