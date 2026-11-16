// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// A-01: the setters guarantee recoveryInactivityPeriod < inheritInactivityPeriod.
contract A01PeriodPriorityTest is Test {
    InheritfiV1ETH eth;

    function setUp() public {
        eth = new InheritfiV1ETH();
    }

    // The default values (30 < 45 days) already respect the priority.
    function test_defaultsRespectPriority() public view {
        assertLt(eth.recoveryInactivityPeriod(), eth.inheritInactivityPeriod(), "30 < 45");
    }

    // Recovery equal to or above inheritance reverts; below is accepted.
    function test_recoveryMustBeBelowInherit() public {
        uint256 inh = eth.inheritInactivityPeriod();
        vm.expectRevert(bytes("Must be < inherit"));
        eth.setRecoveryInactivityPeriod(inh);
        vm.expectRevert(bytes("Must be < inherit"));
        eth.setRecoveryInactivityPeriod(inh + 1 days);
        eth.setRecoveryInactivityPeriod(inh - 1);
        assertEq(eth.recoveryInactivityPeriod(), inh - 1, "accepts inherit - 1");
    }

    // Inheritance equal to or below recovery reverts; above is accepted.
    function test_inheritMustBeAboveRecovery() public {
        uint256 rec = eth.recoveryInactivityPeriod();
        vm.expectRevert(bytes("Must be > recovery"));
        eth.setInheritInactivityPeriod(rec);
        vm.expectRevert(bytes("Must be > recovery"));
        eth.setInheritInactivityPeriod(rec - 1 days);
        eth.setInheritInactivityPeriod(rec + 1);
        assertEq(eth.inheritInactivityPeriod(), rec + 1, "accepts recovery + 1");
    }

    // The range check is still applied first.
    function test_rangeCheckStillFirst() public {
        vm.expectRevert(bytes("Bad period"));
        eth.setRecoveryInactivityPeriod(1 days);
        vm.expectRevert(bytes("Bad period"));
        eth.setInheritInactivityPeriod(181 days);
    }

    // To raise both, inheritance first and recovery afterwards.
    function test_orderMatters_raiseBoth() public {
        vm.expectRevert(bytes("Must be < inherit"));
        eth.setRecoveryInactivityPeriod(50 days);
        eth.setInheritInactivityPeriod(55 days);
        eth.setRecoveryInactivityPeriod(50 days);
        assertEq(eth.recoveryInactivityPeriod(), 50 days, "recovery 50");
        assertEq(eth.inheritInactivityPeriod(), 55 days, "inheritance 55");
    }

    // Any sequence of calls always leaves recovery < inheritance.
    function testFuzz_priorityAlwaysHolds(uint256[6] memory vals, uint8 order) public {
        uint256 applied;
        for (uint256 i; i < 6; i++) {
            uint256 v = bound(vals[i], 0, 100 days);
            bool isRec = ((order >> (i % 8)) & 1) == 1;
            (bool ok,) = isRec
                ? address(eth).call(abi.encodeCall(eth.setRecoveryInactivityPeriod, (v)))
                : address(eth).call(abi.encodeCall(eth.setInheritInactivityPeriod, (v)));
            if (ok) applied++;
            assertLt(eth.recoveryInactivityPeriod(), eth.inheritInactivityPeriod(), "priority");
        }
        assertLe(applied, 6);
    }
}
