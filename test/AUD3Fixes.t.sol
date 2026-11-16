// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

/// @notice Fixes after the third internal review: AUD3-01 (claim marks survive an abandoned
///         recovery and are cleared when the testator returns or the recovery is
///         executed), list caps of 40, a minimum 3-day exclusive recovery window,
///         minimum inactivity periods of 14 and 21 days, and the new defaults.
contract AUD3FixesTest is Test {
    InheritfiV1ETH internal eth;

    address internal testator = makeAddr("testator");
    address internal heirA = makeAddr("heirA");
    address internal heirB = makeAddr("heirB");
    address internal contact = makeAddr("contact");

    uint256 internal constant START = 100 ether;

    function setUp() public {
        eth = new InheritfiV1ETH();
        eth.setWrappingTax(0);
        eth.setInheritanceTax(0);
        eth.setRecoveryTax(0);

        vm.deal(testator, START);
        vm.startPrank(testator);
        eth.wrap{value: START}();
        address[] memory heirs = new address[](2);
        heirs[0] = heirA;
        heirs[1] = heirB;
        uint256[] memory pcts = new uint256[](2);
        pcts[0] = 5_000;
        pcts[1] = 5_000;
        eth.setHeirs(heirs, pcts);
        address[] memory contacts = new address[](1);
        contacts[0] = contact;
        eth.setRecoveryUsers(contacts);
        vm.stopPrank();
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _claimed(address heir) internal view returns (bool c) {
        (,, c,,) = eth.getHeirInheritanceInfo(testator, heir);
    }

    /// Heir A claims 50 %, then a contact starts a recovery during the inheritance.
    function _aClaimsThenContactStartsRecovery() internal {
        _warp(eth.inheritInactivityPeriod());
        vm.prank(heirA);
        eth.startInheritance(testator);
        _warp(eth.inheritWaitingTime());
        vm.prank(heirA);
        eth.executeInheritance(testator);
        assertEq(eth.balanceOf(heirA), 50 ether, "A got its 50 %");
        vm.prank(contact);
        eth.startRecovery(testator);
    }

    // ============ AUD3-01 ============

    /// An abandoned recovery keeps the claim marks: when the heirs replace it, the
    /// split continues and A cannot claim twice.
    function test_AUD3_01_abandonedRecovery_noDoubleClaim() public {
        _aClaimsThenContactStartsRecovery();
        assertTrue(_claimed(heirA), "A's claim mark is kept");
        (,,,,,,,, bool inhStarted,, bool recStarted,,) = eth.getUserInfo(testator);
        assertFalse(inhStarted, "inheritance disarmed");
        assertTrue(recStarted, "recovery armed");

        _warp(eth.recoveryExecutionWindow());
        vm.prank(heirB);
        eth.startInheritance(testator);
        _warp(eth.inheritWaitingTime());

        vm.prank(heirA);
        vm.expectRevert(bytes("Already claimed"));
        eth.executeInheritance(testator);

        vm.prank(heirB);
        eth.executeInheritance(testator);
        assertEq(eth.balanceOf(heirA), 50 ether, "A keeps 50");
        assertEq(eth.balanceOf(heirB), 50 ether, "B receives 50");
        assertEq(eth.balanceOf(testator), 0, "estate fully distributed");
    }

    /// If the testator returns while the recovery is armed, every claim mark is cleared
    /// (the originally proposed fix alone left them behind) and a later inheritance starts afresh.
    function test_AUD3_01_testatorReturnsDuringArmedRecovery_clearsMarks() public {
        _aClaimsThenContactStartsRecovery();

        vm.prank(testator);
        eth.checkActivity();
        assertFalse(_claimed(heirA), "marks cleared on return");
        (,,,,,,,, bool inhStarted,, bool recStarted,, bool closed) = eth.getUserInfo(testator);
        assertFalse(inhStarted, "no inheritance");
        assertFalse(recStarted, "no recovery");
        assertFalse(closed, "claims not closed");

        _warp(eth.inheritInactivityPeriod());
        vm.prank(heirA);
        eth.startInheritance(testator);
        _warp(eth.inheritWaitingTime());
        vm.prank(heirA);
        eth.executeInheritance(testator);
        vm.prank(heirB);
        eth.executeInheritance(testator);
        assertEq(eth.balanceOf(heirA), 75 ether, "A: 50 earlier plus 25 in the new process");
        assertEq(eth.balanceOf(heirB), 25 ether, "B: 25 in the new process");
        assertEq(eth.balanceOf(testator), 0, "estate fully distributed");
    }

    /// An executed recovery takes the whole balance and clears every claim mark.
    function test_AUD3_01_executedRecovery_clearsMarks() public {
        _aClaimsThenContactStartsRecovery();
        _warp(eth.recoveryWaitingTime());
        vm.prank(contact);
        eth.executeRecovery(testator);
        assertEq(eth.balanceOf(contact), 50 ether, "contact recovers the rest");
        assertEq(eth.balanceOf(testator), 0, "nothing left");
        assertFalse(_claimed(heirA), "marks cleared on execution");
        (,,,,,,,, bool inhStarted,, bool recStarted,, bool closed) = eth.getUserInfo(testator);
        assertFalse(inhStarted, "no inheritance");
        assertFalse(recStarted, "no recovery");
        assertFalse(closed, "claims not closed");
    }

    // ============ List caps ============

    function test_maxHeirs_cap40() public {
        eth.setMaxHeirs(40);
        assertEq(eth.maxHeirs(), 40, "40 accepted");
        vm.expectRevert(bytes("Bad value"));
        eth.setMaxHeirs(41);
    }

    function test_maxTreasuries_cap40() public {
        eth.setMaxTreasuries(40);
        assertEq(eth.maxTreasuries(), 40, "40 accepted");
        vm.expectRevert(bytes("Bad value"));
        eth.setMaxTreasuries(41);
    }

    function test_otherLimits_stillUpTo50() public {
        eth.setMaxRecoveryUsers(50);
        eth.setMaxDelegates(50);
        assertEq(eth.maxRecoveryUsers(), 50, "recovery users 50");
        assertEq(eth.maxDelegates(), 50, "delegates 50");
        vm.expectRevert(bytes("Bad value"));
        eth.setMaxRecoveryUsers(51);
        vm.expectRevert(bytes("Bad value"));
        eth.setMaxDelegates(51);
    }

    // ============ Minimum 3-day exclusive recovery window ============

    function test_window_minGap_onWindowSetter() public {
        uint256 waiting = eth.recoveryWaitingTime();
        vm.expectRevert(bytes("Must be > waiting"));
        eth.setRecoveryExecutionWindow(waiting + 3 days - 1);
        eth.setRecoveryExecutionWindow(waiting + 3 days);
        assertEq(eth.recoveryExecutionWindow(), waiting + 3 days, "gap of exactly 3 days accepted");
    }

    function test_window_minGap_onWaitingSetter() public {
        uint256 window = eth.recoveryExecutionWindow();
        vm.expectRevert(bytes("Must be < window"));
        eth.setRecoveryWaitingTime(window - 3 days + 1);
        eth.setRecoveryWaitingTime(window - 3 days);
        assertEq(eth.recoveryWaitingTime(), window - 3 days, "gap of exactly 3 days accepted");
    }

    // ============ Minimum inactivity periods ============

    function test_minRecoveryInactivity_14days() public {
        vm.expectRevert(bytes("Bad period"));
        eth.setRecoveryInactivityPeriod(14 days - 1);
        eth.setRecoveryInactivityPeriod(14 days);
        assertEq(eth.recoveryInactivityPeriod(), 14 days, "14 days accepted");
    }

    function test_minInheritInactivity_21days() public {
        eth.setRecoveryInactivityPeriod(14 days);
        vm.expectRevert(bytes("Bad period"));
        eth.setInheritInactivityPeriod(21 days - 1);
        eth.setInheritInactivityPeriod(21 days);
        assertEq(eth.inheritInactivityPeriod(), 21 days, "21 days accepted");
    }

    // ============ New defaults ============

    function test_newDefaults() public view {
        assertEq(eth.recoveryInactivityPeriod(), 30 days, "recovery inactivity");
        assertEq(eth.inheritInactivityPeriod(), 45 days, "inherit inactivity");
        assertEq(eth.inheritWaitingTime(), 7 days, "inherit waiting");
        assertEq(eth.inheritRemainingWaitingTime(), 14 days, "remaining waiting");
        assertEq(eth.recoveryWaitingTime(), 7 days, "recovery waiting");
        assertEq(eth.recoveryExecutionWindow(), 30 days, "execution window");
        assertEq(eth.maxHeirs(), 30, "max heirs");
        assertEq(eth.maxRecoveryUsers(), 15, "max recovery users");
        assertEq(eth.maxTreasuries(), 25, "max treasuries");
        assertEq(eth.maxDelegates(), 20, "max delegates");
    }
}
