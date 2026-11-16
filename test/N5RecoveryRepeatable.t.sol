// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// N-5 (design): recovery can be repeated without limit. executeRecovery does not renew the
// testator's activity, so when new funds arrive another recovery can be started immediately.
contract N5RecoveryRepeatableTest is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address R1 = makeAddr("recovery1");
    address R2 = makeAddr("recovery2");
    address A = makeAddr("heirA");
    address B = makeAddr("heirB");
    address X = makeAddr("thirdParty");
    uint256 constant BP = 10_000;

    function setUp() public {
        eth = new InheritfiV1ETH();
        eth.setWrappingTax(0); // the testator ends up with exactly 100 iETH
        vm.deal(T, 100 ether);
        address[] memory r = new address[](2);
        r[0] = R1; r[1] = R2;
        vm.startPrank(T);
        eth.wrap{value: 100 ether}();
        eth.setRecoveryUsers(r);
        vm.stopPrank();
    }

    function _net(uint256 x) internal view returns (uint256) {
        return x - (x * eth.recoveryTax()) / BP;
    }

    function _activity() internal view returns (uint256 a) {
        (,,,,, a,,,,,,,) = eth.getUserInfo(T);
    }

    function _sendToT(uint256 amount) internal {
        vm.deal(X, amount);
        vm.startPrank(X);
        eth.wrap{value: amount}();
        eth.transfer(T, amount);
        vm.stopPrank();
    }

    function _setHeirs() internal {
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = A; w[1] = B;
        p[0] = 5000; p[1] = 5000;
        vm.prank(T);
        eth.setHeirs(w, p);
    }

    // Full recovery with `ru`: executing too early reverts; afterwards it recovers
    // the whole balance minus the tax and leaves the testator at 0.
    function _recover(address ru) internal {
        uint256 bal = eth.balanceOf(T);
        vm.prank(ru);
        eth.startRecovery(T);
        vm.prank(ru);
        vm.expectRevert(bytes("Too soon"));
        eth.executeRecovery(T);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryWaitingTime());
        uint256 before = eth.balanceOf(ru);
        vm.prank(ru);
        eth.executeRecovery(T);
        assertEq(eth.balanceOf(ru) - before, _net(bal), "recovers everything minus the tax");
        assertEq(eth.balanceOf(T), 0, "testator at 0");
    }

    // Three recoveries in a row; after the first one there is no need to wait for inactivity again.
    function test_recoveryRepeatable() public {
        uint256 act0 = _activity();
        vm.warp(vm.getBlockTimestamp() + eth.recoveryInactivityPeriod());
        _recover(R1);
        assertEq(_activity(), act0, "executeRecovery does not renew the testator's activity");

        // Without a balance a recovery can be armed in advance, but not executed (OBS-01).
        vm.prank(R2);
        eth.startRecovery(T);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryWaitingTime());
        vm.prank(R2);
        vm.expectRevert(bytes("No balance"));
        eth.executeRecovery(T);

        // New funds arrive: the armed recovery is executed right away.
        _sendToT(10 ether);
        uint256 before = eth.balanceOf(R2);
        vm.prank(R2);
        eth.executeRecovery(T);
        assertEq(eth.balanceOf(R2) - before, _net(10 ether), "recovers the new funds minus the tax");
        assertEq(eth.balanceOf(T), 0, "testator at 0");

        // And once more, with the same recovery user as at the beginning.
        _sendToT(3 ether);
        _recover(R1);

        (,, uint256 recovered,,,,,,,,,,) = eth.getUserInfo(T);
        assertEq(recovered, 113 ether, "total recovered 100 + 10 + 3");
    }

    // While a recovery is active, the heirs cannot start the inheritance.
    function test_heirsBlockedWhileRecoveryActive() public {
        _setHeirs();
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(R1);
        eth.startRecovery(T);
        vm.prank(A);
        vm.expectRevert(bytes("Process active"));
        eth.startInheritance(T);
    }

    // A recovery cancels an ongoing inheritance (with one claim already made) and recovers the rest.
    function test_recoveryCancelsInheritanceInProgress() public {
        _setHeirs();
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(A);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        vm.prank(A);
        eth.executeInheritance(T);
        assertEq(eth.balanceOf(T), 50 ether, "A claimed its 50 %");

        _recover(R1);
        (,,,,,,,, bool inhStarted,,,,) = eth.getUserInfo(T);
        assertFalse(inhStarted, "inheritance cancelled");
        (,, bool markedA,,) = eth.getHeirInheritanceInfo(T, A);
        assertFalse(markedA, "A's claim mark cleared");
    }
}
