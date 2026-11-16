// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// I-01: Lack-of-Quorum with two or more present delegates. The absent delegate is
// removed and its weight is redistributed among the present ones. Every candidacy
// and vote is then reset (N-13), so only candidates nominated by present delegates
// can take part in the new election.
// Also: if every delegate answers the roll-call, the quorum call is cancelled.
contract I01QuorumTest is Test {
    InheritfiV1ETH eth;
    address D1 = makeAddr("delegate1");
    address D2 = makeAddr("delegate2");
    address D3 = makeAddr("delegate3");
    address D4 = makeAddr("delegate4");
    address C = makeAddr("candidate");

    function setUp() public {
        eth = new InheritfiV1ETH();
        _add(D1, 50);
        _add(D2, 50);
        _add(D3, 33);
        _add(D4, 40);
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

    function _checkWeights() internal view {
        address[] memory list = eth.getDelegates();
        uint256 sum;
        for (uint256 i; i < list.length; i++) {
            uint256 w = _w(list[i]);
            assertGe(w, 1);
            assertLe(w, 50);
            sum += w;
        }
        assertEq(sum, 100, "weights sum 100");
    }

    // D1 nominates C (and D2 optionally votes for C); D4 never answers the roll-call.
    function _quorumWithAbsentD4(bool d2Votes) internal {
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        vm.prank(D1);
        eth.nominateOwnerCandidate(C);
        vm.prank(C);
        eth.acceptOwnerCandidacy();
        if (d2Votes) {
            vm.prank(D2);
            eth.voteForOwnerCandidate(C);
        }
        assertFalse(eth.ownerElected(), "not elected before the quorum");
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(D1);
        eth.quorumCall();
        vm.prank(D2);
        eth.present();
        vm.prank(D3);
        eth.present();
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        vm.prank(D1);
        eth.quorate();
    }

    // The quorum resets every candidacy and vote; the present delegates then elect
    // in a new election with their redistributed weights.
    function test_quorate_resetsCandidaciesAndVotes() public {
        assertLt(_w(D1) + _w(D2), 51, "below the threshold before the quorum");
        _quorumWithAbsentD4(true);
        assertFalse(eth.ownerElected(), "no automatic election after redistribution");
        (address cand, uint256 tv, address nom) = eth.ownerCandidates(C);
        assertEq(cand, address(0), "candidacy cleared");
        assertEq(tv, 0, "tally cleared");
        assertEq(nom, address(0), "nominator cleared");
        assertEq(eth.getOwnerCandidates().length, 0, "no candidates left");
        assertEq(_votedFor(D1), address(0), "D1 vote released");
        assertEq(_votedFor(D2), address(0), "D2 vote released");
        assertEq(_votedFor(D3), address(0), "D3 vote released");
        assertFalse(_active(D4), "absent delegate removed");
        assertEq(eth.getDelegates().length, 3);
        assertFalse(eth.quorumCallActive());
        _checkWeights();

        assertGe(_w(D1) + _w(D2), 51, "above the threshold after redistribution");
        vm.prank(D1);
        eth.nominateOwnerCandidate(C);
        vm.prank(C);
        eth.acceptOwnerCandidacy();
        vm.prank(D2);
        eth.voteForOwnerCandidate(C);
        assertTrue(eth.ownerElected(), "elected in the new election");
        assertEq(eth.ownerElect(), C);
    }

    // A split election after the quorum: a present nominator cancels its own
    // candidacy, which releases its vote, and backs the other candidate.
    function test_quorate_presentNominatorCanUnstallElection() public {
        _quorumWithAbsentD4(false);
        assertFalse(eth.ownerElected(), "no automatic election after redistribution");
        address C2 = makeAddr("candidate2");
        vm.prank(D1);
        eth.nominateOwnerCandidate(C);
        vm.prank(C);
        eth.acceptOwnerCandidacy();
        vm.prank(D2);
        eth.nominateOwnerCandidate(C2);
        vm.prank(C2);
        eth.acceptOwnerCandidacy();
        assertFalse(eth.ownerElected(), "split vote: nobody reaches the threshold");
        vm.prank(D2);
        vm.expectRevert(bytes("Already voted"));
        eth.voteForOwnerCandidate(C);
        vm.prank(D2);
        eth.cancelOwnerCandidacy(C2);
        assertEq(_votedFor(D2), address(0), "D2 vote released");
        vm.prank(D2);
        eth.voteForOwnerCandidate(C);
        assertTrue(eth.ownerElected(), "elected after the nominator stepped back");
        assertEq(eth.ownerElect(), C);
        _checkWeights();
    }

    // If every delegate answers, no rescue is needed: the call is cancelled and nobody is removed.
    function test_allPresent_cancelsQuorumCall() public {
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(D1);
        eth.quorumCall();
        vm.prank(D2);
        eth.present();
        vm.prank(D3);
        eth.present();
        assertTrue(eth.quorumCallActive());
        vm.prank(D4);
        eth.present();
        assertFalse(eth.quorumCallActive(), "everyone answered");
        assertEq(eth.getDelegates().length, 4, "nobody removed");
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        vm.prank(D1);
        vm.expectRevert(bytes("No quorum call"));
        eth.quorate();
    }
}
