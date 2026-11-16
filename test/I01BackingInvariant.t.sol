// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";
import "../src/InheritfiV1UNI.sol";

// Minimal ERC-20 used as the UNI underlying.
contract I01MockToken is ERC20 {
    constructor() ERC20("Mock UNI", "mUNI") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// I-01: backing invariant. Under random wraps, unwraps (users and treasury), transfers,
// tax collection, donations of the underlying (or forced ETH) and every rescue path,
// each wrapper must always hold exactly as much underlying as iTokens exist, and at
// least accumulatedTax of its own iTokens.
contract I01BackingInvariantTest is Test {
    InheritfiV1ETH eth;
    InheritfiV1UNI uni;
    I01MockToken mUni;
    address[3] users;
    address TR = makeAddr("treasury");
    address SINK = makeAddr("rescueSink");

    function setUp() public {
        eth = new InheritfiV1ETH();
        mUni = new I01MockToken();
        uni = new InheritfiV1UNI(address(mUni));
        address[] memory w = new address[](1);
        uint256[] memory p = new uint256[](1);
        w[0] = TR; p[0] = 10_000;
        eth.setTreasuries(w, p);
        uni.setTreasuries(w, p);
        for (uint256 i; i < 3; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            vm.deal(users[i], 1_000 ether);
            mUni.mint(users[i], 1_000 ether);
            vm.prank(users[i]);
            mUni.approve(address(uni), type(uint256).max);
        }
        vm.warp(vm.getBlockTimestamp() + eth.taxCollectionWaitingTime());
    }

    function _checkBacking() internal view {
        assertEq(address(eth).balance, eth.totalSupply(), "ETH backing == iETH supply");
        assertEq(eth.getRecoverableETH(), 0);
        assertGe(eth.balanceOf(address(eth)), eth.accumulatedTax(), "iETH held >= tax");
        assertEq(mUni.balanceOf(address(uni)), uni.totalSupply(), "UNI backing == iUNI supply");
        assertEq(uni.getRecoverableUNI(), 0);
        assertGe(uni.balanceOf(address(uni)), uni.accumulatedTax(), "iUNI held >= tax");
    }

    function _wrapEth(address u, uint256 x) internal {
        uint256 amt = 1 + x % 5 ether;
        vm.prank(u);
        eth.wrap{value: amt}();
    }

    function _unwrapEth(address u, uint256 x) internal {
        uint256 bal = eth.balanceOf(u);
        if (bal == 0) return;
        vm.prank(u);
        eth.unwrap(1 + x % bal);
    }

    function _wrapUni(address u, uint256 x) internal {
        uint256 amt = 1 + x % 5 ether;
        vm.prank(u);
        uni.wrap(amt);
    }

    function _unwrapUni(address u, uint256 x) internal {
        uint256 bal = uni.balanceOf(u);
        if (bal == 0) return;
        vm.prank(u);
        uni.unwrap(1 + x % bal);
    }

    function _move(IERC20 t, address from, address to, uint256 x) internal {
        uint256 bal = t.balanceOf(from);
        if (bal == 0 || from == to) return;
        vm.prank(from);
        t.transfer(to, 1 + x % bal);
    }

    function _collect() internal {
        if (eth.accumulatedTax() > 0) {
            vm.prank(TR);
            eth.collectTax();
        }
        if (uni.accumulatedTax() > 0) {
            vm.prank(TR);
            uni.collectTax();
        }
    }

    // Forced ETH and a direct UNI donation are rescued in full; the iToken backing is untouched.
    function _donateAndRescue(uint256 x) internal {
        uint256 d = 1 + x % 3 ether;
        vm.deal(address(eth), address(eth).balance + d);
        assertEq(eth.getRecoverableETH(), d, "only the forced ETH is recoverable");
        eth.emergencyRecoverETH(payable(SINK), d);
        mUni.mint(address(uni), d);
        assertEq(uni.getRecoverableUNI(), d, "only the donated UNI is recoverable");
        uni.emergencyRecoverUNI(SINK, d);
    }

    // iTokens sent to the wrapper by mistake are recoverable, but never the accumulated tax.
    function _iTokenExcessRescue(address u, uint256 x) internal {
        uint256 bal = eth.balanceOf(u);
        if (bal == 0) return;
        uint256 amt = 1 + x % bal;
        vm.prank(u);
        eth.transfer(address(eth), amt);
        assertEq(eth.getRecoverableITokens(), amt, "only the mistaken iETH is recoverable");
        eth.emergencyRecoverERC20(address(eth), SINK, amt);
    }

    function testFuzz_backingInvariant(uint256 seed) public {
        _checkBacking();
        for (uint256 k; k < 30; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 op = r % 9;
            uint256 wi = (r >> 8) % 4;
            address who = wi == 3 ? TR : users[wi];
            address to = users[(r >> 16) % 3];
            uint256 x = r >> 24;
            if (op == 0) _wrapEth(users[wi % 3], x);
            else if (op == 1) _unwrapEth(who, x);
            else if (op == 2) _move(IERC20(address(eth)), who, to, x);
            else if (op == 3) _wrapUni(users[wi % 3], x);
            else if (op == 4) _unwrapUni(who, x);
            else if (op == 5) _move(IERC20(address(uni)), who, to, x);
            else if (op == 6) _collect();
            else if (op == 7) _donateAndRescue(x);
            else _iTokenExcessRescue(who, x);
            _checkBacking();
        }
    }
}
