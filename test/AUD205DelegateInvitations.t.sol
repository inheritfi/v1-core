// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// AUD2-05: a delegate invitation is valid only within delegateInvitationWindow
// and while the owner that issued it is still the owner (ownership epoch).
// (a) An invalid (expired) invitation must not block nominating that address.
// (b) Invitations issued by a previous owner cannot be accepted after an
//     ownership change, do not block a new invitation, and do not block a
//     nomination either.
contract AUD205DelegateInvitationsTest is Test {
    InheritfiV1ETH eth;
    address D1 = makeAddr("delegate1");
    address D2 = makeAddr("delegate2");
    address C = makeAddr("invitedAddress");
    address N = makeAddr("newOwner");
    address X = makeAddr("electedOwner");

    function setUp() public {
        eth = new InheritfiV1ETH();
        _add(D1, 50);
        _add(D2, 50);
    }

    function _add(address d, uint256 w) internal {
        eth.addDelegate(d, w);
        vm.prank(d);
        eth.acceptDelegate();
    }

    // The current owner (this contract) hands ownership to N in two steps.
    function _transferOwnershipToN() internal {
        eth.transferOwnership(N);
        vm.prank(N);
        eth.acceptOwnership();
        assertEq(eth.owner(), N, "N is the owner");
    }

    // (a) An expired invitation no longer blocks a nomination.
    function test_expiredInvitationDoesNotBlockNomination() public {
        uint256 t0 = vm.getBlockTimestamp();
        eth.addDelegate(C, 10);
        vm.warp(t0 + eth.delegateInvitationWindow() + 1);
        vm.prank(D1);
        eth.nominateOwnerCandidate(C);
        assertTrue(eth.pendingNomination(C), "C nominated");
    }

    // (a) A valid invitation still blocks the nomination.
    function test_validInvitationStillBlocksNomination() public {
        eth.setDelegateInvitationWindow(90 days);
        uint256 t0 = vm.getBlockTimestamp();
        eth.addDelegate(C, 10);
        vm.warp(t0 + eth.contractRecoveryStartWaitingTime());
        vm.prank(D1);
        vm.expectRevert(bytes("Is delegate"));
        eth.nominateOwnerCandidate(C);
    }

    // (b) An invitation from the previous owner cannot be accepted.
    function test_invitationFromPreviousOwnerCannotBeAccepted() public {
        eth.addDelegate(C, 10);
        _transferOwnershipToN();
        vm.prank(C);
        vm.expectRevert(bytes("Invite expired"));
        eth.acceptDelegate();
    }

    // (b) The new owner can invite the same address again.
    function test_newOwnerCanReinvite() public {
        eth.addDelegate(C, 10);
        _transferOwnershipToN();
        vm.prank(N);
        eth.addDelegate(C, 10);
        vm.prank(C);
        eth.acceptDelegate();
        assertEq(eth.getDelegates().length, 3, "C joined under the new owner");
    }

    // (b) An inherited invitation, still inside its window, does not block a
    // nomination: the ownership-epoch rule applies on its own.
    function test_inheritedInvitationDoesNotBlockNomination() public {
        uint256 t0 = vm.getBlockTimestamp();
        eth.addDelegate(C, 10);
        _transferOwnershipToN();
        vm.warp(t0 + eth.contractRecoveryStartWaitingTime());
        assertLe(vm.getBlockTimestamp(), t0 + eth.delegateInvitationWindow(), "invitation not expired by time");
        vm.prank(D1);
        eth.nominateOwnerCandidate(C);
        assertTrue(eth.pendingNomination(C), "C nominated");
    }

    // (b) A takeover through the delegates' election also invalidates it.
    function test_invitationInvalidatedByContractRecovery() public {
        eth.setDelegateInvitationWindow(90 days);
        uint256 t0 = vm.getBlockTimestamp();
        eth.addDelegate(C, 10);

        vm.warp(t0 + eth.contractRecoveryStartWaitingTime());
        vm.prank(D1);
        eth.nominateOwnerCandidate(X);
        vm.prank(X);
        eth.acceptOwnerCandidacy();
        vm.prank(D2);
        eth.voteForOwnerCandidate(X);
        assertTrue(eth.ownerElected(), "X elected");
        vm.prank(D1);
        eth.startContractRecoveryProcess();
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryWaitingTime());
        vm.prank(D1);
        eth.executeContractRecovery();
        assertEq(eth.owner(), X, "X is the owner");
        assertLe(vm.getBlockTimestamp(), t0 + eth.delegateInvitationWindow(), "invitation not expired by time");

        vm.prank(C);
        vm.expectRevert(bytes("Invite expired"));
        eth.acceptDelegate();
    }
}
