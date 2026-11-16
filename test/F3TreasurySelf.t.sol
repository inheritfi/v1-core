// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// F3: setTreasuries rejects the wrapper itself as a treasury.
contract F3TreasurySelfTest is Test {
    InheritfiV1ETH eth;
    address TR1 = makeAddr("treasury1");

    function setUp() public {
        eth = new InheritfiV1ETH();
    }

    function _one(address w) internal pure returns (address[] memory a, uint256[] memory p) {
        a = new address[](1);
        p = new uint256[](1);
        a[0] = w;
        p[0] = 10_000;
    }

    function test_rejectsSelfAsOnlyTreasury() public {
        (address[] memory a, uint256[] memory p) = _one(address(eth));
        vm.expectRevert(bytes("Bad addr"));
        eth.setTreasuries(a, p);
    }

    function test_rejectsSelfAmongOthers() public {
        address[] memory a = new address[](2);
        uint256[] memory p = new uint256[](2);
        a[0] = TR1; a[1] = address(eth);
        p[0] = 5000; p[1] = 5000;
        vm.expectRevert(bytes("Bad addr"));
        eth.setTreasuries(a, p);
    }

    function test_zeroAddressStillRejected() public {
        (address[] memory a, uint256[] memory p) = _one(address(0));
        vm.expectRevert(bytes("Bad addr"));
        eth.setTreasuries(a, p);
    }

    function test_validTreasuryAccepted() public {
        (address[] memory a, uint256[] memory p) = _one(TR1);
        eth.setTreasuries(a, p);
        (address[] memory w,) = eth.getTreasuries();
        assertEq(w.length, 1);
        assertEq(w[0], TR1);
    }
}
