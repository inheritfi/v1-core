// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// N-13: delegates A, B and C (25% each) nominate their own accepted candidates and
// then disappear; D (8%), E (8%) and F (9%) each voted for one of those candidates.
// Before the fix the redistribution left every candidate below 51 with no way to
// cancel a candidacy or re-cast a vote. Now quorate() resets every candidacy and
// vote, so the present delegates can run a new election and unstall it themselves.
contract N13QuorateResetTest is Test {
    InheritfiV1ETH eth;
    address A = makeAddr("delegateA");
    address B = makeAddr("delegateB");
    address C = makeAddr("delegateC");
    address D = makeAddr("delegateD");
    address E = makeAddr("delegateE");
    address F = makeAddr("delegateF");
    address CA = makeAddr("candidateA");
    address CB = makeAddr("candidateB");
    address CC = makeAddr("candidateC");
    address X = makeAddr("candidateX");
    address Y = makeAddr("candidateY");
    address Z = makeAddr("candidateZ");

    function setUp() public {
        eth = new InheritfiV1ETH();
        // This acceptance sequence yields exactly 25/25/25/8/8/9.
        _add(A, 50);
        _add(B, 50);
        _add(C, 32);
        _add(D, 8);
        _add(E, 8);
        _add(F, 9);
        assertEq(_w(A), 25, "A weight");
        assertEq(_w(B), 25, "B weight");
        assertEq(_w(C), 25, "C weight");
        assertEq(_w(D), 8, "D weight");
        assertEq(_w(E), 8, "E weight");
        assertEq(_w(F), 9, "F weight");
    }

    function _add(address d, uint256 w) internal {
        eth.addDelegate(d, w);
        vm.prank(d);
        eth.acceptDelegate();
    }

    function _w(address d) internal view returns (uint256 w) {
        (,, w,,,) = eth.delegates(d);
    }

    function _active(address d) internal view returns (bool a) {
        (a,,,,,) = eth.delegates(d);
    }

    function _votedFor(address d) internal view returns (address vf) {
        (,,, vf,,) = eth.delegates(d);
    }

    function _tally(address c) internal view returns (uint256 tv) {
        (, tv,) = eth.ownerCandidates(c);
    }

    function _nominateAndAccept(address nominator, address candidate) internal {
        vm.prank(nominator);
        eth.nominateOwnerCandidate(candidate);
        vm.prank(candidate);
        eth.acceptOwnerCandidacy();
    }

    // Builds the stalled election, then A, B and C miss the roll-call.
    function _stalledElectionThenQuorate() internal {
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        _nominateAndAccept(A, CA);
        _nominateAndAccept(B, CB);
        _nominateAndAccept(C, CC);
        vm.prank(D);
        eth.voteForOwnerCandidate(CA);
        vm.prank(E);
        eth.voteForOwnerCandidate(CB);
        vm.prank(F);
        eth.voteForOwnerCandidate(CC);
        assertEq(_tally(CA), 33, "CA tally before the quorum");
        assertEq(_tally(CB), 33, "CB tally before the quorum");
        assertEq(_tally(CC), 34, "CC tally before the quorum");
        assertFalse(eth.ownerElected(), "not elected before the quorum");

        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(D);
        eth.quorumCall();
        vm.prank(E);
        eth.present();
        vm.prank(F);
        eth.present();
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        vm.prank(D);
        eth.quorate();
    }

    // After the quorum every candidacy and vote is reset and the present delegates
    // elect a candidate of their own.
    function test_userScenario_quorateResetsStalledElection() public {
        _stalledElectionThenQuorate();

        assertFalse(_active(A), "A removed");
        assertFalse(_active(B), "B removed");
        assertFalse(_active(C), "C removed");
        assertEq(eth.getDelegates().length, 3, "three delegates left");
        assertEq(_w(D), 32, "D weight after redistribution");
        assertEq(_w(E), 32, "E weight after redistribution");
        assertEq(_w(F), 36, "F weight after redistribution");
        assertFalse(eth.ownerElected(), "no automatic election");
        assertEq(eth.getOwnerCandidates().length, 0, "every candidacy reset");
        (address ca,,) = eth.ownerCandidates(CA);
        (address cb,,) = eth.ownerCandidates(CB);
        (address cc,,) = eth.ownerCandidates(CC);
        assertEq(ca, address(0), "CA cleared");
        assertEq(cb, address(0), "CB cleared");
        assertEq(cc, address(0), "CC cleared");
        assertEq(_votedFor(D), address(0), "D vote released");
        assertEq(_votedFor(E), address(0), "E vote released");
        assertEq(_votedFor(F), address(0), "F vote released");
        assertFalse(eth.quorumCallActive(), "quorum call closed");

        _nominateAndAccept(D, X);
        vm.prank(E);
        eth.voteForOwnerCandidate(X);
        assertTrue(eth.ownerElected(), "present delegates elect");
        assertEq(eth.ownerElect(), X);
    }

    // The new election stalls again (32/32/36); a present nominator cancels its own
    // candidacy, which releases its vote, and backs another candidate.
    function test_userScenario_presentNominatorUnstallsNewElection() public {
        _stalledElectionThenQuorate();

        _nominateAndAccept(D, X);
        _nominateAndAccept(E, Y);
        _nominateAndAccept(F, Z);
        assertEq(_tally(X), 32, "X tally");
        assertEq(_tally(Y), 32, "Y tally");
        assertEq(_tally(Z), 36, "Z tally");
        assertFalse(eth.ownerElected(), "split vote: nobody reaches the threshold");

        vm.prank(F);
        vm.expectRevert(bytes("Already voted"));
        eth.voteForOwnerCandidate(X);
        vm.prank(D);
        vm.expectRevert(bytes("Not nominator"));
        eth.cancelOwnerCandidacy(Z);

        vm.prank(F);
        eth.cancelOwnerCandidacy(Z);
        assertEq(_votedFor(F), address(0), "F vote released");
        vm.prank(F);
        eth.voteForOwnerCandidate(X);
        assertTrue(eth.ownerElected(), "elected after the nominator stepped back");
        assertEq(eth.ownerElect(), X);
    }
}
