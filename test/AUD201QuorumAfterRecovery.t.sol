// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// AUD2-01: a quorum call opened while the previous owner was inactive must not
// survive executeContractRecovery(). Otherwise, once the roll-call window
// closes, a minority delegate could run quorate() against the freshly elected
// owner and take ownership or remove the majority that elected that owner.
contract AUD201QuorumAfterRecoveryTest is Test {
    InheritfiV1ETH eth;
    address A = makeAddr("delegateA");
    address B = makeAddr("delegateB");
    address M = makeAddr("minorityDelegate");
    address X = makeAddr("electedOwner");

    function setUp() public {
        eth = new InheritfiV1ETH();
        _add(A, 50);
        _add(B, 50);
        _add(M, 20);
        assertEq(_w(A), 40, "A weight");
        assertEq(_w(B), 40, "B weight");
        assertEq(_w(M), 20, "M weight");
    }

    function _add(address d, uint256 w) internal {
        eth.addDelegate(d, w);
        vm.prank(d);
        eth.acceptDelegate();
    }

    function _w(address d) internal view returns (uint256 w) {
        (,, w,,,) = eth.delegates(d);
    }

    // The owner is inactive; M opens a roll-call that nobody else answers;
    // A and B elect X and execute the contract recovery.
    function _electXWhileRollCallOpen() internal returns (uint256 rollCallStart) {
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(M);
        eth.quorumCall();
        rollCallStart = vm.getBlockTimestamp();
        assertTrue(eth.quorumCallActive(), "roll-call open during the election");

        vm.prank(A);
        eth.nominateOwnerCandidate(X);
        vm.prank(X);
        eth.acceptOwnerCandidacy();
        vm.prank(B);
        eth.voteForOwnerCandidate(X);
        assertTrue(eth.ownerElected(), "X elected with 80");

        vm.prank(A);
        eth.startContractRecoveryProcess();
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryWaitingTime());
        vm.prank(A);
        eth.executeContractRecovery();
        assertEq(eth.owner(), X, "X is the new owner");
    }

    function _assertRollCallClosed() internal view {
        assertFalse(eth.quorumCallActive(), "recovery closes the stale roll-call");
        assertEq(eth.getPresentDelegates().length, 0, "present list cleared");
    }

    function _assertGovernanceIntact() internal view {
        assertEq(eth.owner(), X, "elected owner keeps ownership");
        assertEq(eth.getDelegates().length, 3, "no delegate removed");
        assertEq(_w(A), 40, "A weight unchanged");
        assertEq(_w(B), 40, "B weight unchanged");
        assertEq(_w(M), 20, "M weight unchanged");
    }

    // Defaults: the original roll-call window closes 60 days after the recovery.
    function test_recoveryClosesStaleQuorumCall() public {
        uint256 start = _electXWhileRollCallOpen();
        _assertRollCallClosed();

        vm.warp(start + eth.quorumRollcallWindow());
        vm.prank(M);
        vm.expectRevert();
        eth.quorate();
        _assertGovernanceIntact();
    }

    // With both windows at 30 days the takeover would happen in the same second
    // as the recovery; it must not be possible either.
    function test_recoveryClosesStaleQuorumCall_sameSecond() public {
        eth.setQuorumRollcallWindow(30 days);
        eth.setContractRecoveryWaitingTime(30 days);
        _electXWhileRollCallOpen();
        _assertRollCallClosed();

        vm.prank(M);
        vm.expectRevert();
        eth.quorate();
        _assertGovernanceIntact();
    }

    // Right after the recovery the new owner counts as active: no new roll-call.
    function test_newOwnerIsActiveAfterRecovery() public {
        _electXWhileRollCallOpen();
        _assertRollCallClosed();
        assertEq(eth.lastOwnerActivityTimestamp(), vm.getBlockTimestamp(), "activity recorded");

        vm.prank(M);
        vm.expectRevert(bytes("Owner active"));
        eth.quorumCall();
    }
}
