// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Minimal ERC-20 with configurable decimals, used as the underlying of every wrapper.
contract I01DecimalsMock is ERC20 {
    uint8 private immutable dec;
    constructor(uint8 d) ERC20("Mock", "MCK") { dec = d; }
    function decimals() public view override returns (uint8) { return dec; }
}

// I-01: decimals(), name() and symbol() of the 29 wrappers. Wrappers do not read the
// underlying's decimals, so each must return the value of its real token: 8 for WBTC
// and 18 for ETH and the other 27. The wrappers are deployed with vm.deployCode, so
// this test does not embed their bytecode. Each ticker is the underlying's on-chain
// symbol() byte for byte, and each ERC-20 wrapper must expose its underlying through
// a getter named exactly like the ticker.
contract I01WrapperDecimalsTest is Test {
    function test_decimalsNameSymbol_allWrappers() public {
        I01DecimalsMock m18 = new I01DecimalsMock(18);
        I01DecimalsMock m8 = new I01DecimalsMock(8);
        string[28] memory t = [
            string("AAVE"), "AXS", "COMP", "CRV", "crvUSD", "CVX", "DAI", "ENS", "ETHFI",
            "FET", "GHO", "GRT", "IMX", "INJ", "JASMY", "LDO", "LINK", "PENDLE", "PEPE",
            "POL", "SHIB", "SKY", "STRK", "UNI", "WBTC", "WETH", "WLD", "wstETH"
        ];
        for (uint256 i; i < t.length; i++) {
            bool isBtc = keccak256(bytes(t[i])) == keccak256("WBTC");
            address und = isBtc ? address(m8) : address(m18);
            string memory c = string.concat("InheritfiV1", t[i]);
            address w = vm.deployCode(string.concat(c, ".sol:", c), abi.encode(und));
            assertEq(ERC20(w).decimals(), isBtc ? 8 : 18, t[i]);
            assertEq(ERC20(w).decimals(), ERC20(und).decimals(), t[i]);
            assertEq(ERC20(w).symbol(), string.concat("i", t[i]), t[i]);
            assertEq(ERC20(w).name(), string.concat("INHERITFI V1 ", t[i]), t[i]);
            (bool ok, bytes memory ret) = w.staticcall(abi.encodeWithSignature(string.concat(t[i], "()")));
            assertTrue(ok, t[i]);
            assertEq(abi.decode(ret, (address)), und, t[i]);
        }
        address e = vm.deployCode("InheritfiV1ETH.sol:InheritfiV1ETH");
        assertEq(ERC20(e).decimals(), 18, "ETH");
        assertEq(ERC20(e).symbol(), "iETH", "ETH");
        assertEq(ERC20(e).name(), "INHERITFI V1 ETH", "ETH");
    }
}
