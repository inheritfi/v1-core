// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "../src/InheritfiV1DAI.sol";
import "../src/InheritfiV1ETH.sol";

/**
 * @notice Emergency recovery functions against tokens sent directly to a wrapper.
 *         (1) The ERC-721 and ERC-1155 paths reject the wrapper's underlying asset and the wrapper itself,
 *             in all 29 contracts. (2) A malicious token can never move user funds, the backing, the
 *             accumulated tax, user configuration or ownership, whatever it does when the owner recovers it.
 */

contract GuardUnderlying is ERC20 {
    constructor() ERC20("Guard Underlying", "GU") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

/// Hypothetical underlying that also exposes both NFT-style safeTransferFrom selectors as ERC-20 transfers.
contract GuardSelectorUnderlying is ERC20 {
    constructor() ERC20("Guard Selector Underlying", "GSU") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
    function safeTransferFrom(address from, address to, uint256 amount) external {
        if (msg.sender != from) _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
    }
    function safeTransferFrom(address from, address to, uint256, uint256 amount, bytes calldata) external {
        if (msg.sender != from) _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
    }
}

/// Hypothetical underlying with a fallback that accepts any call (like WETH9).
contract GuardFallbackUnderlying is ERC20 {
    constructor() ERC20("Guard Fallback Underlying", "GFU") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
    fallback() external {}
}

contract GuardNft is ERC721 {
    constructor() ERC721("Guard NFT", "GN") {}
    function mint(address to, uint256 id) external { _safeMint(to, id); }
}

contract GuardMulti is ERC1155 {
    constructor() ERC1155("") {}
    function mint(address to, uint256 id, uint256 v) external { _mint(to, id, v, ""); }
    function mintBatch(address to, uint256[] memory ids, uint256[] memory vs) external { _mintBatch(to, ids, vs, ""); }
}

/// Malicious token: transfer (ERC-20) and both safeTransferFrom (ERC-721 / ERC-1155) run the chosen mode.
contract GuardEvil {
    enum Mode { NONE, REENTER, REVERT_BOMB, RETURN_BOMB, GAS_BURN, LIE, RETURN_FALSE }
    Mode public mode;
    address public target;
    address public underlying;
    address public victim;
    bool public isEth;
    uint256 public bombSize;
    uint256 public fakeBal;
    string[] public labels;
    bool[] public oks;

    function setup(address t, address u, address v, bool e) external { target = t; underlying = u; victim = v; isEth = e; }
    function setMode(Mode m, uint256 size) external { mode = m; bombSize = size; }
    function setFakeBal(uint256 b) external { fakeBal = b; }
    function count() external view returns (uint256) { return labels.length; }
    receive() external payable {}

    function prepare(uint256 wrapAmt) external {
        bool ok;
        if (isEth) {
            (ok,) = target.call{value: wrapAmt}(abi.encodeWithSignature("wrap()"));
        } else {
            IERC20(underlying).approve(target, type(uint256).max);
            (ok,) = target.call(abi.encodeWithSignature("wrap(uint256)", wrapAmt));
        }
        require(ok, "prepare");
    }

    function balanceOf(address) external view returns (uint256) { return fakeBal; }
    function transfer(address, uint256) external returns (bool) { return _hook(); }
    function safeTransferFrom(address, address, uint256) external { require(_hook(), "false"); }
    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external { require(_hook(), "false"); }

    function _try(string memory label, bytes memory data, uint256 value) internal {
        (bool ok,) = target.call{value: value}(data);
        labels.push(label);
        oks.push(ok);
    }

    function _hook() internal returns (bool) {
        Mode m = mode;
        if (m == Mode.REENTER) { _reenter(); return true; }
        if (m == Mode.LIE) return true;
        if (m == Mode.RETURN_FALSE) return false;
        uint256 n = bombSize;
        if (m == Mode.REVERT_BOMB) assembly { revert(0, n) }
        if (m == Mode.RETURN_BOMB) assembly { mstore(0, 1) return(0, n) }
        if (m == Mode.GAS_BURN) { uint256 x; while (true) { unchecked { x++; } } }
        return true;
    }

    function _reenter() internal {
        // Ordinary user actions: allowed, they are what any account can do in its own transaction.
        if (isEth) {
            _try("wrap", abi.encodeWithSignature("wrap()"), 1 ether);
            _try("emergencyRecoverETH", abi.encodeWithSignature("emergencyRecoverETH(address,uint256)", address(this), 1), 0);
        } else {
            _try("wrap", abi.encodeWithSignature("wrap(uint256)", 1 ether), 0);
            _try("emergencyRecoverDAI", abi.encodeWithSignature("emergencyRecoverDAI(address,uint256)", address(this), 1), 0);
            _try("emergencyRecoverETH", abi.encodeWithSignature("emergencyRecoverETH(address,uint256)", address(this), 1), 0);
        }
        _try("unwrap", abi.encodeWithSignature("unwrap(uint256)", 0.5 ether), 0);
        _try("transfer", abi.encodeWithSignature("transfer(address,uint256)", address(0xBEEF), 1), 0);
        _try("checkActivity", abi.encodeWithSignature("checkActivity()"), 0);
        address[] memory hs = new address[](1); hs[0] = address(0xBEEF);
        uint256[] memory ps = new uint256[](1); ps[0] = 10_000;
        _try("setHeirs", abi.encodeWithSignature("setHeirs(address[],uint256[])", hs, ps), 0);
        // Privileged or third-party actions: must all fail.
        _try("transferFrom(victim)", abi.encodeWithSignature("transferFrom(address,address,uint256)", victim, address(this), 1), 0);
        _try("executeInheritance", abi.encodeWithSignature("executeInheritance(address)", victim), 0);
        _try("executeInheritanceRemaining", abi.encodeWithSignature("executeInheritanceRemaining(address)", victim), 0);
        _try("startInheritance", abi.encodeWithSignature("startInheritance(address)", victim), 0);
        _try("startRecovery", abi.encodeWithSignature("startRecovery(address)", victim), 0);
        _try("executeRecovery", abi.encodeWithSignature("executeRecovery(address)", victim), 0);
        _try("collectTax", abi.encodeWithSignature("collectTax()"), 0);
        _try("emergencyRecoverERC20(underlying)", abi.encodeWithSignature("emergencyRecoverERC20(address,address,uint256)", underlying, address(this), 1), 0);
        _try("emergencyRecoverERC20(self)", abi.encodeWithSignature("emergencyRecoverERC20(address,address,uint256)", target, address(this), 1), 0);
        _try("emergencyRecoverERC20(evil)", abi.encodeWithSignature("emergencyRecoverERC20(address,address,uint256)", address(this), address(this), 1), 0);
        _try("emergencyRecoverERC721", abi.encodeWithSignature("emergencyRecoverERC721(address,address,uint256)", address(this), address(this), 1), 0);
        _try("emergencyRecoverERC1155", abi.encodeWithSignature("emergencyRecoverERC1155(address,address,uint256,uint256)", address(this), address(this), 1, 1), 0);
        _try("setWrappingTax", abi.encodeWithSignature("setWrappingTax(uint256)", 0), 0);
        _try("setTreasuries", abi.encodeWithSignature("setTreasuries(address[],uint256[])", new address[](0), new uint256[](0)), 0);
        _try("transferOwnership", abi.encodeWithSignature("transferOwnership(address)", address(this)), 0);
        _try("acceptOwnership", abi.encodeWithSignature("acceptOwnership()"), 0);
        _try("renounceOwnership", abi.encodeWithSignature("renounceOwnership()"), 0);
        _try("startContractRecoveryProcess", abi.encodeWithSignature("startContractRecoveryProcess()"), 0);
        _try("initiateOwnerQuorumCall", abi.encodeWithSignature("initiateOwnerQuorumCall()"), 0);
        if (!isEth) {
            (bool ok,) = underlying.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", target, address(this), 1));
            labels.push("underlying.transferFrom(wrapper)");
            oks.push(ok);
        }
    }
}

contract EmergencyRecoveryGuardTest is Test {
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address donor = makeAddr("donor");
    address sink = makeAddr("sink");

    string[28] TICKERS = [
        "AAVE", "AXS", "COMP", "CRV", "crvUSD", "CVX", "DAI", "ENS", "ETHFI", "FET", "GHO", "GRT", "IMX", "INJ", "JASMY",
        "LDO", "LINK", "PENDLE", "PEPE", "POL", "SHIB", "SKY", "STRK", "UNI", "WBTC", "WETH", "WLD", "wstETH"
    ];

    struct Snap {
        uint256 alice; uint256 bob; uint256 supply; uint256 backing; uint256 tax; uint256 recUnderlying;
        uint256 recITokens; address own; address pending; uint256 aliceAct; uint256 heirCount; uint256 ruCount;
    }

    function _snap(InheritfiV1Base w, address u, bool eth) internal view returns (Snap memory s) {
        s.alice = w.balanceOf(alice);
        s.bob = w.balanceOf(bob);
        s.supply = w.totalSupply();
        s.backing = eth ? address(w).balance : IERC20(u).balanceOf(address(w));
        s.tax = w.accumulatedTax();
        s.recUnderlying = eth ? InheritfiV1ETH(payable(address(w))).getRecoverableETH() : InheritfiV1DAI(address(w)).getRecoverableDAI();
        s.recITokens = w.getRecoverableITokens();
        s.own = w.owner();
        s.pending = w.pendingOwner();
        (,,,,, s.aliceAct, s.heirCount, s.ruCount,,,,,) = w.getUserInfo(alice);
    }

    function _assertUserFundsIntact(Snap memory a, Snap memory b) internal pure {
        assertEq(a.alice, b.alice, "alice balance");
        assertEq(a.bob, b.bob, "bob balance");
        assertEq(a.recUnderlying, b.recUnderlying, "recoverable underlying");
        assertEq(a.recITokens, b.recITokens, "recoverable iTokens");
        assertEq(b.backing - b.recUnderlying, b.supply, "backing == supply + excess");
        assertEq(a.own, b.own, "owner");
        assertEq(a.pending, b.pending, "pending owner");
        assertEq(a.aliceAct, b.aliceAct, "alice activity");
        assertEq(a.heirCount, b.heirCount, "alice heirs");
        assertEq(a.ruCount, b.ruCount, "alice recovery users");
    }

    function _configureAlice(InheritfiV1Base w) internal {
        address[] memory hs = new address[](1); hs[0] = bob;
        uint256[] memory ps = new uint256[](1); ps[0] = 10_000;
        address[] memory rs = new address[](1); rs[0] = carol;
        vm.startPrank(alice);
        w.setHeirs(hs, ps);
        w.setRecoveryUsers(rs);
        vm.stopPrank();
    }

    function _deployDai(address u) internal returns (InheritfiV1DAI w) {
        vm.prank(owner);
        w = new InheritfiV1DAI(u);
        GuardUnderlying(u).mint(alice, 1000 ether);
        vm.startPrank(alice);
        IERC20(u).approve(address(w), type(uint256).max);
        w.wrap(1000 ether);
        vm.stopPrank();
        _configureAlice(w);
        GuardUnderlying(u).mint(donor, 5 ether);
        vm.prank(donor);
        IERC20(u).transfer(address(w), 5 ether);
    }

    function _deployEth() internal returns (InheritfiV1ETH w) {
        vm.prank(owner);
        w = new InheritfiV1ETH();
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        w.wrap{value: 1000 ether}();
        _configureAlice(w);
        vm.deal(address(w), address(w).balance + 5 ether); // ETH forced into the contract
    }

    function _evil(InheritfiV1Base w, address u, bool eth) internal returns (GuardEvil e) {
        e = new GuardEvil();
        e.setup(address(w), u, alice, eth);
        if (eth) vm.deal(address(e), 100 ether);
        else GuardUnderlying(u).mint(address(e), 100 ether);
        e.prepare(10 ether);
        e.setFakeBal(1 ether);
    }

    // ---------- 1. Guard in all 29 contracts ----------

    function test_guard_all28Erc20Wrappers() public {
        GuardNft nft = new GuardNft();
        GuardMulti multi = new GuardMulti();
        for (uint256 i; i < TICKERS.length; i++) {
            string memory t = TICKERS[i];
            GuardSelectorUnderlying u = new GuardSelectorUnderlying();
            vm.prank(owner);
            address w = vm.deployCode(string.concat("InheritfiV1", t, ".sol:InheritfiV1", t), abi.encode(address(u)));
            u.mint(alice, 1000 ether);
            vm.startPrank(alice);
            u.approve(w, type(uint256).max);
            InheritfiV1DAI(w).wrap(1000 ether);
            vm.stopPrank();
            uint256 supply = InheritfiV1Base(w).totalSupply();
            vm.startPrank(owner);
            vm.expectRevert(bytes("Protected asset"));
            InheritfiV1Base(w).emergencyRecoverERC721(address(u), sink, 1000 ether);
            vm.expectRevert(bytes("Protected asset"));
            InheritfiV1Base(w).emergencyRecoverERC1155(address(u), sink, 0, 1000 ether);
            vm.expectRevert(bytes("Protected asset"));
            InheritfiV1Base(w).emergencyRecoverERC721(w, sink, 1);
            vm.expectRevert(bytes("Protected asset"));
            InheritfiV1Base(w).emergencyRecoverERC1155(w, sink, 1, 1);
            vm.stopPrank();
            assertEq(u.balanceOf(w), supply, string.concat(t, ": backing intact"));
            assertEq(u.balanceOf(sink), 0, string.concat(t, ": nothing left"));
            // Real NFTs and ERC-1155 tokens sent by mistake can still be returned.
            nft.mint(w, i);
            multi.mint(w, i, 3);
            vm.startPrank(owner);
            InheritfiV1Base(w).emergencyRecoverERC721(address(nft), sink, i);
            InheritfiV1Base(w).emergencyRecoverERC1155(address(multi), sink, i, 3);
            vm.stopPrank();
            assertEq(nft.ownerOf(i), sink, string.concat(t, ": NFT returned"));
            assertEq(multi.balanceOf(sink, i), 3, string.concat(t, ": ERC-1155 returned"));
        }
    }

    function test_guard_ethWrapper() public {
        InheritfiV1ETH w = _deployEth();
        GuardNft nft = new GuardNft();
        GuardMulti multi = new GuardMulti();
        vm.startPrank(owner);
        vm.expectRevert(bytes("Protected asset"));
        w.emergencyRecoverERC721(address(w), sink, 1);
        vm.expectRevert(bytes("Protected asset"));
        w.emergencyRecoverERC1155(address(w), sink, 1, 1);
        vm.expectRevert(bytes("Bad addr"));
        w.emergencyRecoverERC721(address(0), sink, 1);
        vm.expectRevert(bytes("Bad input"));
        w.emergencyRecoverERC1155(address(0), sink, 1, 1);
        vm.stopPrank();
        nft.mint(address(w), 9);
        multi.mint(address(w), 9, 2);
        vm.startPrank(owner);
        w.emergencyRecoverERC721(address(nft), sink, 9);
        w.emergencyRecoverERC1155(address(multi), sink, 9, 2);
        vm.stopPrank();
        assertEq(nft.ownerOf(9), sink);
        assertEq(multi.balanceOf(sink, 9), 2);
        assertEq(address(w).balance - w.getRecoverableETH(), w.totalSupply());
    }

    function test_guard_fallbackUnderlying() public {
        GuardFallbackUnderlying u = new GuardFallbackUnderlying();
        vm.prank(owner);
        InheritfiV1DAI w = new InheritfiV1DAI(address(u));
        vm.startPrank(owner);
        vm.expectRevert(bytes("Protected asset"));
        w.emergencyRecoverERC721(address(u), sink, 1);
        vm.expectRevert(bytes("Protected asset"));
        w.emergencyRecoverERC1155(address(u), sink, 1, 1);
        vm.stopPrank();
    }

    /// A failed recovery attempt reverts entirely: no proof of life is recorded either.
    function test_guard_revertKeepsOwnerActivity() public {
        GuardUnderlying u = new GuardUnderlying();
        InheritfiV1DAI w = _deployDai(address(u));
        uint256 before = w.lastOwnerActivityTimestamp();
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert(bytes("Protected asset"));
        w.emergencyRecoverERC721(address(u), sink, 1);
        assertEq(w.lastOwnerActivityTimestamp(), before);
    }

    // ---------- 2. Malicious tokens sent directly to a wrapper ----------

    function _reenterCase(bool eth, uint8 fn) internal {
        GuardUnderlying u = new GuardUnderlying();
        InheritfiV1Base w = eth ? InheritfiV1Base(address(_deployEth())) : InheritfiV1Base(address(_deployDai(address(u))));
        GuardEvil e = _evil(w, address(u), eth);
        e.setMode(GuardEvil.Mode.REENTER, 0);
        Snap memory a = _snap(w, address(u), eth);
        vm.prank(owner);
        if (fn == 0) w.emergencyRecoverERC721(address(e), sink, 1);
        else if (fn == 1) w.emergencyRecoverERC1155(address(e), sink, 1, 1);
        else if (eth) InheritfiV1ETH(payable(address(w))).emergencyRecoverERC20(address(e), sink, 1);
        else InheritfiV1DAI(address(w)).emergencyRecoverERC20(address(e), sink, 1);
        Snap memory b = _snap(w, address(u), eth);
        uint256 n = e.count();
        assertGt(n, 20, "reentrant attempts recorded");
        for (uint256 i; i < n; i++) {
            bytes32 h = keccak256(bytes(e.labels(i)));
            bool userAction = h == keccak256("wrap") || h == keccak256("unwrap") || h == keccak256("transfer")
                || h == keccak256("checkActivity") || h == keccak256("setHeirs");
            if (userAction) assertTrue(e.oks(i), string.concat("user action failed: ", e.labels(i)));
            else assertFalse(e.oks(i), string.concat("privileged call succeeded: ", e.labels(i)));
        }
        _assertUserFundsIntact(a, b);
        assertEq(w.balanceOf(address(w)), w.accumulatedTax(), "contract iTokens == accumulated tax");
        assertGt(b.tax, a.tax, "attacker paid fees");
    }

    function test_malicious_reenter_DAI_ERC20() public { _reenterCase(false, 2); }
    function test_malicious_reenter_DAI_ERC721() public { _reenterCase(false, 0); }
    function test_malicious_reenter_DAI_ERC1155() public { _reenterCase(false, 1); }
    function test_malicious_reenter_ETH_ERC20() public { _reenterCase(true, 2); }
    function test_malicious_reenter_ETH_ERC721() public { _reenterCase(true, 0); }
    function test_malicious_reenter_ETH_ERC1155() public { _reenterCase(true, 1); }

    function _modeCase(GuardEvil.Mode m, uint256 size, uint8 fn, bool expectRevert) internal {
        GuardUnderlying u = new GuardUnderlying();
        InheritfiV1DAI w = _deployDai(address(u));
        GuardEvil e = _evil(w, address(u), false);
        e.setMode(m, size);
        Snap memory a = _snap(w, address(u), false);
        uint256 lastBefore = w.lastOwnerActivityTimestamp();
        vm.warp(block.timestamp + 1 days);
        bytes memory data;
        if (fn == 0) data = abi.encodeWithSignature("emergencyRecoverERC721(address,address,uint256)", address(e), sink, 1);
        else if (fn == 1) data = abi.encodeWithSignature("emergencyRecoverERC1155(address,address,uint256,uint256)", address(e), sink, 1, 1);
        else data = abi.encodeWithSignature("emergencyRecoverERC20(address,address,uint256)", address(e), sink, 1);
        vm.prank(owner);
        (bool ok,) = address(w).call{gas: 15_000_000}(data);
        assertEq(ok, !expectRevert, "expected outcome");
        Snap memory b = _snap(w, address(u), false);
        _assertUserFundsIntact(a, b);
        assertEq(b.tax, a.tax, "tax");
        assertEq(b.supply, a.supply, "supply");
        if (expectRevert) assertEq(w.lastOwnerActivityTimestamp(), lastBefore, "owner activity rolled back");
    }

    function test_malicious_revertBomb_ERC20() public { _modeCase(GuardEvil.Mode.REVERT_BOMB, 200_000, 2, true); }
    function test_malicious_revertBomb_ERC721() public { _modeCase(GuardEvil.Mode.REVERT_BOMB, 200_000, 0, true); }
    function test_malicious_revertBomb_ERC1155() public { _modeCase(GuardEvil.Mode.REVERT_BOMB, 200_000, 1, true); }
    function test_malicious_returnBomb_ERC20() public { _modeCase(GuardEvil.Mode.RETURN_BOMB, 200_000, 2, false); }
    function test_malicious_returnBomb_ERC721() public { _modeCase(GuardEvil.Mode.RETURN_BOMB, 200_000, 0, false); }
    function test_malicious_returnBomb_ERC1155() public { _modeCase(GuardEvil.Mode.RETURN_BOMB, 200_000, 1, false); }
    function test_malicious_gasBurn_ERC20() public { _modeCase(GuardEvil.Mode.GAS_BURN, 0, 2, true); }
    function test_malicious_gasBurn_ERC721() public { _modeCase(GuardEvil.Mode.GAS_BURN, 0, 0, true); }
    function test_malicious_gasBurn_ERC1155() public { _modeCase(GuardEvil.Mode.GAS_BURN, 0, 1, true); }
    function test_malicious_lie_ERC20() public { _modeCase(GuardEvil.Mode.LIE, 0, 2, false); }
    function test_malicious_returnFalse_ERC20() public { _modeCase(GuardEvil.Mode.RETURN_FALSE, 0, 2, true); }
    function test_malicious_returnFalse_ERC721() public { _modeCase(GuardEvil.Mode.RETURN_FALSE, 0, 0, true); }

    function test_malicious_lyingBalance() public {
        GuardUnderlying u = new GuardUnderlying();
        InheritfiV1DAI w = _deployDai(address(u));
        GuardEvil e = _evil(w, address(u), false);
        e.setMode(GuardEvil.Mode.LIE, 0);
        e.setFakeBal(0);
        vm.prank(owner);
        vm.expectRevert(bytes("Insufficient balance"));
        w.emergencyRecoverERC20(address(e), sink, 1);
        e.setFakeBal(type(uint256).max);
        Snap memory a = _snap(w, address(u), false);
        vm.prank(owner);
        w.emergencyRecoverERC20(address(e), sink, type(uint256).max);
        _assertUserFundsIntact(a, _snap(w, address(u), false));
    }

    function test_receivers_noStateWrites() public {
        GuardUnderlying u = new GuardUnderlying();
        InheritfiV1DAI w = _deployDai(address(u));
        GuardNft n = new GuardNft();
        GuardMulti m = new GuardMulti();
        Snap memory a = _snap(w, address(u), false);
        vm.record();
        n.mint(address(w), 7);
        m.mint(address(w), 1, 10);
        uint256[] memory ids = new uint256[](2); ids[0] = 2; ids[1] = 3;
        uint256[] memory vs = new uint256[](2); vs[0] = 1; vs[1] = 2;
        m.mintBatch(address(w), ids, vs);
        assertEq(w.onERC721Received(address(1), address(2), 3, hex"dead"), w.onERC721Received.selector);
        assertEq(w.onERC1155Received(address(1), address(2), 3, 4, hex"dead"), w.onERC1155Received.selector);
        assertEq(w.onERC1155BatchReceived(address(1), address(2), ids, vs, hex"dead"), w.onERC1155BatchReceived.selector);
        (, bytes32[] memory writes) = vm.accesses(address(w));
        assertEq(writes.length, 0, "receivers never write to the wrapper");
        _assertUserFundsIntact(a, _snap(w, address(u), false));
    }

    function test_ownerLimits_DAI() public {
        GuardUnderlying u = new GuardUnderlying();
        InheritfiV1DAI w = _deployDai(address(u));
        vm.prank(alice);
        w.transfer(address(w), 2 ether);
        uint256 tax = w.accumulatedTax();
        assertEq(w.getRecoverableDAI(), 5 ether);
        assertEq(w.getRecoverableITokens(), 2 ether);
        vm.startPrank(owner);
        vm.expectRevert(bytes("Exceeds recoverable"));
        w.emergencyRecoverDAI(sink, 5 ether + 1);
        vm.expectRevert(bytes("Use emergencyRecoverDAI"));
        w.emergencyRecoverERC20(address(u), sink, 1);
        vm.expectRevert(bytes("Exceeds recoverable"));
        w.emergencyRecoverERC20(address(w), sink, 2 ether + 1);
        w.emergencyRecoverDAI(sink, 5 ether);
        w.emergencyRecoverERC20(address(w), sink, 2 ether);
        vm.stopPrank();
        assertEq(w.getRecoverableDAI(), 0);
        assertEq(w.getRecoverableITokens(), 0);
        assertEq(w.accumulatedTax(), tax);
        assertEq(u.balanceOf(address(w)), w.totalSupply(), "backing intact");
        vm.deal(address(w), 1 ether); // ETH forced into an ERC-20 wrapper belongs to no user
        vm.prank(owner);
        w.emergencyRecoverETH(payable(sink), 1 ether);
        assertEq(u.balanceOf(address(w)), w.totalSupply());
    }

    function test_ownerLimits_ETH() public {
        InheritfiV1ETH w = _deployEth();
        assertEq(w.getRecoverableETH(), 5 ether);
        vm.startPrank(owner);
        vm.expectRevert(bytes("Exceeds recoverable"));
        w.emergencyRecoverETH(payable(sink), 5 ether + 1);
        w.emergencyRecoverETH(payable(sink), 5 ether);
        vm.stopPrank();
        assertEq(address(w).balance, w.totalSupply(), "backing intact");
    }

    /// Without the owner, a malicious token inside the contract is never executed.
    function test_noAutomaticCallsToForeignTokens() public {
        GuardUnderlying u = new GuardUnderlying();
        InheritfiV1DAI w = _deployDai(address(u));
        GuardEvil e = _evil(w, address(u), false);
        e.setMode(GuardEvil.Mode.GAS_BURN, 0);
        e.setFakeBal(1e30);
        vm.prank(alice);
        w.unwrap(10 ether);
        vm.prank(alice);
        w.transfer(carol, 1 ether);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + w.recoveryInactivityPeriod() + 1 days);
        vm.prank(carol);
        w.startRecovery(alice);
        vm.warp(t0 + w.recoveryInactivityPeriod() + w.recoveryWaitingTime() + 2 days);
        vm.prank(carol);
        w.executeRecovery(alice);
        assertEq(w.balanceOf(alice), 0);
        assertEq(u.balanceOf(address(w)) - w.getRecoverableDAI(), w.totalSupply());
    }
}
