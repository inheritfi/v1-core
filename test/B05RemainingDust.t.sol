// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// B-05: executeInheritanceRemaining must distribute the testator's whole balance
// among the heirs who already claimed; the last of them takes the rounding residue
// (same rule as collectTax), so no dust is left behind.
contract B05RemainingDustTest is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address U = makeAddr("funder");
    address H1 = makeAddr("heir1");
    address H2 = makeAddr("heir2");
    address H3 = makeAddr("heir3");

    function setUp() public {
        eth = new InheritfiV1ETH();
        vm.deal(T, 10 ether);
        vm.prank(T);
        eth.wrap{value: 10 ether}();
        vm.deal(U, 100 ether);
        vm.prank(U);
        eth.wrap{value: 100 ether}();
        address[] memory w = new address[](3);
        uint256[] memory p = new uint256[](3);
        w[0] = H1; w[1] = H2; w[2] = H3;
        p[0] = 3333; p[1] = 3333; p[2] = 3334;
        vm.prank(T);
        eth.setHeirs(w, p);
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(H1);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
    }

    function _claim(address h) internal {
        vm.prank(h);
        eth.executeInheritance(T);
    }

    // Sends `amount` iETH to the testator and runs the remaining step. Checks that each
    // heir receives exactly the potentialRemaining reported just before, that nothing is
    // left with the testator and that every unit went to the heirs or to the tax pool.
    function _remainingLeavesNoDust(uint256 amount, address caller) internal {
        vm.prank(U);
        eth.transfer(T, amount);
        uint256 bal = eth.balanceOf(T);
        uint256 taxBefore = eth.accumulatedTax();
        (,,,,,,,,, uint256 startTs,,,) = eth.getUserInfo(T);
        vm.warp(startTs + eth.inheritWaitingTime() + eth.inheritRemainingWaitingTime());

        address[3] memory hs = [H1, H2, H3];
        uint256[3] memory expected;
        uint256[3] memory before;
        for (uint256 i; i < 3; i++) {
            (,,,, expected[i]) = eth.getHeirInheritanceInfo(T, hs[i]);
            before[i] = eth.balanceOf(hs[i]);
        }

        vm.prank(caller);
        eth.executeInheritanceRemaining(T);

        uint256 gained;
        for (uint256 i; i < 3; i++) {
            uint256 g = eth.balanceOf(hs[i]) - before[i];
            assertEq(g, expected[i], "potentialRemaining == net actually received");
            gained += g;
        }
        assertEq(eth.balanceOf(T), 0, "B-05: no dust left with the testator");
        assertEq(gained + eth.accumulatedTax() - taxBefore, bal, "whole balance distributed");
    }

    // Three heirs at 33.33 / 33.33 / 33.34 %: 100 wei cannot be split exactly.
    function test_allClaimed_oddAmount() public {
        _claim(H1);
        _claim(H2);
        _claim(H3);
        assertEq(eth.balanceOf(T), 0, "last claimer took the whole balance (N-8)");
        _remainingLeavesNoDust(100, H1);
    }

    // Only H1 and H2 claimed: the remaining goes to them alone and H3 receives nothing.
    function test_partialClaim_onlyClaimersReceive() public {
        _claim(H1);
        _claim(H2);
        uint256 h3Before = eth.balanceOf(H3);
        _remainingLeavesNoDust(101, H2);
        assertEq(eth.balanceOf(H3), h3Before, "non-claiming heir receives nothing");
    }

    // Any amount received after every heir claimed is fully distributed.
    function testFuzz_allClaimed_anyAmount(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        _claim(H1);
        _claim(H2);
        _claim(H3);
        _remainingLeavesNoDust(amount, H3);
    }
}
