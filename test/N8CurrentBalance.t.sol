// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// N-8: executeInheritance pays from the current balance:
// share = balance * pct / (BP - pct already claimed). The last one receives the whole balance.
// A claim of 0 is paid, marks the heir as claimed, and the heir takes part in the remaining.
contract N8CurrentBalanceTest is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address A = makeAddr("heirA");
    address B = makeAddr("heirB");
    address C = makeAddr("heirC");
    address X = makeAddr("thirdParty");
    uint256 constant BP = 10_000;

    function setUp() public {
        eth = new InheritfiV1ETH();
        eth.setWrappingTax(0); // the testator ends up with exactly 100 iETH
        vm.deal(T, 100 ether);
        vm.prank(T);
        eth.wrap{value: 100 ether}();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _net(uint256 x) internal view returns (uint256) {
        return x - (x * eth.inheritanceTax()) / BP;
    }

    // Inactivity time elapsed, inheritance started and claim window open.
    function _start(address initiator) internal {
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(initiator);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
    }

    // Claims and checks that what is received matches the potential shown just before.
    function _claim(address heir) internal returns (uint256 got) {
        (,,, uint256 shown,) = eth.getHeirInheritanceInfo(T, heir);
        uint256 before = eth.balanceOf(heir);
        vm.prank(heir);
        eth.executeInheritance(T);
        got = eth.balanceOf(heir) - before;
        assertEq(got, shown, "receives what was shown");
    }

    // Claims and checks that exactly the gross share leaves the testator, never overpaying.
    function _step(address heir) internal returns (uint256 rel) {
        uint256 tb = eth.balanceOf(T);
        _claim(heir);
        (, rel,,,) = eth.getHeirInheritanceInfo(T, heir);
        assertEq(tb - eth.balanceOf(T), rel, "the gross share leaves the testator");
        assertLe(rel, tb, "never overpaid");
    }

    function _heirs(uint256 n) internal returns (address[] memory w) {
        w = new address[](n);
        for (uint256 i; i < n; i++) w[i] = makeAddr(string.concat("heir", vm.toString(i)));
    }

    // n percentages >= 1 that add up to exactly BP.
    function _randPcts(uint256 n, uint256 seed) internal pure returns (uint256[] memory p) {
        p = new uint256[](n);
        uint256 left = BP;
        for (uint256 i; i < n - 1; i++) {
            uint256 maxHere = left - (n - 1 - i);
            p[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, maxHere);
            left -= p[i];
        }
        p[n - 1] = left;
    }

    function _perm(uint256 k) internal pure returns (uint256[3] memory o) {
        k = k % 6;
        if (k == 0) o = [uint256(0), 1, 2];
        else if (k == 1) o = [uint256(0), 2, 1];
        else if (k == 2) o = [uint256(1), 0, 2];
        else if (k == 3) o = [uint256(1), 2, 0];
        else if (k == 4) o = [uint256(2), 0, 1];
        else o = [uint256(2), 1, 0];
    }

    // ─── Tests ────────────────────────────────────────────────────────────────

    // Design example: 100 iETH, A 30 %, B 45 %, C 25 %.
    // A claims 30; a spender withdraws 50; C claims 20*25/70; 100 arrive; B (last) claims everything.
    function test_userExample_30_45_25() public {
        address[] memory w = new address[](3);
        uint256[] memory p = new uint256[](3);
        w[0] = A; w[1] = B; w[2] = C;
        p[0] = 3000; p[1] = 4500; p[2] = 2500;
        vm.startPrank(T);
        eth.setHeirs(w, p);
        eth.approve(X, type(uint256).max);
        vm.stopPrank();
        assertEq(eth.balanceOf(T), 100 ether, "initial balance 100");
        _start(A);

        // A: 100 * 3000 / 10000 = 30
        assertEq(_claim(A), _net(30 ether), "A: 30 minus tax");
        assertEq(eth.balanceOf(T), 70 ether, "70 left");

        // A spender withdraws 50 (not a proof of life).
        vm.prank(X);
        eth.transferFrom(T, X, 50 ether);
        assertEq(eth.balanceOf(T), 20 ether, "20 left");

        // C: 20 * 2500 / 7000 = 7.142857142857142857
        uint256 grossC = (uint256(20 ether) * 2500) / 7000;
        assertEq(grossC, 7142857142857142857, "gross C");
        assertEq(_claim(C), _net(grossC), "C: 7.14 minus tax");

        // 100 iETH arrive in the testator's wallet.
        vm.deal(X, 100 ether);
        vm.startPrank(X);
        eth.wrap{value: 100 ether}();
        eth.transfer(T, 100 ether);
        vm.stopPrank();
        uint256 balB = eth.balanceOf(T);
        assertEq(balB, 120 ether - grossC, "balance before B: 112.857142857142857143");

        // B is the last one: 4500 / 4500 = the whole balance.
        assertEq(_claim(B), _net(balB), "B: whole balance minus tax");
        assertEq(eth.balanceOf(T), 0, "testator at 0");
        (,,, uint256 released,,,,,,,,,) = eth.getUserInfo(T);
        assertEq(released, 150 ether, "total released 30 + 7.14 + 112.86");
    }

    // Start on dust: nobody gets blocked. A claims 0 and is marked; B (last)
    // takes the dust; whatever arrives later is split by the remaining, A included.
    function test_dustStart_zeroShareMarked_andInRemainder() public {
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = A; w[1] = B;
        p[0] = 5000; p[1] = 5000;
        vm.startPrank(T);
        eth.setHeirs(w, p);
        eth.transfer(X, eth.balanceOf(T) - 1);
        vm.stopPrank();
        assertEq(eth.balanceOf(T), 1, "testator with 1 wei");
        _start(A); // no longer reverts on dust

        assertEq(_claim(A), 0, "A claims 0");
        (,, bool markedA,,) = eth.getHeirInheritanceInfo(T, A);
        assertTrue(markedA, "A is marked as claimed");
        assertEq(_claim(B), 1, "B last: 1 wei, tax 0");
        assertEq(eth.balanceOf(T), 0, "testator at 0");

        // 10 iETH arrive; the remaining window opens.
        vm.deal(X, 10 ether);
        vm.startPrank(X);
        eth.wrap{value: 10 ether}();
        eth.transfer(T, 10 ether);
        vm.stopPrank();
        (,,,,,,,,, uint256 startTs,,,) = eth.getUserInfo(T);
        vm.warp(startTs + eth.inheritWaitingTime() + eth.inheritRemainingWaitingTime());

        (,,,, uint256 rA) = eth.getHeirInheritanceInfo(T, A);
        (,,,, uint256 rB) = eth.getHeirInheritanceInfo(T, B);
        assertEq(rA, _net((uint256(10 ether) * 5000) / BP), "remaining A 50 %");
        assertGt(rA, 0, "A takes part in the remaining although it claimed 0");
        uint256 bA = eth.balanceOf(A);
        uint256 bB = eth.balanceOf(B);
        vm.prank(A);
        eth.executeInheritanceRemaining(T);
        assertEq(eth.balanceOf(A) - bA, rA, "A receives the remaining shown");
        assertEq(eth.balanceOf(B) - bB, rB, "B receives the remaining shown");
    }

    // Constant balance: each heir receives exactly its percentage, in any order.
    // With 100 iETH, balance / BP = 1e16 exactly, so there is no rounding.
    function testFuzz_orderIndependence(uint256 pSeed, uint256 orderSeed) public {
        uint256[] memory p = _randPcts(3, pSeed);
        address[] memory w = _heirs(3);
        vm.prank(T);
        eth.setHeirs(w, p);
        _start(w[0]);

        uint256[3] memory o = _perm(orderSeed);
        for (uint256 i; i < 3; i++) _step(w[o[i]]);

        for (uint256 j; j < 3; j++) {
            (, uint256 rel,,,) = eth.getHeirInheritanceInfo(T, w[j]);
            assertEq(rel, 1e16 * p[j], "exactly its percentage");
        }
        assertEq(eth.balanceOf(T), 0, "testator at 0");
    }

    // Random balance and percentages, with a random spender withdrawal before one claim.
    // Never overpaid, what is shown is what is received, the last one leaves the balance at 0 and
    // what is paid (gross) plus what is withdrawn is exactly the initial balance.
    function testFuzz_conservation(uint8 nSeed, uint256 pSeed, uint256 bal, uint256 drainSeed, uint8 drainAt)
        public
    {
        uint256 n = bound(nSeed, 1, 5);
        bal = bound(bal, 1, 100 ether);
        uint256[] memory p = _randPcts(n, pSeed);
        address[] memory w = _heirs(n);
        vm.startPrank(T);
        eth.setHeirs(w, p);
        eth.approve(X, type(uint256).max);
        eth.transfer(X, eth.balanceOf(T) - bal);
        vm.stopPrank();
        _start(w[0]);

        uint256 drainIndex = bound(drainAt, 0, n - 1);
        uint256 drained;
        uint256 paid;
        for (uint256 i; i < n; i++) {
            if (i == drainIndex) drained = _drain(drainSeed);
            paid += _step(w[i]);
        }
        assertEq(eth.balanceOf(T), 0, "the last one leaves the balance at 0");
        assertEq(paid + drained, bal, "conservation");
    }

    function _drain(uint256 seed) internal returns (uint256 d) {
        d = bound(seed, 0, eth.balanceOf(T));
        if (d > 0) {
            vm.prank(X);
            eth.transferFrom(T, X, d);
        }
    }
}
