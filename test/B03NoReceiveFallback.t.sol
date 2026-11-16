// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";
import "../src/InheritfiV1UNI.sol";

// Minimal ERC-20 used as the UNI underlying.
contract B03MockUnderlying is ERC20 {
    constructor() ERC20("Mock UNI", "mUNI") {}
}

// B-03: wrappers have no receive() and no fallback(): direct ETH transfers and calls
// to non-existent functions revert; wrap() still accepts ETH, and forced ETH stays
// recoverable through emergencyRecoverETH.
contract B03NoReceiveFallbackTest is Test {
    InheritfiV1ETH eth;
    InheritfiV1UNI uni;
    address U = makeAddr("user");
    address TO = makeAddr("rescueTarget");

    function setUp() public {
        eth = new InheritfiV1ETH();
        uni = new InheritfiV1UNI(address(new B03MockUnderlying()));
        vm.deal(U, 10 ether);
    }

    // Direct ETH transfers revert on both kinds of wrapper; the ETH never leaves the sender.
    function test_directETH_reverts_andStaysWithSender() public {
        uint256 before = U.balance;
        vm.prank(U);
        (bool okEth,) = address(eth).call{value: 1 ether}("");
        assertFalse(okEth, "ETH wrapper rejects direct ETH");
        vm.prank(U);
        (bool okUni,) = address(uni).call{value: 1 ether}("");
        assertFalse(okUni, "ERC-20 wrapper rejects direct ETH");
        assertEq(U.balance, before, "ETH never left the sender");
        assertEq(address(eth).balance, 0);
        assertEq(address(uni).balance, 0);
    }

    // Calls to functions that do not exist revert, with or without value.
    function test_unknownFunction_reverts() public {
        (bool ok1,) = address(eth).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok1, "pause() no longer exists");
        vm.prank(U);
        (bool ok2,) = address(uni).call{value: 1 ether}(abi.encodeWithSignature("tokenTax()"));
        assertFalse(ok2, "unknown selector with value");
        assertEq(U.balance, 10 ether, "value returned to sender");
    }

    // wrap() is still the way to deposit ETH.
    function test_wrapStillAcceptsETH() public {
        vm.prank(U);
        eth.wrap{value: 1 ether}();
        assertEq(address(eth).balance, 1 ether);
        assertGt(eth.balanceOf(U), 0);
    }

    // Forced ETH (e.g. selfdestruct) cannot be rejected and remains recoverable.
    function test_forcedETH_stillRecoverable() public {
        vm.prank(U);
        eth.wrap{value: 1 ether}();
        vm.deal(address(eth), address(eth).balance + 2 ether);
        assertEq(eth.getRecoverableETH(), 2 ether, "only the forced ETH is recoverable");
        eth.emergencyRecoverETH(payable(TO), 2 ether);
        assertEq(TO.balance, 2 ether);
        assertEq(address(eth).balance, 1 ether, "iETH backing untouched");

        vm.deal(address(uni), 3 ether);
        uni.emergencyRecoverETH(payable(TO), 3 ether);
        assertEq(TO.balance, 5 ether);
    }
}
