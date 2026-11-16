// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// AUD2-03: a recovery that is started and never executed must not block the
// inheritance forever. Once recoveryExecutionWindow has passed since the
// recovery started, an heir may replace it by starting the inheritance; until
// an heir does so, the recovery user can still execute it, and a recovery user
// can always re-arm a recovery, which cancels the inheritance (A-01).
// OBS-01: a recovery can be armed with a zero balance, so recovery users can
// protect future funds; executing it still requires a balance.
contract AUD203RecoveryExpiryTest is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address H1 = makeAddr("heir1");
    address H2 = makeAddr("heir2");
    address R = makeAddr("recoveryUser");
    address S = makeAddr("sender");
    uint256 t0;

    event RecoveryExecutionWindowUpdated(uint256 old, uint256 nv);

    function setUp() public {
        eth = new InheritfiV1ETH();
        vm.deal(T, 10 ether);
        vm.startPrank(T);
        eth.wrap{value: 10 ether}();
        address[] memory hs = new address[](2);
        uint256[] memory ps = new uint256[](2);
        hs[0] = H1;
        ps[0] = 5_000;
        hs[1] = H2;
        ps[1] = 5_000;
        eth.setHeirs(hs, ps);
        address[] memory rus = new address[](1);
        rus[0] = R;
        eth.setRecoveryUsers(rus);
        vm.stopPrank();
        t0 = vm.getBlockTimestamp();
    }

    function _inheritanceStarted() internal view returns (bool s) {
        (,,,,,,,, s,,,,) = eth.getUserInfo(T);
    }

    function _recoveryStarted() internal view returns (bool s) {
        (,,,,,,,,,, s,,) = eth.getUserInfo(T);
    }

    // R arms a recovery once T has been inactive long enough for both processes.
    function _armRecovery() internal returns (uint256 start) {
        vm.warp(t0 + eth.inheritInactivityPeriod());
        vm.prank(R);
        eth.startRecovery(T);
        start = vm.getBlockTimestamp();
        assertTrue(_recoveryStarted(), "recovery armed");
    }

    // ─── Expiry behaviour ─────────────────────────────────────────────────────

    function test_heirsBlockedBeforeExpiry() public {
        uint256 start = _armRecovery();
        vm.warp(start + eth.recoveryExecutionWindow() - 1);
        vm.prank(H1);
        vm.expectRevert(bytes("Process active"));
        eth.startInheritance(T);
    }

    function test_heirsReplaceExpiredRecovery() public {
        uint256 start = _armRecovery();
        vm.warp(start + eth.recoveryExecutionWindow());
        vm.prank(H1);
        eth.startInheritance(T);
        assertTrue(_inheritanceStarted(), "inheritance started");
        assertFalse(_recoveryStarted(), "expired recovery disarmed");
    }

    function test_recoveryUserStillExecutesIfNoHeirActed() public {
        uint256 start = _armRecovery();
        vm.warp(start + eth.recoveryExecutionWindow() + 10 days);
        vm.prank(R);
        eth.executeRecovery(T);
        assertEq(eth.balanceOf(T), 0, "R recovered everything");
        assertFalse(_recoveryStarted(), "recovery closed");
    }

    function test_recoveryUserReArmsAfterHeirReplacement() public {
        uint256 start = _armRecovery();
        vm.warp(start + eth.recoveryExecutionWindow());
        vm.prank(H1);
        eth.startInheritance(T);
        vm.prank(R);
        eth.startRecovery(T);
        assertTrue(_recoveryStarted(), "recovery re-armed");
        assertFalse(_inheritanceStarted(), "inheritance cancelled (A-01)");
    }

    // F1: a window change applies to a recovery that is already armed.
    function test_windowChangeAppliesToArmedRecovery() public {
        uint256 start = _armRecovery();
        eth.setRecoveryExecutionWindow(10 days);
        vm.warp(start + 10 days - 1);
        vm.prank(H1);
        vm.expectRevert(bytes("Process active"));
        eth.startInheritance(T);
        vm.warp(start + 10 days);
        vm.prank(H1);
        eth.startInheritance(T);
        assertFalse(_recoveryStarted(), "replaced under the new window");
    }

    // ─── OBS-01 ───────────────────────────────────────────────────────────────

    // Once the heirs emptied T, R arms a recovery at zero balance; the heirs can
    // no longer sweep new funds and R recovers them.
    function test_recoveryArmedAtZeroBalanceProtectsFutureFunds() public {
        vm.warp(t0 + eth.inheritInactivityPeriod());
        vm.prank(H1);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        vm.prank(H1);
        eth.executeInheritance(T);
        vm.prank(H2);
        eth.executeInheritance(T);
        assertEq(eth.balanceOf(T), 0, "T emptied by the heirs");

        vm.prank(R);
        eth.startRecovery(T);
        assertTrue(_recoveryStarted(), "armed at zero balance");
        assertFalse(_inheritanceStarted(), "inheritance cancelled");

        vm.warp(vm.getBlockTimestamp() + eth.inheritRemainingWaitingTime());
        vm.deal(S, 5 ether);
        vm.startPrank(S);
        eth.wrap{value: 5 ether}();
        uint256 arriving = eth.balanceOf(S);
        eth.transfer(T, arriving);
        vm.stopPrank();

        vm.prank(H1);
        vm.expectRevert(bytes("Not started"));
        eth.executeInheritanceRemaining(T);

        uint256 before = eth.balanceOf(R);
        vm.prank(R);
        eth.executeRecovery(T);
        assertEq(eth.balanceOf(T), 0, "new funds recovered");
        assertEq(eth.balanceOf(R) - before, arriving - (arriving * eth.recoveryTax()) / 10_000, "R got the new funds minus tax");
    }

    // Arming at zero balance is allowed, executing at zero balance is not.
    function test_executeRecoveryStillRequiresBalance() public {
        vm.warp(t0 + eth.inheritInactivityPeriod());
        vm.prank(H1);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        vm.prank(H1);
        eth.executeInheritance(T);
        vm.prank(H2);
        eth.executeInheritance(T);

        vm.prank(R);
        eth.startRecovery(T);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryWaitingTime());
        vm.prank(R);
        vm.expectRevert(bytes("No balance"));
        eth.executeRecovery(T);
    }

    // ─── Setters ──────────────────────────────────────────────────────────────

    function test_defaultWindow() public view {
        assertEq(eth.recoveryExecutionWindow(), 30 days, "default window");
    }

    function test_setWindow_bounds() public {
        vm.expectRevert(bytes("Bad period"));
        eth.setRecoveryExecutionWindow(7 days - 1);
        vm.expectRevert(bytes("Bad period"));
        eth.setRecoveryExecutionWindow(90 days + 1);
        eth.setRecoveryWaitingTime(2 days);
        eth.setRecoveryExecutionWindow(7 days);
        assertEq(eth.recoveryExecutionWindow(), 7 days, "minimum accepted");
        eth.setRecoveryExecutionWindow(90 days);
        assertEq(eth.recoveryExecutionWindow(), 90 days, "maximum accepted");
    }

    function test_setWindow_mustExceedWaiting() public {
        uint256 waiting = eth.recoveryWaitingTime();
        vm.expectRevert(bytes("Must be > waiting"));
        eth.setRecoveryExecutionWindow(waiting);
    }

    function test_setWaiting_mustStayBelowWindow() public {
        uint256 window = eth.recoveryExecutionWindow();
        vm.expectRevert(bytes("Must be < window"));
        eth.setRecoveryWaitingTime(window);
        // Raising both: the window goes first.
        eth.setRecoveryExecutionWindow(60 days);
        eth.setRecoveryWaitingTime(window);
        assertEq(eth.recoveryWaitingTime(), window, "waiting raised after the window");
    }

    function test_setWindow_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(eth));
        emit RecoveryExecutionWindowUpdated(30 days, 45 days);
        eth.setRecoveryExecutionWindow(45 days);
    }

    function test_setWindow_onlyOwner() public {
        vm.prank(S);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, S));
        eth.setRecoveryExecutionWindow(45 days);
    }
}
