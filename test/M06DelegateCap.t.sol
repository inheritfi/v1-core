// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// M-06: the maxDelegates cap is enforced when a delegate accepts, not only when invited.
contract M06DelegateCapTest is Test {
    InheritfiV1ETH eth;
    address D1 = makeAddr("delegate1");
    address D2 = makeAddr("delegate2");
    address D3 = makeAddr("delegate3");
    address D4 = makeAddr("delegate4");
    address E = makeAddr("stranger");

    function setUp() public {
        eth = new InheritfiV1ETH();
        eth.setMaxDelegates(2);
        eth.addDelegate(D1, 50);
        vm.prank(D1);
        eth.acceptDelegate();
    }

    // With one active delegate and cap 2, two invitations pass addDelegate; only one can be accepted.
    function test_acceptBeyondCap_reverts() public {
        eth.addDelegate(D2, 50);
        eth.addDelegate(D3, 50);
        vm.prank(D2);
        eth.acceptDelegate();
        assertEq(eth.getDelegates().length, 2, "cap reached");

        vm.prank(D3);
        vm.expectRevert(bytes("Max reached"));
        eth.acceptDelegate();
        assertEq(eth.getDelegates().length, 2, "roster did not grow");
    }

    // Existing error precedence is kept: no invitation and expired invitation report their own errors.
    function test_errorPrecedence_kept() public {
        eth.addDelegate(D2, 50);
        eth.addDelegate(D4, 50);
        vm.prank(D2);
        eth.acceptDelegate();

        vm.prank(E);
        vm.expectRevert(bytes("No pending role"));
        eth.acceptDelegate();

        vm.warp(vm.getBlockTimestamp() + eth.delegateInvitationWindow() + 1);
        vm.prank(D4);
        vm.expectRevert(bytes("Invite expired"));
        eth.acceptDelegate();
    }

    // Once there is room again, a still-valid invitation can be accepted.
    function test_acceptAfterRaisingCap() public {
        eth.addDelegate(D2, 50);
        eth.addDelegate(D3, 50);
        vm.prank(D2);
        eth.acceptDelegate();
        vm.prank(D3);
        vm.expectRevert(bytes("Max reached"));
        eth.acceptDelegate();

        eth.setMaxDelegates(3);
        vm.prank(D3);
        eth.acceptDelegate();
        assertEq(eth.getDelegates().length, 3, "accepted once there is room");
    }
}
