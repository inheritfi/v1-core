// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

contract HeirPotentialsTest is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address A = makeAddr("heirA");
    address B = makeAddr("heirB");
    address C = makeAddr("heirC");
    address X = makeAddr("thirdParty");
    uint256 constant BP = 10_000;

    function setUp() public {
        eth = new InheritfiV1ETH();
        vm.deal(T, 100 ether);
        vm.prank(T);
        eth.wrap{value: 100 ether}();
    }

    function _net(uint256 x) internal view returns (uint256) {
        return x - (x * eth.inheritanceTax()) / BP;
    }

    function _pot(address heir) internal view returns (uint256 p, uint256 r) {
        (,,, p, r) = eth.getHeirInheritanceInfo(T, heir);
    }

    function _setHeirs3() internal {
        address[] memory w = new address[](3);
        uint256[] memory p = new uint256[](3);
        w[0] = A; w[1] = B; w[2] = C;
        p[0] = 5000; p[1] = 3000; p[2] = 2000;
        vm.prank(T);
        eth.setHeirs(w, p);
    }

    // Full scenario: projection, claims on the current balance, remaining, lock, new funds and reset.
    function test_fullFlow() public {
        _setHeirs3();
        uint256 bal = eth.balanceOf(T);

        // 1) Inheritance not started: projection on the current balance, remaining 0.
        (uint256 pA, uint256 rA) = _pot(A);
        assertEq(pA, _net((bal * 5000) / BP), "projection A");
        assertEq(rA, 0, "remaining A before start");

        // 2) Start inheritance: proportional share of the current balance (nobody has claimed: pct / BP).
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(A);
        eth.startInheritance(T);
        uint256 snap = eth.balanceOf(T);
        (pA, rA) = _pot(A);
        (uint256 pC,) = _pot(C);
        assertEq(pA, _net((snap * 5000) / BP), "exact A");
        assertEq(pC, _net((snap * 2000) / BP), "exact C");
        assertEq(rA, 0, "remaining A before claiming");

        // 3) A and C claim: what is received must be exactly what was shown.
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        uint256 before = eth.balanceOf(A);
        vm.prank(A);
        eth.executeInheritance(T);
        assertEq(eth.balanceOf(A) - before, pA, "A receives what was shown");

        before = eth.balanceOf(C);
        vm.prank(C);
        eth.executeInheritance(T);
        assertEq(eth.balanceOf(C) - before, pC, "C receives what was shown");

        // After claiming: potential 0; B (now the last one) sees the whole available balance.
        (pA, rA) = _pot(A);
        assertEq(pA, 0, "A already claimed");
        (uint256 pB, uint256 rB) = _pot(B);
        uint256 balNow = eth.balanceOf(T);
        assertEq(pB, _net(balNow), "B last: whole balance");
        assertEq(rB, 0, "B does not take part in the remaining");

        // 4a) Remaining window still closed: potentialRemaining 0 and the function reverts "Too soon".
        (, rA) = _pot(A);
        assertEq(rA, 0, "remaining A before the window");
        (,,,,,,,,, uint256 startTs,,,) = eth.getUserInfo(T);
        uint256 opens = startTs + eth.inheritWaitingTime() + eth.inheritRemainingWaitingTime();
        vm.warp(opens - 1);
        (, rA) = _pot(A);
        assertEq(rA, 0, "remaining A one second before");
        vm.prank(A);
        vm.expectRevert(bytes("Too soon"));
        eth.executeInheritanceRemaining(T);

        // 4) Remaining, at the exact opening second: what is received must match what was shown.
        vm.warp(opens);
        (, rA) = _pot(A);
        (, uint256 rC) = _pot(C);
        assertEq(rA, _net((balNow * 5000) / 7000), "remaining A formula");
        uint256 bA = eth.balanceOf(A);
        uint256 bC = eth.balanceOf(C);
        vm.prank(A);
        eth.executeInheritanceRemaining(T);
        assertEq(eth.balanceOf(A) - bA, rA, "A receives the remaining shown");
        assertEq(eth.balanceOf(C) - bC, rC, "C receives the remaining shown");

        // 5) Lock: B can no longer claim and its potential is 0.
        (pB, rB) = _pot(B);
        assertEq(pB, 0, "B potential 0 after closing");
        assertEq(rB, 0, "B remaining 0");
        vm.prank(B);
        vm.expectRevert(bytes("Claims closed"));
        eth.executeInheritance(T);
        (,,,,,,,,,,,, bool closed) = eth.getUserInfo(T);
        assertTrue(closed, "getUserInfo shows the lock closed");

        // 6) New iTokens arrive: A and C can claim again (A-03 design).
        vm.deal(X, 10 ether);
        vm.startPrank(X);
        eth.wrap{value: 10 ether}();
        eth.transfer(T, eth.balanceOf(X));
        vm.stopPrank();
        (, rA) = _pot(A);
        (, rC) = _pot(C);
        assertGt(rA, 0, "new remaining A > 0");
        bA = eth.balanceOf(A);
        bC = eth.balanceOf(C);
        vm.prank(C);
        eth.executeInheritanceRemaining(T);
        assertEq(eth.balanceOf(A) - bA, rA, "A receives the second remaining");
        assertEq(eth.balanceOf(C) - bC, rC, "C receives the second remaining");

        // 7) The testator proves life: everything is reset, including the lock.
        vm.prank(T);
        eth.checkActivity();
        (,,,,,,,, bool started,,,, bool closedAfterReset) = eth.getUserInfo(T);
        assertFalse(closedAfterReset, "lock reset in getUserInfo");
        assertFalse(started, "inheritance disarmed");
        (pB,) = _pot(B);
        assertEq(pB, _net((eth.balanceOf(T) * 3000) / BP), "B back to projection");

        // New process with a real balance (the remaining emptied the wallet): 20 ETH arrive in iTokens.
        vm.deal(X, 20 ether);
        vm.startPrank(X);
        eth.wrap{value: 20 ether}();
        eth.transfer(T, eth.balanceOf(X));
        vm.stopPrank();
        // New process: B can claim (lock reset).
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(B);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        (pB,) = _pot(B);
        before = eth.balanceOf(B);
        vm.prank(B);
        eth.executeInheritance(T);
        assertGt(pB, 0, "B has a real share");
        assertEq(eth.balanceOf(B) - before, pB, "B claims in the new process");
    }

    // A third party with allowance withdraws funds during the window: each claim uses the current balance,
    // split among those who have not claimed yet; the last one receives the whole available balance.
    function test_insufficientBalanceCases() public {
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = A; w[1] = B;
        p[0] = 5000; p[1] = 5000;
        vm.startPrank(T);
        eth.setHeirs(w, p);
        eth.approve(X, type(uint256).max);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(A);
        eth.startInheritance(T);
        uint256 snap = eth.balanceOf(T);

        // A third party with allowance takes 60 %: A claims its proportional share of the current balance.
        vm.prank(X);
        eth.transferFrom(T, X, (snap * 6000) / BP);
        uint256 balNow = eth.balanceOf(T);
        (uint256 pA,) = _pot(A);
        assertEq(pA, _net((balNow * 5000) / BP), "A: share of the current balance");
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        uint256 before = eth.balanceOf(A);
        vm.prank(A);
        eth.executeInheritance(T);
        assertEq(eth.balanceOf(A) - before, pA, "A receives what was shown");

        // X returns part: B is the last one and receives the whole available balance.
        vm.prank(X);
        eth.transfer(T, (snap * 1500) / BP);
        balNow = eth.balanceOf(T);
        (uint256 pB,) = _pot(B);
        assertEq(pB, _net(balNow), "B last: whole balance");
        before = eth.balanceOf(B);
        vm.prank(B);
        eth.executeInheritance(T);
        assertEq(eth.balanceOf(B) - before, pB, "B receives what was shown");
        assertEq(eth.balanceOf(T), 0, "testator balance at 0");
    }
}
