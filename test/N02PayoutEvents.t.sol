// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// N-2: the three payout events share one format, (testator, recipient, net, tax):
// InheritanceExecuted, InheritanceRemainingExecuted (previously gross, without tax)
// and RecoveryExecuted. Checked against the balances actually moved.
contract N02PayoutEventsTest is Test {
    InheritfiV1ETH eth;
    address T = makeAddr("testator");
    address U = makeAddr("funder");
    address H1 = makeAddr("heir1");
    address H2 = makeAddr("heir2");
    address RU = makeAddr("recoveryUser");

    bytes32 constant INH = keccak256("InheritanceExecuted(address,address,uint256,uint256)");
    bytes32 constant REM = keccak256("InheritanceRemainingExecuted(address,address,uint256,uint256)");
    bytes32 constant REM_OLD = keccak256("InheritanceRemainingExecuted(address,address,uint256)");
    bytes32 constant REC = keccak256("RecoveryExecuted(address,address,uint256,uint256)");

    function setUp() public {
        eth = new InheritfiV1ETH();
        vm.deal(T, 10 ether);
        vm.prank(T);
        eth.wrap{value: 10 ether}();
        vm.deal(U, 10 ether);
        vm.prank(U);
        eth.wrap{value: 10 ether}();
    }

    // Returns (recipient, amount, tax) of the only `topic0` event emitted by the wrapper.
    function _find(Vm.Log[] memory logs, bytes32 topic0, address testator) internal view returns (address who, uint256 amount, uint256 tax) {
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(eth) && logs[i].topics[0] == topic0) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), testator, "testator topic");
                who = address(uint160(uint256(logs[i].topics[2])));
                (amount, tax) = abi.decode(logs[i].data, (uint256, uint256));
                found++;
            }
        }
        assertEq(found, 1, "exactly one event");
    }

    function _heirs() internal {
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = H1; w[1] = H2;
        p[0] = 5000; p[1] = 5000;
        vm.prank(T);
        eth.setHeirs(w, p);
        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(H1);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
    }

    // executeInheritance and executeInheritanceRemaining report (net, tax) the same way.
    function test_inheritanceEvents_reportNetAndTax() public {
        _heirs();
        uint256 bal = eth.balanceOf(T);
        uint256 h1Before = eth.balanceOf(H1);
        uint256 taxBefore = eth.accumulatedTax();
        vm.recordLogs();
        vm.prank(H1);
        eth.executeInheritance(T);
        (address who, uint256 net, uint256 tax) = _find(vm.getRecordedLogs(), INH, T);
        assertEq(who, H1);
        assertEq(net, eth.balanceOf(H1) - h1Before, "net == received");
        assertEq(tax, eth.accumulatedTax() - taxBefore, "tax == accrued");
        assertEq(net + tax, bal / 2, "gross == share");

        vm.prank(U);
        eth.transfer(T, 1 ether + 7);
        (,,,,,,,,, uint256 startTs,,,) = eth.getUserInfo(T);
        vm.warp(startTs + eth.inheritWaitingTime() + eth.inheritRemainingWaitingTime());
        uint256 remBal = eth.balanceOf(T);
        h1Before = eth.balanceOf(H1);
        taxBefore = eth.accumulatedTax();
        vm.recordLogs();
        vm.prank(H1);
        eth.executeInheritanceRemaining(T);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (who, net, tax) = _find(logs, REM, T);
        assertEq(who, H1);
        assertGt(tax, 0);
        assertEq(net, eth.balanceOf(H1) - h1Before, "N-2: remaining reports the net");
        assertEq(tax, eth.accumulatedTax() - taxBefore, "N-2: remaining reports the tax");
        assertEq(net + tax, remBal, "gross == whole balance (sole claimer)");
        for (uint256 i; i < logs.length; i++) assertTrue(logs[i].topics[0] != REM_OLD, "old signature gone");
    }

    // executeRecovery reports (net, tax) in the same format.
    function test_recoveryEvent_reportsNetAndTax() public {
        address[] memory r = new address[](1);
        r[0] = RU;
        vm.prank(T);
        eth.setRecoveryUsers(r);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryInactivityPeriod());
        vm.prank(RU);
        eth.startRecovery(T);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryWaitingTime());
        uint256 bal = eth.balanceOf(T);
        uint256 taxBefore = eth.accumulatedTax();
        vm.recordLogs();
        vm.prank(RU);
        eth.executeRecovery(T);
        (address who, uint256 net, uint256 tax) = _find(vm.getRecordedLogs(), REC, T);
        assertEq(who, RU);
        assertEq(net, eth.balanceOf(RU), "net == received");
        assertEq(tax, eth.accumulatedTax() - taxBefore, "tax == accrued");
        assertEq(net + tax, bal, "gross == whole balance");
    }
}
