// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// AUD2-08: owner weight actions (setDelegateWeight, removeDelegate) are
// onlyOwnerAlive, so _ownerAlive() clears every candidacy and vote before the
// weights change. They can therefore never trigger an election, even when the
// new weights would push a candidate past the threshold. This is what makes
// the base-level election check after setDelegateWeight unreachable.
contract AUD208OwnerWeightChangeTest is Test {
    InheritfiV1ETH eth;
    address A = makeAddr("delegateA");
    address B = makeAddr("delegateB");
    address C = makeAddr("delegateC");
    address D = makeAddr("delegateD");
    address E = makeAddr("delegateE");
    address F = makeAddr("delegateF");
    address X = makeAddr("candidateX");

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

        // Owner inactive; A nominates X, X accepts, B votes: X holds 50 (< 51).
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        vm.prank(A);
        eth.nominateOwnerCandidate(X);
        vm.prank(X);
        eth.acceptOwnerCandidacy();
        vm.prank(B);
        eth.voteForOwnerCandidate(X);
        assertEq(_tally(X), 50, "X tally before the owner action");
        assertFalse(eth.ownerElected(), "not elected yet");
    }

    function _add(address d, uint256 w) internal {
        eth.addDelegate(d, w);
        vm.prank(d);
        eth.acceptDelegate();
    }

    function _w(address d) internal view returns (uint256 w) {
        (,, w,,,) = eth.delegates(d);
    }

    function _votedFor(address d) internal view returns (address vf) {
        (,,, vf,,) = eth.delegates(d);
    }

    function _tally(address c) internal view returns (uint256 tv) {
        (, tv,) = eth.ownerCandidates(c);
    }

    function _assertElectionCleared() internal view {
        assertFalse(eth.ownerElected(), "owner action never elects");
        assertEq(eth.ownerElect(), address(0), "no owner elect");
        assertEq(eth.getOwnerCandidates().length, 0, "candidacies cleared");
        (address cand,,) = eth.ownerCandidates(X);
        assertEq(cand, address(0), "X record cleared");
        assertEq(_votedFor(A), address(0), "A vote released");
        assertEq(_votedFor(B), address(0), "B vote released");
        address[] memory list = eth.getDelegates();
        uint256 sum;
        for (uint256 i; i < list.length; i++) sum += _w(list[i]);
        assertEq(sum, 100, "weights sum 100");
    }

    // With live votes, 25 -> 26 for A would take X to 51.
    function test_setDelegateWeight_neverElects() public {
        eth.setDelegateWeight(A, 26);
        assertEq(_w(A), 26, "new weight applied");
        _assertElectionCleared();
    }

    // With live votes, C's 25 redistributed to A and B would take X past 51.
    function test_removeDelegate_neverElects() public {
        eth.removeDelegate(C);
        assertGe(_w(A) + _w(B), 51, "A + B would exceed the threshold");
        _assertElectionCleared();
    }
}
