// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// INF-10 (AUD3): eight revert branches the review reported as unreachable were
// removed after being proven dead by code reading and fuzzing. This suite keeps
// the facts that made the removal safe, under any sequence of calls from any
// account, with the owner changing taxes, periods, treasuries, delegates and
// ownership at any time:
//   - a successful wrap or unwrap always pays at least 1 (was "Too small");
//   - structural invariants checked after every call:
//     S1 an heir index implies a non-empty heir list with non-zero percentages
//        (was "No heirs", "Zero pct");
//     S2 claim marks exist only with an inheritance or recovery in progress
//        (was "None claimed", "Zero pct");
//     S3 no delegate weight above 50, so accepting a candidacy never elects;
//     S4 a present flag implies membership of presentList (was "No present delegates");
//     S5 candidate records are complete or empty (was "Not found");
//     S6 no candidacy survives an election (was "Already elected");
//   - no arithmetic panic;
//   - control: the live "Not started" branch of executeInheritanceRemaining
//     (reachable since the AUD3-01 fix) is reached, proving the search gets that deep.

contract INF10MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

interface IINF10Wrapper {
    function wrap(uint256 amount) external;
    function unwrap(uint256 amount) external;
    function setWrappingTax(uint256 r) external;
    function setUnwrappingTax(uint256 r) external;
    function setTreasuries(address[] calldata wallets, uint256[] calldata percentages) external;
    function balanceOf(address a) external view returns (uint256);
}

contract INF10Handler is Test {
    InheritfiV1ETH public eth;
    uint256 internal constant N = 8;
    address[N] internal actors;

    uint256 public constant NACT = 39;

    uint256 public payoutViolations; // successful wrap or unwrap that paid 0
    uint256 public liveRemainingNotStarted;
    uint256 public panics;

    // Starting state (the fuzzer can change all of it): every actor holds iETH,
    // actors 0 to 2 have heirs and recovery contacts, actors 5 to 7 are delegates.
    // Roles overlap on purpose: a testator can also be an heir, a contact or a delegate.
    constructor() {
        for (uint256 i; i < N; i++) actors[i] = makeAddr(string.concat("inf10actor", vm.toString(i)));
        eth = new InheritfiV1ETH();
        for (uint256 i; i < N; i++) {
            vm.deal(actors[i], 10 ether);
            vm.prank(actors[i]);
            eth.wrap{value: 10 ether}();
        }
        for (uint256 t; t < 3; t++) {
            (address[] memory hs, uint256[] memory ps) = _split(2 + t % 2, 11 * t + 1, actors[t]);
            vm.prank(actors[t]);
            eth.setHeirs(hs, ps);
            (address[] memory rs, ) = _split(1 + t % 2, 7 * t + 3, actors[t]);
            vm.prank(actors[t]);
            eth.setRecoveryUsers(rs);
        }
        eth.addDelegate(actors[5], 50);
        vm.prank(actors[5]);
        eth.acceptDelegate();
        eth.addDelegate(actors[6], 50);
        vm.prank(actors[6]);
        eth.acceptDelegate();
        eth.addDelegate(actors[7], 34);
        vm.prank(actors[7]);
        eth.acceptDelegate();
    }

    // ─── call helpers ─────────────────────────────────────────────────────────

    function _reason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4) return "EMPTY";
        bytes4 sel = bytes4(ret);
        if (sel == 0x08c379a0) {
            bytes memory body = new bytes(ret.length - 4);
            for (uint256 i; i < body.length; i++) body[i] = ret[i + 4];
            return abi.decode(body, (string));
        }
        if (sel == 0x4e487b71) return "PANIC";
        return string.concat("CUSTOM:", vm.toString(abi.encodePacked(sel)));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _call(string memory label, address from, uint256 value, bytes memory data)
        internal
        returns (bool success, string memory reason)
    {
        vm.prank(from);
        bytes memory ret;
        (success, ret) = address(eth).call{value: value}(data);
        label;
        reason = success ? "OK" : _reason(ret);
        if (_eq(reason, "PANIC")) panics++;
    }

    // ─── actor selection ──────────────────────────────────────────────────────

    function _a(uint256 s) internal view returns (address) { return actors[s % N]; }

    function _heirOf(address t, uint256 s) internal view returns (address) {
        (address[] memory hs, ) = eth.getHeirs(t);
        if (hs.length > 0 && s % 4 != 0) return hs[(s / 4) % hs.length];
        return _a(s);
    }

    // Testator with heirs (or with recovery contacts), most of the time.
    function _testator(uint256 s, bool withContacts) internal view returns (address) {
        if (s % 4 != 0) {
            for (uint256 k; k < N; k++) {
                address t = actors[(s / 4 + k) % N];
                uint256 n = withContacts ? eth.getRecoveryUsers(t).length : _heirCount(t);
                if (n > 0) return t;
            }
        }
        return _a(s);
    }

    function _heirCount(address t) internal view returns (uint256 n) {
        (,,,,,, n,,,,,,) = eth.getUserInfo(t);
    }

    // An heir of `t` who already claimed (has a claim mark), most of the time.
    function _claimedHeirOf(address t, uint256 s) internal view returns (address) {
        if (s % 4 != 0) {
            (address[] memory hs, ) = eth.getHeirs(t);
            for (uint256 k; k < hs.length; k++) {
                address h = hs[(s / 4 + k) % hs.length];
                (,, bool received,,) = eth.getHeirInheritanceInfo(t, h);
                if (received) return h;
            }
        }
        return _heirOf(t, s / 4);
    }

    function _ruOf(address t, uint256 s) internal view returns (address) {
        address[] memory rs = eth.getRecoveryUsers(t);
        if (rs.length > 0 && s % 4 != 0) return rs[(s / 4) % rs.length];
        return _a(s);
    }

    function _del(uint256 s) internal view returns (address) {
        address[] memory ds = eth.getDelegates();
        if (ds.length > 0 && s % 4 != 0) return ds[(s / 4) % ds.length];
        return _a(s);
    }

    function _cand(uint256 s) internal view returns (address) {
        if (s % 3 == 0) {
            address[] memory cs = eth.getOwnerCandidates();
            if (cs.length > 0) return cs[(s / 3) % cs.length];
        } else if (s % 3 == 1) {
            for (uint256 k; k < N; k++) {
                address c = actors[(s / 3 + k) % N];
                if (eth.pendingNomination(c)) return c;
            }
        }
        return _a(s / 3);
    }

    // Distinct wallets (excluding `skip`) with percentages summing to 10_000.
    function _split(uint256 n, uint256 seed, address skip)
        internal
        view
        returns (address[] memory ws, uint256[] memory ps)
    {
        ws = new address[](n);
        ps = new uint256[](n);
        uint256 got;
        for (uint256 k; k < N && got < n; k++) {
            address w = actors[(seed % N + k) % N];
            if (w == skip) continue;
            ws[got] = w;
            got++;
        }
        if (got < n) {
            assembly { mstore(ws, got) mstore(ps, got) }
            n = got;
        }
        uint256 left = 10_000;
        for (uint256 i; i < n; i++) {
            if (i == n - 1) { ps[i] = left; break; }
            uint256 maxP = left - (n - 1 - i);
            uint256 p = 1 + (uint256(keccak256(abi.encode(seed, i))) % maxP);
            ps[i] = p;
            left -= p;
        }
    }

    // ─── user actions ─────────────────────────────────────────────────────────

    function wrap(uint256 ai, uint256 amt) public {
        address a = _a(ai);
        amt = amt % 4 == 0 ? bound(amt, 1, 1000) : bound(amt, 1, 50 ether);
        vm.deal(a, a.balance + amt);
        uint256 before = eth.balanceOf(a);
        (bool ok, ) = _call("wrap", a, amt, abi.encodeCall(InheritfiV1ETH.wrap, ()));
        if (ok && eth.balanceOf(a) <= before) payoutViolations++;
    }

    function unwrap(uint256 ai, uint256 amt) public {
        address a = _a(ai);
        uint256 bal = eth.balanceOf(a);
        if (bal == 0) amt = 1;
        else amt = amt % 4 == 0 ? bound(amt, 1, bal < 1000 ? bal : 1000) : bound(amt, 1, bal);
        uint256 ethBefore = a.balance;
        (bool ok, ) = _call("unwrap", a, 0, abi.encodeCall(InheritfiV1ETH.unwrap, (amt)));
        if (ok && a.balance <= ethBefore) payoutViolations++;
    }

    function transfer(uint256 ai, uint256 bi, uint256 amt) public {
        address a = _a(ai);
        uint256 bal = eth.balanceOf(a);
        amt = bound(amt, 0, bal);
        _call("transfer", a, 0, abi.encodeCall(eth.transfer, (_a(bi), amt)));
    }

    function setHeirs(uint256 ti, uint256 n, uint256 seed) public {
        address t = _a(ti);
        (address[] memory ws, uint256[] memory ps) = _split(bound(n, 1, 4), seed, t);
        if (seed % 9 == 0 && ws.length > 0) ws[0] = t; // invalid on purpose
        _call("setHeirs", t, 0, abi.encodeCall(eth.setHeirs, (ws, ps)));
    }

    function setRecoveryUsers(uint256 ti, uint256 n, uint256 seed) public {
        address t = _a(ti);
        (address[] memory ws, ) = _split(bound(n, 1, 3), seed, t);
        _call("setRecoveryUsers", t, 0, abi.encodeCall(eth.setRecoveryUsers, (ws)));
    }

    function startInheritance(uint256 ti, uint256 hi) public {
        address t = _testator(ti, false);
        _call("startInheritance", _heirOf(t, hi), 0, abi.encodeCall(eth.startInheritance, (t)));
    }

    function executeInheritance(uint256 ti, uint256 hi) public {
        address t = _testator(ti, false);
        _call("executeInheritance", _heirOf(t, hi), 0, abi.encodeCall(eth.executeInheritance, (t)));
    }

    function executeInheritanceRemaining(uint256 ti, uint256 hi) public {
        address t = _testator(ti, false);
        (, string memory r) = _call(
            "executeInheritanceRemaining", _claimedHeirOf(t, hi), 0, abi.encodeCall(eth.executeInheritanceRemaining, (t))
        );
        if (_eq(r, "Not started")) liveRemainingNotStarted++;
    }

    function startRecovery(uint256 ti, uint256 ri) public {
        address t = _testator(ti, true);
        _call("startRecovery", _ruOf(t, ri), 0, abi.encodeCall(eth.startRecovery, (t)));
    }

    function executeRecovery(uint256 ti, uint256 ri) public {
        address t = _testator(ti, true);
        _call("executeRecovery", _ruOf(t, ri), 0, abi.encodeCall(eth.executeRecovery, (t)));
    }

    function checkActivity(uint256 ai) public {
        _call("checkActivity", _a(ai), 0, abi.encodeCall(eth.checkActivity, ()));
    }

    function warp(uint256 s) public {
        s = s % 3 == 0 ? bound(s, 1 hours, 10 days) : bound(s, 0, 120 days);
        vm.warp(block.timestamp + s);
    }

    // ─── owner actions (always signed by the current owner) ──────────────────

    function _owner() internal view returns (address) { return eth.owner(); }

    function setTax(uint256 which, uint256 r) public {
        address o = _owner();
        if (o == address(0)) return;
        // Mostly valid rates; sometimes any rate up to 100 %, which the setters must reject.
        r = r % 2 == 0 ? bound(r, 0, 31) : bound(r, 0, 10_000);
        bytes4[4] memory sels = [
            eth.setWrappingTax.selector, eth.setUnwrappingTax.selector,
            eth.setInheritanceTax.selector, eth.setRecoveryTax.selector
        ];
        _call("setTax", o, 0, abi.encodeWithSelector(sels[which % 4], r));
    }

    function setPeriod(uint256 which, uint256 p) public {
        address o = _owner();
        if (o == address(0)) return;
        p = bound(p, 1 days, 200 days);
        bytes4[12] memory sels = [
            eth.setRecoveryInactivityPeriod.selector, eth.setInheritInactivityPeriod.selector,
            eth.setInheritWaitingTime.selector, eth.setInheritRemainingWaitingTime.selector,
            eth.setRecoveryWaitingTime.selector, eth.setRecoveryExecutionWindow.selector,
            eth.setContractRecoveryStartWaitingTime.selector, eth.setContractRecoveryWaitingTime.selector,
            eth.setQuorumInactivityPeriod.selector, eth.setQuorumRollcallWindow.selector,
            eth.setDelegateInvitationWindow.selector, eth.setOwnerInvitationWindow.selector
        ];
        _call("setPeriod", o, 0, abi.encodeWithSelector(sels[which % 12], p));
    }

    function setTreasuries(uint256 n, uint256 seed) public {
        address o = _owner();
        if (o == address(0)) return;
        (address[] memory ws, uint256[] memory ps) = _split(bound(n, 1, 3), seed, address(0));
        _call("setTreasuries", o, 0, abi.encodeCall(eth.setTreasuries, (ws, ps)));
    }

    function ownerCheck() public {
        address o = _owner();
        if (o == address(0)) return;
        _call("ownerCheck", o, 0, abi.encodeCall(eth.ownerCheck, ()));
    }

    function collectTax(uint256 ai) public {
        address from = ai % 2 == 0 ? _owner() : _a(ai);
        if (from == address(0)) return;
        _call("collectTax", from, 0, abi.encodeCall(eth.collectTax, ()));
    }

    function transferOwnership(uint256 ti) public {
        address o = _owner();
        if (o == address(0)) return;
        address to = ti % 5 == 0 ? address(0) : _a(ti);
        _call("transferOwnership", o, 0, abi.encodeCall(eth.transferOwnership, (to)));
    }

    function acceptOwnership(uint256 ai) public {
        address a = eth.pendingOwner();
        if (a == address(0) || ai % 4 == 0) a = _a(ai);
        _call("acceptOwnership", a, 0, abi.encodeCall(eth.acceptOwnership, ()));
    }

    function renounce(uint256 step) public {
        address o = _owner();
        if (o == address(0)) return;
        if (step % 3 == 0) _call("startRenounce", o, 0, abi.encodeCall(eth.startRenounceOwnershipProcess, ()));
        else if (step % 3 == 1) _call("cancelRenounce", o, 0, abi.encodeCall(eth.cancelRenounceOwnershipProcess, ()));
        else _call("renounce", o, 0, abi.encodeCall(eth.renounceOwnership, ()));
    }

    function addDelegate(uint256 di, uint256 w) public {
        address o = _owner();
        if (o == address(0)) return;
        _call("addDelegate", o, 0, abi.encodeCall(eth.addDelegate, (_a(di), bound(w, 1, 60))));
    }

    function acceptDelegate(uint256 di) public {
        _call("acceptDelegate", _a(di), 0, abi.encodeCall(eth.acceptDelegate, ()));
    }

    function setDelegateWeight(uint256 di, uint256 w) public {
        address o = _owner();
        if (o == address(0)) return;
        _call("setDelegateWeight", o, 0, abi.encodeCall(eth.setDelegateWeight, (_del(di), bound(w, 1, 60))));
    }

    function removeDelegate(uint256 di) public {
        address o = _owner();
        if (o == address(0)) return;
        _call("removeDelegate", o, 0, abi.encodeCall(eth.removeDelegate, (_del(di))));
    }

    // ─── governance actions ───────────────────────────────────────────────────

    function nominate(uint256 di, uint256 ci) public {
        _call("nominate", _del(di), 0, abi.encodeCall(eth.nominateOwnerCandidate, (_a(ci))));
    }

    function acceptCandidacy(uint256 ci) public {
        _call("acceptCandidacy", _cand(ci), 0, abi.encodeCall(eth.acceptOwnerCandidacy, ()));
    }

    function vote(uint256 di, uint256 ci) public {
        _call("vote", _del(di), 0, abi.encodeCall(eth.voteForOwnerCandidate, (_cand(ci))));
    }

    function cancel(uint256 di, uint256 ci) public {
        address c = _cand(ci);
        address d = _del(di);
        if (di % 2 == 0) {
            (,, address nom) = eth.ownerCandidates(c);
            if (nom != address(0)) d = nom;
        }
        _call("cancel", d, 0, abi.encodeCall(eth.cancelOwnerCandidacy, (c)));
    }

    function startContractRecovery(uint256 di) public {
        _call("startContractRecovery", _del(di), 0, abi.encodeCall(eth.startContractRecoveryProcess, ()));
    }

    function executeContractRecovery(uint256 di) public {
        _call("executeContractRecovery", _del(di), 0, abi.encodeCall(eth.executeContractRecovery, ()));
    }

    function quorumCall(uint256 di) public {
        _call("quorumCall", _del(di), 0, abi.encodeCall(eth.quorumCall, ()));
    }

    function present(uint256 di) public {
        _call("present", _del(di), 0, abi.encodeCall(eth.present, ()));
    }

    function quorate(uint256 di) public {
        _call("quorate", _del(di), 0, abi.encodeCall(eth.quorate, ()));
    }

    // One entry point for the owner and the pending owner, so that owner
    // actions (each of which proves the owner alive) stay infrequent and the
    // owner-absence paths (nomination, quorum call, quorate) are reachable.
    function ownerAction(uint256 which, uint256 x, uint256 y) public {
        uint256 w = which % 12;
        if (w == 0) setTax(x, y);
        else if (w == 1) setPeriod(x, y);
        else if (w == 2) setTreasuries(x, y);
        else if (w == 3) ownerCheck();
        else if (w == 4) collectTax(x);
        else if (w == 5) transferOwnership(x);
        else if (w == 6) acceptOwnership(x);
        else if (w == 7) renounce(x);
        else if (w == 8) addDelegate(x, y);
        else if (w == 9) setDelegateWeight(x, y);
        else if (w == 10) removeDelegate(x);
        else addDelegate(x, y);
    }

    // ─── dispatch (used by the reach control) ───────────────────────────────────

    function dispatch(uint256 r) external {
        uint256 x = uint256(keccak256(abi.encode(r, 1)));
        uint256 y = uint256(keccak256(abi.encode(r, 2)));
        uint256 z = uint256(keccak256(abi.encode(r, 3)));
        uint256 a = r % NACT;
        if (a == 0 || a == 1) wrap(x, y);
        else if (a == 2) unwrap(x, y);
        else if (a == 3) transfer(x, y, z);
        else if (a == 4) setHeirs(x, y, z);
        else if (a == 5) setRecoveryUsers(x, y, z);
        else if (a == 6 || a == 7) startInheritance(x, y);
        else if (a == 8 || a == 9) executeInheritance(x, y);
        else if (a == 10 || a == 11 || a == 12) executeInheritanceRemaining(x, y);
        else if (a == 13 || a == 14) startRecovery(x, y);
        else if (a == 15) executeRecovery(x, y);
        else if (a == 16) checkActivity(x);
        else if (a >= 17 && a <= 20) warp(x);
        else if (a == 21) ownerAction(x, y, z);
        else if (a == 22) acceptDelegate(x);
        else if (a == 23 || a == 24) nominate(x, y);
        else if (a == 25 || a == 26) acceptCandidacy(x);
        else if (a == 27 || a == 28) vote(x, y);
        else if (a == 29 || a == 30) cancel(x, y);
        else if (a == 31) startContractRecovery(x);
        else if (a == 32) executeContractRecovery(x);
        else if (a == 33) quorumCall(x);
        else if (a == 34 || a == 35) present(x);
        else quorate(x);
    }

    function actionSelectors() external pure returns (bytes4[] memory s) {
        s = new bytes4[](23);
        s[0] = this.wrap.selector;               s[1] = this.unwrap.selector;
        s[2] = this.transfer.selector;           s[3] = this.setHeirs.selector;
        s[4] = this.setRecoveryUsers.selector;   s[5] = this.startInheritance.selector;
        s[6] = this.executeInheritance.selector; s[7] = this.executeInheritanceRemaining.selector;
        s[8] = this.startRecovery.selector;      s[9] = this.executeRecovery.selector;
        s[10] = this.checkActivity.selector;     s[11] = this.warp.selector;
        s[12] = this.ownerAction.selector;       s[13] = this.acceptDelegate.selector;
        s[14] = this.nominate.selector;          s[15] = this.acceptCandidacy.selector;
        s[16] = this.vote.selector;              s[17] = this.cancel.selector;
        s[18] = this.startContractRecovery.selector; s[19] = this.executeContractRecovery.selector;
        s[20] = this.quorumCall.selector;        s[21] = this.present.selector;
        s[22] = this.quorate.selector;
    }

    // ─── structural invariants behind the proofs ─────────────────────────────

    // Returns "" when every invariant holds, otherwise the name of the first broken one.
    function structuralViolation() external view returns (string memory) {
        for (uint256 i; i < N; i++) {
            address t = actors[i];
            (,,,,,, uint256 heirCount,, bool inh,, bool rec,,) = eth.getUserInfo(t);
            bool anyMark;
            for (uint256 j; j < N; j++) {
                try eth.getHeirInheritanceInfo(t, actors[j]) returns (
                    uint256 pct, uint256, bool received, uint256, uint256
                ) {
                    if (heirCount == 0) return "S1 heir index without heirs (was No heirs)";
                    if (pct == 0) return "S1 heir with zero percentage (was Zero pct)";
                    if (received) anyMark = true;
                } catch Error(string memory r) {
                    if (!_eq(r, "Not heir")) return string.concat("S1 view reverted: ", r);
                } catch {
                    return "S1 view panicked";
                }
            }
            if (anyMark && !inh && !rec) return "S2 claim marks without a process (was None claimed, Zero pct)";
        }
        address[] memory present_ = eth.getPresentDelegates();
        for (uint256 i; i < N; i++) {
            address a = actors[i];
            (,, uint256 w,,,) = eth.delegates(a);
            if (w > 50) return "S3 weight above 50 (an accepted candidacy could elect)";
            if (eth.presentConfirmed(a)) {
                bool found;
                for (uint256 k; k < present_.length; k++) if (present_[k] == a) found = true;
                if (!found) return "S4 present flag outside presentList (was No present delegates)";
            }
            (address cand,, address nom) = eth.ownerCandidates(a);
            if (cand != address(0) && cand != a) return "S5 candidate record under another key (was Not found)";
            if ((nom != address(0)) != (cand == a)) return "S5 nominator and candidate out of sync (was Not found)";
            if (eth.ownerElected() && (nom != address(0) || eth.pendingNomination(a))) {
                return "S6 candidacy alive after election (was Already elected)";
            }
        }
        if (eth.ownerElected() && eth.getOwnerCandidates().length != 0) return "S6 candidate list after election (was Already elected)";
        return "";
    }
}

// Coverage-guided invariant fuzzing over the handler (Foundry engine).
contract INF10InvariantTest is Test {
    INF10Handler h;

    function setUp() public {
        h = new INF10Handler();
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: h.actionSelectors()}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_structure() public view {
        assertEq(h.structuralViolation(), "", "structural invariant");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_wrapAndUnwrapPayAtLeastOne() public view {
        assertEq(h.payoutViolations(), 0, "wrap or unwrap paid 0");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_noPanic() public view {
        assertEq(h.panics(), 0, "panic");
    }
}

// Control: fixed pseudo-random sequences must reach the live "Not started"
// branch of executeInheritanceRemaining (an heir who already claimed, while a
// recovery is armed), so the search is known to get that deep.
contract INF10ReachControlTest is Test {
    uint256 constant SEQS = 200;
    uint256 constant STEPS = 150;

    function test_reachesLiveNotStartedBranch() public {
        // 30,000 calls exceed the per-test gas limit; gas is not what this test measures.
        vm.pauseGasMetering();
        uint256 live;
        for (uint256 s; s < SEQS; s++) {
            INF10Handler h = new INF10Handler();
            for (uint256 k; k < STEPS; k++) h.dispatch(uint256(keccak256(abi.encode("inf10", s, k))));
            assertEq(h.structuralViolation(), "", "structural invariant");
            assertEq(h.payoutViolations(), 0, "wrap or unwrap paid 0");
            assertEq(h.panics(), 0, "panic");
            live += h.liveRemainingNotStarted();
        }
        emit log_named_uint("live Not started reached", live);
        assertGt(live, 0, "live branch not reached");
    }
}

// Every wrapper (ETH and the 28 ERC-20): for any amount, both tax rates (0 to
// 30) and the treasury path, wrap mints at least 1 and unwrap pays at least 1.
contract INF10WrapPaysAtLeastOneTest is Test {
    string[28] TICKERS = [
        "AAVE", "AXS", "COMP", "CRV", "crvUSD", "CVX", "DAI", "ENS", "ETHFI", "FET", "GHO", "GRT", "IMX", "INJ", "JASMY",
        "LDO", "LINK", "PENDLE", "PEPE", "POL", "SHIB", "SKY", "STRK", "UNI", "WBTC", "WETH", "WLD", "wstETH"
    ];
    address[28] ws;
    INF10MockToken[28] us;
    InheritfiV1ETH eth;
    address U = makeAddr("inf10user");
    address T = makeAddr("inf10treasury");

    function setUp() public {
        address[] memory tw = new address[](1);
        tw[0] = T;
        uint256[] memory tp = new uint256[](1);
        tp[0] = 10_000;
        for (uint256 i; i < 28; i++) {
            us[i] = new INF10MockToken();
            string memory t = TICKERS[i];
            ws[i] = vm.deployCode(string.concat("InheritfiV1", t, ".sol:InheritfiV1", t), abi.encode(address(us[i])));
            IINF10Wrapper(ws[i]).setTreasuries(tw, tp);
        }
        eth = new InheritfiV1ETH();
        eth.setTreasuries(tw, tp);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_wrapAndUnwrapPayAtLeastOne(uint256 amount, uint256 wr, uint256 ur, uint256 back) public {
        amount = amount % 2 == 0 ? bound(amount, 1, 1000) : bound(amount, 1, 1e36);
        wr = bound(wr, 0, 30);
        ur = bound(ur, 0, 30);
        for (uint256 i; i < 28; i++) {
            IINF10Wrapper w = IINF10Wrapper(ws[i]);
            w.setWrappingTax(wr);
            w.setUnwrappingTax(ur);
            _cycleErc20(w, us[i], U, amount, back);
            _cycleErc20(w, us[i], T, amount, back);
        }
        eth.setWrappingTax(wr);
        eth.setUnwrappingTax(ur);
        _cycleEth(U, amount, back);
        _cycleEth(T, amount, back);
    }

    function _cycleErc20(IINF10Wrapper w, INF10MockToken u, address who, uint256 amount, uint256 back) internal {
        u.mint(who, amount);
        vm.startPrank(who);
        u.approve(address(w), amount);
        w.wrap(amount);
        uint256 bal = w.balanceOf(who);
        assertGt(bal, 0, "wrap minted nothing");
        uint256 before = u.balanceOf(who);
        w.unwrap(back % 2 == 0 ? 1 : bound(back, 1, bal));
        assertGt(u.balanceOf(who), before, "unwrap paid nothing");
        vm.stopPrank();
    }

    function _cycleEth(address who, uint256 amount, uint256 back) internal {
        vm.deal(who, amount);
        vm.startPrank(who);
        eth.wrap{value: amount}();
        uint256 bal = eth.balanceOf(who);
        assertGt(bal, 0, "wrap minted nothing");
        uint256 before = who.balance;
        eth.unwrap(back % 2 == 0 ? 1 : bound(back, 1, bal));
        assertGt(who.balance, before, "unwrap paid nothing");
        vm.stopPrank();
    }
}
