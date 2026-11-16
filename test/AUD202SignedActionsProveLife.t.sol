// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// AUD2-02: every succession action signed by a wallet (startInheritance,
// executeInheritance, executeInheritanceRemaining, startRecovery,
// executeRecovery) is proof of life of that wallet only: it renews the
// signer's clock and disarms any process started against the signer as a
// testator, while the testator whose iTokens are being claimed is untouched.
// T has heirs H and H2 (50/50) and recovery user R; H and R are testators
// themselves, with heir Z.
contract AUD202SignedActionsProveLifeTest is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address H = makeAddr("heirOfT");
    address H2 = makeAddr("secondHeirOfT");
    address R = makeAddr("recoveryUserOfT");
    address Z = makeAddr("heirOfHAndR");
    uint256 t0;

    function setUp() public {
        eth = new InheritfiV1ETH();
        vm.deal(T, 10 ether);
        vm.deal(H, 1 ether);
        vm.deal(R, 1 ether);

        vm.startPrank(T);
        eth.wrap{value: 10 ether}();
        address[] memory hs = new address[](2);
        uint256[] memory ps = new uint256[](2);
        hs[0] = H;
        ps[0] = 5_000;
        hs[1] = H2;
        ps[1] = 5_000;
        eth.setHeirs(hs, ps);
        address[] memory rus = new address[](1);
        rus[0] = R;
        eth.setRecoveryUsers(rus);
        vm.stopPrank();

        _ownTestatorWithHeirZ(H);
        _ownTestatorWithHeirZ(R);
        t0 = vm.getBlockTimestamp();
        assertEq(_activity(T), t0, "T clock at setup");
    }

    function _ownTestatorWithHeirZ(address who) internal {
        vm.startPrank(who);
        eth.wrap{value: 1 ether}();
        address[] memory hs = new address[](1);
        uint256[] memory ps = new uint256[](1);
        hs[0] = Z;
        ps[0] = 10_000;
        eth.setHeirs(hs, ps);
        vm.stopPrank();
    }

    function _activity(address u) internal view returns (uint256 a) {
        (,,,,, a,,,,,,,) = eth.getUserInfo(u);
    }

    function _inheritanceStarted(address u) internal view returns (bool s) {
        (,,,,,,,, s,,,,) = eth.getUserInfo(u);
    }

    function _zStartsAgainst(address signer) internal {
        vm.prank(Z);
        eth.startInheritance(signer);
        assertTrue(_inheritanceStarted(signer), "process armed against the signer");
    }

    // The signer proved life: own process disarmed, own clock renewed, Z cannot
    // claim; the testator T whose iTokens were claimed did not prove life.
    function _assertSignerAliveTestatorNot(address signer) internal {
        assertFalse(_inheritanceStarted(signer), "signer's own process disarmed");
        assertEq(_activity(signer), vm.getBlockTimestamp(), "signer's clock renewed");
        assertEq(_activity(T), t0, "T's clock untouched");
        vm.prank(Z);
        vm.expectRevert(bytes("Not started"));
        eth.executeInheritance(signer);
    }

    function test_startInheritance_provesHeirAlive() public {
        vm.warp(t0 + eth.inheritInactivityPeriod());
        _zStartsAgainst(H);
        vm.prank(H);
        eth.startInheritance(T);
        _assertSignerAliveTestatorNot(H);
    }

    function test_executeInheritance_provesHeirAlive() public {
        vm.warp(t0 + eth.inheritInactivityPeriod());
        vm.prank(H2);
        eth.startInheritance(T);
        _zStartsAgainst(H);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        vm.prank(H);
        eth.executeInheritance(T);
        _assertSignerAliveTestatorNot(H);
    }

    function test_executeInheritanceRemaining_provesHeirAlive() public {
        vm.warp(t0 + eth.inheritInactivityPeriod());
        vm.prank(H2);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        vm.prank(H);
        eth.executeInheritance(T);
        // Long enough for Z to start against H under either rule, and for the
        // remainder window of T's process to be open.
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        _zStartsAgainst(H);
        assertGt(eth.balanceOf(T), 0, "H2's unclaimed half is still with T");
        vm.prank(H);
        eth.executeInheritanceRemaining(T);
        _assertSignerAliveTestatorNot(H);
    }

    function test_startRecovery_provesRecoveryUserAlive() public {
        vm.warp(t0 + eth.inheritInactivityPeriod());
        _zStartsAgainst(R);
        vm.prank(R);
        eth.startRecovery(T);
        _assertSignerAliveTestatorNot(R);
    }

    // The reported scenario: R recovers T's funds while R's own heir has an
    // inheritance armed against R; R must keep what it recovered.
    function test_executeRecovery_provesRecoveryUserAlive() public {
        vm.warp(t0 + eth.recoveryInactivityPeriod());
        vm.prank(R);
        eth.startRecovery(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        _zStartsAgainst(R);
        vm.prank(R);
        eth.executeRecovery(T);
        assertGt(eth.balanceOf(R), 10 ether, "R holds its own funds plus T's");
        _assertSignerAliveTestatorNot(R);
        assertGt(eth.balanceOf(R), 10 ether, "R keeps what it recovered");
    }
}
