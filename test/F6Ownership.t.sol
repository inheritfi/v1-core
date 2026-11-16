// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// F6 / N-7 / N-9 / H: two-step ownership transfer with expiry, proof of life
// on transfer and on acceptance, fresh activity timestamp after a delegate-driven
// owner change, and renounce reset whenever the owner changes.
contract F6OwnershipTest is Test {
    InheritfiV1ETH eth;
    address D1 = makeAddr("delegate1");
    address D2 = makeAddr("delegate2");
    address B = makeAddr("newOwner");
    address C = makeAddr("candidate");
    address X = makeAddr("otherCandidate");

    function setUp() public {
        eth = new InheritfiV1ETH();
    }

    function _addDelegates() internal {
        eth.addDelegate(D1, 50);
        vm.prank(D1);
        eth.acceptDelegate();
        eth.addDelegate(D2, 50);
        vm.prank(D2);
        eth.acceptDelegate();
    }

    // D1 nominates `cand`, `cand` accepts (50 votes) and D2 votes (100): elected.
    function _elect(address cand) internal {
        vm.prank(D1);
        eth.nominateOwnerCandidate(cand);
        vm.prank(cand);
        eth.acceptOwnerCandidacy();
        vm.prank(D2);
        eth.voteForOwnerCandidate(cand);
        assertTrue(eth.ownerElected(), "elected");
        assertEq(eth.ownerElect(), cand);
    }

    // 1. transferOwnership is proof of life and cancels delegate processes.
    function test_transferOwnership_isProofOfLife_cancelsRecovery() public {
        _addDelegates();
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        _elect(C);
        vm.prank(D1);
        eth.startContractRecoveryProcess();
        assertTrue(eth.startContractRecovery());

        eth.transferOwnership(B);
        assertEq(eth.lastOwnerActivityTimestamp(), vm.getBlockTimestamp(), "proof of life");
        assertEq(eth.ownerInvitationTimestamp(), vm.getBlockTimestamp(), "invitation recorded");
        assertFalse(eth.startContractRecovery(), "recovery cancelled");
        assertFalse(eth.ownerElected(), "election voided");
        assertEq(eth.pendingOwner(), B);
        assertEq(eth.owner(), address(this), "owner unchanged until acceptance");
    }

    // 2. acceptOwnership within the window: transfers and cancels an ongoing recovery.
    function test_acceptOwnership_withinWindow_cancelsRecovery() public {
        _addDelegates();
        eth.setOwnerInvitationWindow(90 days);
        eth.transferOwnership(B);
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        _elect(C);
        vm.prank(D1);
        eth.startContractRecoveryProcess();

        vm.prank(B);
        eth.acceptOwnership();
        assertEq(eth.owner(), B);
        assertEq(eth.pendingOwner(), address(0));
        assertEq(eth.lastOwnerActivityTimestamp(), vm.getBlockTimestamp(), "proof of life of B");
        assertFalse(eth.startContractRecovery(), "recovery cancelled");
        assertFalse(eth.ownerElected(), "election voided");

        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryWaitingTime());
        vm.prank(D1);
        vm.expectRevert(bytes("Bad state"));
        eth.executeContractRecovery();
    }

    // 3. Accepting exactly at the window edge works; one second later it has expired.
    function test_acceptOwnership_windowBoundary() public {
        eth.transferOwnership(B);
        uint256 deadline = vm.getBlockTimestamp() + eth.ownerInvitationWindow();
        vm.warp(deadline + 1);
        vm.prank(B);
        vm.expectRevert(bytes("Invite expired"));
        eth.acceptOwnership();
        assertEq(eth.owner(), address(this), "original owner kept");

        eth.transferOwnership(B); // new invitation
        vm.warp(vm.getBlockTimestamp() + eth.ownerInvitationWindow());
        vm.prank(B);
        eth.acceptOwnership();
        assertEq(eth.owner(), B, "accepts at the exact edge");
    }

    // 4. setOwnerInvitationWindow enforces the 7-90 day range and is owner-only.
    function test_setOwnerInvitationWindow_range() public {
        vm.expectRevert(bytes("Bad period"));
        eth.setOwnerInvitationWindow(7 days - 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setOwnerInvitationWindow(90 days + 1);
        eth.setOwnerInvitationWindow(7 days);
        assertEq(eth.ownerInvitationWindow(), 7 days);
        eth.setOwnerInvitationWindow(90 days);
        assertEq(eth.ownerInvitationWindow(), 90 days);
        vm.prank(B);
        vm.expectRevert();
        eth.setOwnerInvitationWindow(10 days);
    }

    // 5. N-9 and H via Contract Recovery: fresh activity for the new owner, no inherited renounce.
    function test_contractRecovery_freshActivity_noInheritedRenounce() public {
        _addDelegates();
        eth.startRenounceOwnershipProcess();
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        _elect(C);
        vm.prank(D1);
        eth.startContractRecoveryProcess();
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryWaitingTime());
        vm.prank(D1);
        eth.executeContractRecovery();

        assertEq(eth.owner(), C);
        assertEq(eth.lastOwnerActivityTimestamp(), vm.getBlockTimestamp(), "N-9: fresh activity");
        assertFalse(eth.startRenounceOwnership(), "H: renounce not inherited");
        vm.prank(D1);
        vm.expectRevert(bytes("Owner active"));
        eth.nominateOwnerCandidate(X);
        vm.prank(C);
        vm.expectRevert(bytes("Not started"));
        eth.renounceOwnership();
    }

    // 6. N-9 and H via Lack-of-Quorum (sole survivor).
    function test_quorumSoloSurvivor_freshActivity_noInheritedRenounce() public {
        _addDelegates();
        eth.startRenounceOwnershipProcess();
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(D1);
        eth.quorumCall();
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        vm.prank(D1);
        eth.quorate();

        assertEq(eth.owner(), D1, "D1 sole survivor");
        assertEq(eth.lastOwnerActivityTimestamp(), vm.getBlockTimestamp(), "N-9: fresh activity");
        assertFalse(eth.startRenounceOwnership(), "H: renounce not inherited");
    }

    // 7. H via acceptOwnership: the new owner cannot use a renounce started by the previous one.
    function test_acceptOwnership_noInheritedRenounce() public {
        eth.startRenounceOwnershipProcess();
        eth.transferOwnership(B);
        vm.prank(B);
        eth.acceptOwnership();
        assertFalse(eth.startRenounceOwnership());
        assertEq(eth.startRenounceOwnershipTimestamp(), 0);
        vm.warp(vm.getBlockTimestamp() + eth.renounceOwnershipWaitingTime());
        vm.prank(B);
        vm.expectRevert(bytes("Not started"));
        eth.renounceOwnership();
    }
}
