// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";
import "../src/InheritfiV1UNI.sol";

// USDT-like token: transfer does not return a bool.
contract NoBoolToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "NoBool: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

// Standard ERC-20 underlying for the UNI wrapper.
contract MockUnderlying is ERC20 {
    constructor() ERC20("Mock UNI", "mUNI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// A-08 + M-13: emergencyRecoverERC20 uses safeTransfer and, for the wrapper's own iToken,
// only allows rescuing the excess over accumulatedTax.
contract A08M13RecoverTest is Test {
    event EmergencyRecovery(address indexed token, address indexed to, uint256 amount, string tokenType);

    InheritfiV1ETH eth;
    InheritfiV1UNI uni;
    MockUnderlying und;
    address U = makeAddr("user");
    address T = makeAddr("testator");
    address H = makeAddr("heir");
    address R = makeAddr("recoveryUser");
    address TR1 = makeAddr("treasury1");
    address TR2 = makeAddr("treasury2");
    uint256 sent;    // iETH sent directly to the contract
    uint256 rescued; // iETH rescued from the excess

    function setUp() public {
        eth = new InheritfiV1ETH();
        und = new MockUnderlying();
        uni = new InheritfiV1UNI(address(und));
        address[] memory w = new address[](2);
        uint256[] memory p = new uint256[](2);
        w[0] = TR1; w[1] = TR2;
        p[0] = 6000; p[1] = 4000;
        eth.setTreasuries(w, p);
        vm.deal(U, 100 ether);
        vm.prank(U);
        eth.wrap{value: 100 ether}();
    }

    // balanceOf(contract) = accumulatedTax + sent - rescued
    function _checkInv() internal view {
        assertEq(eth.balanceOf(address(eth)), eth.accumulatedTax() + sent - rescued, "invariant");
        assertEq(eth.getRecoverableITokens(), sent - rescued, "recoverable = sent - rescued");
    }

    function _collect() internal {
        vm.warp(vm.getBlockTimestamp() + eth.taxCollectionWaitingTime());
        eth.collectTax();
    }

    // iETH: without excess not a single wei of the taxes is touched; the excess is rescued with
    // the iETH-EXCESS label; afterwards collectTax distributes exactly the taxes.
    function test_eth_recoverExcess_taxesProtected() public {
        uint256 tax0 = eth.accumulatedTax();
        assertGt(tax0, 0, "wrap taxes exist");
        _checkInv();
        vm.expectRevert(bytes("Exceeds recoverable"));
        eth.emergencyRecoverERC20(address(eth), U, 1);

        vm.prank(U);
        eth.transfer(address(eth), 5 ether);
        sent += 5 ether;
        _checkInv();
        vm.expectRevert(bytes("Exceeds recoverable"));
        eth.emergencyRecoverERC20(address(eth), U, 5 ether + 1);

        uint256 before = eth.balanceOf(U);
        vm.expectEmit(true, true, false, true, address(eth));
        emit EmergencyRecovery(address(eth), U, 5 ether, "iETH-EXCESS");
        eth.emergencyRecoverERC20(address(eth), U, 5 ether);
        rescued += 5 ether;
        assertEq(eth.balanceOf(U) - before, 5 ether, "U gets its 5 iETH back");
        assertEq(eth.accumulatedTax(), tax0, "taxes untouched");
        _checkInv();

        _collect();
        assertEq(eth.balanceOf(TR1) + eth.balanceOf(TR2), tax0, "treasuries receive all the taxes");
        assertEq(eth.accumulatedTax(), 0, "taxes distributed");
        _checkInv();
    }

    // iUNI: the underlying stays excluded; the iUNI excess is rescued with iUNI-EXCESS.
    function test_uni_recoverExcess_underlyingExcluded() public {
        und.mint(U, 100 ether);
        vm.startPrank(U);
        und.approve(address(uni), 100 ether);
        uni.wrap(100 ether);
        uni.transfer(address(uni), 2 ether);
        vm.stopPrank();
        uint256 tax0 = uni.accumulatedTax();
        assertEq(uni.getRecoverableITokens(), 2 ether, "iUNI excess");

        vm.expectRevert(bytes("Use emergencyRecoverUNI"));
        uni.emergencyRecoverERC20(address(und), U, 1);

        vm.expectEmit(true, true, false, true, address(uni));
        emit EmergencyRecovery(address(uni), U, 2 ether, "iUNI-EXCESS");
        uni.emergencyRecoverERC20(address(uni), U, 2 ether);
        assertEq(uni.accumulatedTax(), tax0, "taxes untouched");
        assertEq(uni.balanceOf(address(uni)), tax0, "only the taxes remain");
    }

    // A-08: a token without a bool return (USDT-like) is rescued with safeTransfer in ETH and UNI.
    function test_noBoolToken_recovered() public {
        NoBoolToken nb = new NoBoolToken();
        nb.mint(address(eth), 7);
        nb.mint(address(uni), 9);
        vm.expectEmit(true, true, false, true, address(eth));
        emit EmergencyRecovery(address(nb), U, 7, "ERC20");
        eth.emergencyRecoverERC20(address(nb), U, 7);
        uni.emergencyRecoverERC20(address(nb), U, 9);
        assertEq(nb.balanceOf(U), 16, "U receives 7 + 9");
        assertEq(nb.balanceOf(address(eth)), 0);
        assertEq(nb.balanceOf(address(uni)), 0);
    }

    // Invariant across inheritance, remaining, recovery, rescue and collectTax (deterministic).
    function test_invariant_inheritance_remaining_recovery() public {
        vm.deal(T, 50 ether);
        vm.prank(T);
        eth.wrap{value: 50 ether}();
        address[] memory w = new address[](1);
        uint256[] memory p = new uint256[](1);
        w[0] = H; p[0] = 10_000;
        vm.prank(T);
        eth.setHeirs(w, p);
        vm.prank(U);
        eth.transfer(address(eth), 1 ether);
        sent += 1 ether;
        _checkInv();

        vm.warp(vm.getBlockTimestamp() + eth.inheritInactivityPeriod());
        vm.prank(H);
        eth.startInheritance(T);
        vm.warp(vm.getBlockTimestamp() + eth.inheritWaitingTime());
        vm.prank(H);
        eth.executeInheritance(T); // inheritance tax
        _checkInv();

        vm.prank(U);
        eth.transfer(T, 10 ether);
        (,,,,,,,,, uint256 startTs,,,) = eth.getUserInfo(T);
        vm.warp(startTs + eth.inheritWaitingTime() + eth.inheritRemainingWaitingTime());
        vm.prank(H);
        eth.executeInheritanceRemaining(T); // remaining tax
        _checkInv();

        eth.emergencyRecoverERC20(address(eth), U, 1 ether);
        rescued += 1 ether;
        _checkInv();

        address[] memory r = new address[](1);
        r[0] = R;
        vm.prank(U);
        eth.setRecoveryUsers(r);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryInactivityPeriod());
        vm.prank(R);
        eth.startRecovery(U);
        vm.warp(vm.getBlockTimestamp() + eth.recoveryWaitingTime());
        vm.prank(R);
        eth.executeRecovery(U); // recovery tax
        _checkInv();

        _collect();
        assertEq(eth.accumulatedTax(), 0, "taxes distributed");
        _checkInv();
    }

    // Invariant under random sequences of wrap, unwrap, direct send, rescue and collectTax.
    function testFuzz_invariant_randomOps(uint256 seed) public {
        vm.deal(U, 1000 ether);
        vm.deal(T, 1000 ether);
        for (uint256 step; step < 20; step++) {
            _randomOp(uint256(keccak256(abi.encode(seed, step))));
            _checkInv();
        }
        if (eth.accumulatedTax() > 0) _collect();
        assertEq(eth.accumulatedTax(), 0, "taxes distributed");
        _checkInv();
    }

    function _randomOp(uint256 r) internal {
        address u = (r & 1) == 0 ? U : T;
        uint256 op = (r >> 8) % 5;
        uint256 x = r >> 16;
        if (op == 0) {
            uint256 amt = bound(x, 1e15, 10 ether);
            vm.prank(u);
            eth.wrap{value: amt}();
        } else if (op == 1) {
            uint256 bal = eth.balanceOf(u);
            if (bal < 1e15) return;
            uint256 amt = bound(x, 1e15, bal);
            vm.prank(u);
            eth.unwrap(amt);
        } else if (op == 2) {
            uint256 bal = eth.balanceOf(u);
            if (bal == 0) return;
            uint256 amt = bound(x, 1, bal);
            vm.prank(u);
            eth.transfer(address(eth), amt);
            sent += amt;
        } else if (op == 3) {
            uint256 rec = eth.getRecoverableITokens();
            if (rec == 0) return;
            uint256 amt = bound(x, 1, rec);
            eth.emergencyRecoverERC20(address(eth), u, amt);
            rescued += amt;
        } else if (eth.accumulatedTax() > 0) {
            _collect();
        }
    }
}
