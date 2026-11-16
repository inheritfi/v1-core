// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// AUD2-04: the security wait of a treasury wallet change applies between the
// proposal and the acceptance of that treasury only (taxCollectionWaitingTime),
// so the owner can react before a new wallet receives any tax. Accepting a
// change no longer resets the global collection clock, so one treasury can no
// longer postpone collectTax for every treasury.
contract AUD204TreasuryWalletChangeTest is Test {
    InheritfiV1ETH eth;
    address TR1 = makeAddr("treasury1");
    address TR2 = makeAddr("treasury2");
    address NW = makeAddr("newWalletOfTreasury1");
    address U = makeAddr("user");
    uint256 t0;

    function setUp() public {
        eth = new InheritfiV1ETH();
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = TR1; p[0] = 5_000;
        w[1] = TR2; p[1] = 5_000;
        eth.setTreasuries(w, p);
        t0 = vm.getBlockTimestamp();
        vm.deal(U, 100 ether);
        vm.prank(U);
        eth.wrap{value: 100 ether}();
        assertGt(eth.accumulatedTax(), 0, "tax accrued");
    }

    function _wait() internal view returns (uint256) {
        return eth.taxCollectionWaitingTime();
    }

    function _propose() internal {
        vm.prank(TR1);
        eth.proposeTreasuryWalletChange(NW);
    }

    // Before AUD2-04 the acceptance reset the global clock and TR2 got "Too soon".
    function test_walletChangeDoesNotDelayOtherTreasuries() public {
        vm.warp(t0 + _wait());
        _propose();
        vm.warp(vm.getBlockTimestamp() + _wait());
        vm.prank(NW);
        eth.acceptTreasuryWalletChange();
        uint256 before = eth.balanceOf(TR2);
        vm.prank(TR2);
        eth.collectTax();
        assertGt(eth.balanceOf(TR2), before, "TR2 collected right after the change");
        assertEq(eth.accumulatedTax(), 0, "all tax distributed");
    }

    // Before AUD2-04 the acceptance was immediate.
    function test_acceptBeforeWaitingReverts() public {
        _propose();
        vm.prank(NW);
        vm.expectRevert(bytes("Too soon"));
        eth.acceptTreasuryWalletChange();
        vm.warp(vm.getBlockTimestamp() + _wait() - 1);
        vm.prank(NW);
        vm.expectRevert(bytes("Too soon"));
        eth.acceptTreasuryWalletChange();
    }

    function test_acceptAfterWaitingMovesTheEntry() public {
        _propose();
        vm.warp(vm.getBlockTimestamp() + _wait());
        vm.prank(NW);
        eth.acceptTreasuryWalletChange();
        (address[] memory w,) = eth.getTreasuries();
        assertEq(w[0], NW, "new wallet in the entry");
        assertEq(w[1], TR2, "other entry unchanged");
        vm.prank(TR1);
        vm.expectRevert(bytes("Not authorized"));
        eth.collectTax();
        vm.prank(NW);
        eth.collectTax();
    }

    // While the change is pending the official (old) wallet keeps receiving.
    function test_pendingChangeStillPaysOldWallet() public {
        vm.warp(t0 + _wait());
        _propose();
        uint256 beforeOld = eth.balanceOf(TR1);
        vm.prank(TR2);
        eth.collectTax();
        assertGt(eth.balanceOf(TR1), beforeOld, "old wallet paid");
        assertEq(eth.balanceOf(NW), 0, "pending wallet not paid");
    }

    // The owner can react during the wait by replacing the list.
    function test_ownerReactsDuringWaiting() public {
        _propose();
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = TR1; p[0] = 5_000;
        w[1] = TR2; p[1] = 5_000;
        eth.setTreasuries(w, p);
        vm.warp(vm.getBlockTimestamp() + _wait());
        vm.prank(NW);
        vm.expectRevert(bytes("No pending change"));
        eth.acceptTreasuryWalletChange();
    }

    // Before AUD2-04 the acceptance after a new proposal was immediate.
    function test_cancelAndReproposeRestartsWaiting() public {
        _propose();
        vm.warp(vm.getBlockTimestamp() + _wait() - 1);
        vm.prank(TR1);
        eth.cancelTreasuryWalletChange();
        _propose();
        uint256 reproposedAt = vm.getBlockTimestamp();
        vm.warp(reproposedAt + 1);
        vm.prank(NW);
        vm.expectRevert(bytes("Too soon"));
        eth.acceptTreasuryWalletChange();
        vm.warp(reproposedAt + _wait());
        vm.prank(NW);
        eth.acceptTreasuryWalletChange();
        (address[] memory w,) = eth.getTreasuries();
        assertEq(w[0], NW, "accepted after the restarted wait");
    }
}
