// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// MAX_INAC: the recovery and inheritance inactivity periods accept up to 180 days.
// Every other period setter keeps MAX_P (90 days).
contract InactivityMax180Test is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address H = makeAddr("heir");

    function setUp() public {
        eth = new InheritfiV1ETH();
    }

    // Inheritance inactivity: 180 days accepted, one second more rejected.
    function test_inheritInactivityMax180() public {
        eth.setInheritInactivityPeriod(180 days);
        assertEq(eth.inheritInactivityPeriod(), 180 days, "inherit 180");
        vm.expectRevert(bytes("Bad period"));
        eth.setInheritInactivityPeriod(180 days + 1);
    }

    // Recovery inactivity: up to 180 days by range, always below inheritance.
    function test_recoveryInactivityMax180() public {
        eth.setInheritInactivityPeriod(180 days);
        eth.setRecoveryInactivityPeriod(179 days);
        assertEq(eth.recoveryInactivityPeriod(), 179 days, "recovery 179");
        vm.expectRevert(bytes("Must be < inherit"));
        eth.setRecoveryInactivityPeriod(180 days);
        vm.expectRevert(bytes("Bad period"));
        eth.setRecoveryInactivityPeriod(180 days + 1);
    }

    // The other seven period setters keep the 90-day maximum.
    function test_otherPeriodsKeep90() public {
        vm.expectRevert(bytes("Bad period"));
        eth.setInheritWaitingTime(90 days + 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setInheritRemainingWaitingTime(90 days + 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setRecoveryWaitingTime(90 days + 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setRecoveryExecutionWindow(90 days + 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setContractRecoveryStartWaitingTime(90 days + 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setContractRecoveryWaitingTime(90 days + 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setTaxCollectionWaitingTime(90 days + 1);
        eth.setInheritWaitingTime(90 days);
        eth.setInheritRemainingWaitingTime(90 days);
        eth.setRecoveryExecutionWindow(90 days);
        eth.setRecoveryWaitingTime(87 days);
        eth.setContractRecoveryStartWaitingTime(90 days);
        eth.setContractRecoveryWaitingTime(90 days);
        eth.setTaxCollectionWaitingTime(90 days);
        assertEq(eth.inheritWaitingTime(), 90 days, "inherit waiting 90");
        assertEq(eth.inheritRemainingWaitingTime(), 90 days, "remaining 90");
        assertEq(eth.recoveryExecutionWindow(), 90 days, "window 90");
        assertEq(eth.recoveryWaitingTime(), 87 days, "recovery waiting 3 days below window");
        assertEq(eth.contractRecoveryStartWaitingTime(), 90 days, "contract recovery start 90");
        assertEq(eth.contractRecoveryWaitingTime(), 90 days, "contract recovery 90");
        assertEq(eth.taxCollectionWaitingTime(), 90 days, "tax collection 90");
    }

    // With 180 days of inheritance inactivity, an heir can start only after 180 days.
    function test_inheritanceStartsAfter180Days() public {
        eth.setInheritInactivityPeriod(180 days);
        vm.deal(T, 1 ether);
        vm.startPrank(T);
        eth.wrap{value: 1 ether}();
        address[] memory hs = new address[](1);
        uint256[] memory ps = new uint256[](1);
        hs[0] = H;
        ps[0] = 10_000;
        eth.setHeirs(hs, ps);
        vm.stopPrank();
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 180 days - 1);
        vm.prank(H);
        vm.expectRevert(bytes("Too soon"));
        eth.startInheritance(T);
        vm.warp(t0 + 180 days);
        vm.prank(H);
        eth.startInheritance(T);
        (,,,,,,,, bool started,,,,) = eth.getUserInfo(T);
        assertTrue(started, "inheritance started at 180 days");
    }
}
