// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// AUD2-06: transfer and transferFrom move the tokens before updating the
// totalSent / totalReceived counters, so an insufficient balance reverts with
// the standard ERC-20 error instead of an arithmetic panic.
// AUD2-07: the NFT rescues require a contract address.
// AUD2-09: the owner can never be a delegate: an active delegate cannot be
// proposed as owner nor accept ownership, and an invitation issued before
// becoming owner can no longer be accepted (ownership epoch, AUD2-05).
contract AUD2MinorTest is Test {
    InheritfiV1ETH eth;
    address U = makeAddr("user");
    address S = makeAddr("spender");
    address R = makeAddr("receiver");
    address B = makeAddr("futureOwner");
    address D = makeAddr("delegate");
    address EOA = makeAddr("noCode");

    function setUp() public {
        eth = new InheritfiV1ETH();
        vm.deal(U, 1 ether);
        vm.prank(U);
        eth.wrap{value: 1 ether}();
    }

    // ─── AUD2-06 ──────────────────────────────────────────────────────────────

    function test_transferInsufficientBalance_standardError() public {
        vm.prank(U);
        eth.transfer(R, 1);
        uint256 bal = eth.balanceOf(U);
        vm.prank(U);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, U, bal, type(uint256).max)
        );
        eth.transfer(R, type(uint256).max);
    }

    function test_transferFromInsufficientBalance_standardError() public {
        vm.startPrank(U);
        eth.transfer(R, 1);
        eth.approve(S, type(uint256).max);
        vm.stopPrank();
        uint256 bal = eth.balanceOf(U);
        vm.prank(S);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, U, bal, type(uint256).max)
        );
        eth.transferFrom(U, R, type(uint256).max);
    }

    // ─── AUD2-07 ──────────────────────────────────────────────────────────────

    function test_recoverERC721_requiresContract() public {
        vm.expectRevert(bytes("Bad addr"));
        eth.emergencyRecoverERC721(EOA, R, 1);
    }

    function test_recoverERC1155_requiresContract() public {
        vm.expectRevert(bytes("Bad input"));
        eth.emergencyRecoverERC1155(EOA, R, 1, 1);
    }

    // ─── AUD2-09 ──────────────────────────────────────────────────────────────

    function test_cannotProposeActiveDelegateAsOwner() public {
        eth.addDelegate(D, 50);
        vm.prank(D);
        eth.acceptDelegate();
        vm.expectRevert(bytes("Is delegate"));
        eth.transferOwnership(D);
    }

    // B is proposed, becomes a delegate meanwhile, and cannot accept ownership.
    function test_delegateCannotAcceptOwnership() public {
        eth.transferOwnership(B);
        eth.addDelegate(B, 50);
        vm.prank(B);
        eth.acceptDelegate();
        vm.prank(B);
        vm.expectRevert(bytes("Is delegate"));
        eth.acceptOwnership();
        assertEq(eth.owner(), address(this), "ownership unchanged");
    }

    // Regression: B holds an invitation, becomes owner, and cannot accept it.
    function test_ownerCannotAcceptEarlierInvitation() public {
        eth.addDelegate(B, 50);
        eth.transferOwnership(B);
        vm.prank(B);
        eth.acceptOwnership();
        assertEq(eth.owner(), B, "B is the owner");
        vm.prank(B);
        vm.expectRevert(bytes("Invite expired"));
        eth.acceptDelegate();
    }
}
