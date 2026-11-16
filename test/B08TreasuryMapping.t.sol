// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// B-08: treasury membership is an O(1) mapping maintained by the library. Also
// checks B-06 (treasuries unwrap without tax, by design) and that a treasury wallet
// can never be changed to one that is already a treasury.
contract B08TreasuryMappingTest is Test {
    InheritfiV1ETH eth;
    address U = makeAddr("user");
    address TR1 = makeAddr("treasury1");
    address TR2 = makeAddr("treasury2");
    address TR3 = makeAddr("treasury3");
    address TR4 = makeAddr("treasury4");

    function setUp() public {
        eth = new InheritfiV1ETH();
        vm.deal(U, 100 ether);
        vm.prank(U);
        eth.wrap{value: 100 ether}();
        _set2(TR1, TR2);
        vm.startPrank(U);
        eth.transfer(TR1, 10 ether);
        eth.transfer(TR2, 10 ether);
        eth.transfer(TR3, 10 ether);
        eth.transfer(TR4, 10 ether);
        vm.stopPrank();
    }

    function _set2(address a, address b) internal {
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = a; w[1] = b;
        p[0] = 5000; p[1] = 5000;
        eth.setTreasuries(w, p);
    }

    function _set1(address a) internal {
        address[] memory w = new address[](1);
        uint256[] memory p = new uint256[](1);
        w[0] = a; p[0] = 10_000;
        eth.setTreasuries(w, p);
    }

    // Returns the ETH received by `who` when unwrapping 1 iETH.
    function _unwrapOne(address who) internal returns (uint256 received) {
        uint256 before = who.balance;
        vm.prank(who);
        eth.unwrap(1 ether);
        received = who.balance - before;
    }

    function _fee() internal view returns (uint256) {
        return (1 ether * eth.unwrappingTax()) / 10_000;
    }

    // B-06 (design): a treasury unwraps without tax; anyone else pays it.
    function test_treasuryUnwrapsWithoutTax_userPaysTax() public {
        uint256 tax0 = eth.accumulatedTax();
        assertEq(_unwrapOne(TR1), 1 ether, "treasury: no unwrapping tax");
        assertEq(eth.accumulatedTax(), tax0, "no tax accrued for treasury");
        assertGt(_fee(), 0);
        assertEq(_unwrapOne(TR3), 1 ether - _fee(), "non-treasury pays the tax");
    }

    // Replacing the list clears the flags of the previous treasuries.
    function test_replacingTreasuries_clearsOldFlags() public {
        _set1(TR3);
        assertEq(_unwrapOne(TR1), 1 ether - _fee(), "TR1 lost its flag");
        assertEq(_unwrapOne(TR2), 1 ether - _fee(), "TR2 lost its flag");
        assertEq(_unwrapOne(TR3), 1 ether, "TR3 is a treasury");
        vm.warp(vm.getBlockTimestamp() + eth.taxCollectionWaitingTime());
        vm.prank(TR1);
        vm.expectRevert(bytes("Not authorized"));
        eth.collectTax();
        vm.prank(TR3);
        eth.collectTax();
    }

    // Wallets of the previous list can be listed again.
    function test_relistingSameWallets_works() public {
        _set2(TR2, TR1);
        assertEq(_unwrapOne(TR1), 1 ether);
        assertEq(_unwrapOne(TR2), 1 ether);
    }

    // Duplicates are still rejected, now through the mapping.
    function test_duplicateInSetTreasuries_reverts() public {
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = TR3; w[1] = TR3;
        p[0] = 5000; p[1] = 5000;
        vm.expectRevert(bytes("Dup addr"));
        eth.setTreasuries(w, p);
        assertEq(_unwrapOne(TR1), 1 ether, "previous treasuries unchanged");
    }

    // A wallet change moves the flag from the old wallet to the new one.
    function test_walletChange_movesFlag() public {
        vm.prank(TR1);
        eth.proposeTreasuryWalletChange(TR4);
        // The new wallet can accept only after the security wait (AUD2-04).
        vm.warp(vm.getBlockTimestamp() + eth.taxCollectionWaitingTime());
        vm.prank(TR4);
        eth.acceptTreasuryWalletChange();
        assertEq(_unwrapOne(TR4), 1 ether, "new wallet is a treasury");
        assertEq(_unwrapOne(TR1), 1 ether - _fee(), "old wallet lost its flag");
        (address[] memory w,) = eth.getTreasuries();
        assertEq(w[0], TR4);
        assertEq(w[1], TR2);
    }

    // A treasury cannot propose a wallet that is already a treasury (itself included).
    function test_proposeExistingTreasury_reverts() public {
        vm.prank(TR1);
        vm.expectRevert(bytes("Already treasury"));
        eth.proposeTreasuryWalletChange(TR2);
        vm.prank(TR1);
        vm.expectRevert(bytes("Already treasury"));
        eth.proposeTreasuryWalletChange(TR1);
    }

    // Accepting fails if the caller already became a treasury through another entry.
    function test_acceptWhenAlreadyTreasury_reverts() public {
        vm.prank(TR1);
        eth.proposeTreasuryWalletChange(TR4);
        vm.prank(TR2);
        eth.proposeTreasuryWalletChange(TR4);
        // The new wallet can accept only after the security wait (AUD2-04).
        vm.warp(vm.getBlockTimestamp() + eth.taxCollectionWaitingTime());
        vm.prank(TR4);
        eth.acceptTreasuryWalletChange();
        vm.prank(TR4);
        vm.expectRevert(bytes("Already treasury"));
        eth.acceptTreasuryWalletChange();
        (address[] memory w,) = eth.getTreasuries();
        assertEq(w[0], TR4);
        assertEq(w[1], TR2, "no duplicate entry created");
    }
}
