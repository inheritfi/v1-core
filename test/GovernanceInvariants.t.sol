// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "../src/InheritfiV1ETH.sol";

// Governance invariants under random delegate operations with live votes:
// (1) active weights sum exactly 100 (with >= 2 active), (2) every weight >= 1,
// (3) every weight <= 50, (4) each accepted candidate's totalVotes equals the sum
// of the weights of the active delegates who voted for it, (5) every pending
// nomination keeps totalVotes == 0, and (6) no operation ever reverts with an
// arithmetic panic.
// Each step picks its targets from the real state (active delegates, pending
// invitations, pending nominations, accepted candidates, candidacies with their
// nominator) and owner actions are rare, so votes, elections, cancellations,
// contract recoveries and the quorum path are reached. A coverage test replays
// 200 fixed seeds and requires every path to succeed at least once.
contract GovernanceInvariantsTest is Test {
    InheritfiV1ETH eth;
    uint256 constant ND = 10; // delegate pool
    uint256 constant NC = 6; // candidate pool
    uint256 constant STEPS = 48;
    uint256 constant COVERAGE_SEEDS = 200;
    address[ND] dels;
    address[NC] cands;

    // Paths counted by the coverage test.
    uint256 constant P_OWNER = 0;
    uint256 constant P_ACCEPT_DELEGATE = 1;
    uint256 constant P_NOMINATE = 2;
    uint256 constant P_ACCEPT_CANDIDACY = 3;
    uint256 constant P_VOTE = 4;
    uint256 constant P_CANCEL = 5;
    uint256 constant P_RECOVERY_START = 6;
    uint256 constant P_RECOVERY_EXECUTE = 7;
    uint256 constant P_QUORUM_CALL = 8;
    uint256 constant P_PRESENT = 9;
    uint256 constant P_QUORATE = 10;
    uint256 constant P_ELECTION = 11;
    uint256 constant NPATHS = 12;

    function setUp() public {
        for (uint256 i; i < ND; i++) dels[i] = makeAddr(string.concat("delegate", vm.toString(i)));
        for (uint256 i; i < NC; i++) cands[i] = makeAddr(string.concat("candidate", vm.toString(i)));
        eth = new InheritfiV1ETH();
        eth.setDelegateInvitationWindow(90 days);
        eth.addDelegate(_d(0), 50);
        vm.prank(_d(0));
        eth.acceptDelegate();
        eth.addDelegate(_d(1), 50);
        vm.prank(_d(1));
        eth.acceptDelegate();
        eth.addDelegate(_d(2), 34);
        vm.prank(_d(2));
        eth.acceptDelegate();
    }

    function _d(uint256 i) internal view returns (address) {
        return dels[i];
    }

    function _c(uint256 i) internal view returns (address) {
        return cands[i];
    }

    // Low-level call as `from`; ordinary reverts are allowed, arithmetic panics are not.
    function _call(string memory label, address from, bytes memory data) internal returns (bool ok) {
        vm.prank(from);
        bytes memory ret;
        (ok, ret) = address(eth).call(data);
        bool panic = !ok && ret.length >= 4 && bytes4(ret) == bytes4(0x4e487b71);
        assertFalse(panic, string.concat("panic in ", label));
    }

    function _checkInvariants() internal view {
        address[] memory list = eth.getDelegates();
        uint256 sum;
        for (uint256 i; i < list.length; i++) {
            (,, uint256 w,,,) = eth.delegates(list[i]);
            assertGe(w, 1, "rule 2: weight >= 1");
            assertLe(w, 50, "rule 3: weight <= 50");
            sum += w;
        }
        if (list.length >= 2) assertEq(sum, 100, "rule 1: sum == 100");

        address[] memory accepted = eth.getOwnerCandidates();
        for (uint256 j; j < accepted.length; j++) {
            (, uint256 tv,) = eth.ownerCandidates(accepted[j]);
            uint256 expected;
            for (uint256 i; i < list.length; i++) {
                (,, uint256 w, address vf,,) = eth.delegates(list[i]);
                if (vf == accepted[j]) expected += w;
            }
            assertEq(tv, expected, "tally: totalVotes == sum of voters' weights");
        }

        for (uint256 j; j < NC; j++) {
            if (eth.pendingNomination(cands[j])) {
                (, uint256 ptv,) = eth.ownerCandidates(cands[j]);
                assertEq(ptv, 0, "pending nomination keeps totalVotes == 0");
            }
        }
    }

    // ─── Target pickers (from the real state) ─────────────────────────────────

    function _pickActive(uint256 x) internal view returns (address) {
        address[] memory list = eth.getDelegates();
        if (list.length == 0) return address(0);
        return list[x % list.length];
    }

    function _pickInvitee(uint256 x) internal view returns (address) {
        address[ND] memory found;
        uint256 n;
        for (uint256 i; i < ND; i++) {
            (, bool pending,,,,) = eth.delegates(dels[i]);
            if (pending) found[n++] = dels[i];
        }
        if (n == 0) return address(0);
        return found[x % n];
    }

    function _pickPendingNominee(uint256 x) internal view returns (address) {
        address[NC] memory found;
        uint256 n;
        for (uint256 j; j < NC; j++) {
            if (eth.pendingNomination(cands[j])) found[n++] = cands[j];
        }
        if (n == 0) return address(0);
        return found[x % n];
    }

    function _pickAccepted(uint256 x) internal view returns (address) {
        address[] memory list = eth.getOwnerCandidates();
        if (list.length == 0) return address(0);
        return list[x % list.length];
    }

    // Any candidacy (pending or accepted) together with its nominator.
    function _pickCandidacy(uint256 x) internal view returns (address cand, address nom) {
        address[NC] memory found;
        uint256 n;
        for (uint256 j; j < NC; j++) {
            (address c,,) = eth.ownerCandidates(cands[j]);
            if (c != address(0)) found[n++] = cands[j];
        }
        if (n == 0) return (address(0), address(0));
        cand = found[x % n];
        (,, nom) = eth.ownerCandidates(cand);
    }

    // Owner action signed by the current owner: invite, change a weight or remove.
    function _ownerOp(uint256 r) internal returns (bool ok) {
        address o = eth.owner();
        address d = _d((r >> 8) % ND);
        uint256 w = 1 + ((r >> 24) % 50);
        uint256 sub = (r >> 40) % 3;
        if (sub == 0) ok = _call("addDelegate", o, abi.encodeCall(eth.addDelegate, (d, w)));
        else if (sub == 1) ok = _call("setDelegateWeight", o, abi.encodeCall(eth.setDelegateWeight, (d, w)));
        else ok = _call("removeDelegate", o, abi.encodeCall(eth.removeDelegate, (d)));
    }

    // One step: returns the path tried, whether it succeeded, and whether it
    // completed an election. Time passes after every step.
    function _step(uint256 seed, uint256 k) internal returns (uint256 path, bool ok, bool elected) {
        uint256 r = uint256(keccak256(abi.encode(seed, k)));
        uint256 op = r % 32;
        uint256 x = r >> 8;
        bool electedBefore = eth.ownerElected();
        if (op < 2) {
            path = P_OWNER;
            ok = _ownerOp(r);
        } else if (op < 5) {
            path = P_ACCEPT_DELEGATE;
            address d = _pickInvitee(x);
            if (d != address(0)) ok = _call("acceptDelegate", d, abi.encodeCall(eth.acceptDelegate, ()));
        } else if (op < 9) {
            path = P_NOMINATE;
            address d = _pickActive(x);
            address c = _c((r >> 16) % NC);
            if (d != address(0)) ok = _call("nominateOwnerCandidate", d, abi.encodeCall(eth.nominateOwnerCandidate, (c)));
        } else if (op < 12) {
            path = P_ACCEPT_CANDIDACY;
            address c = _pickPendingNominee(x);
            if (c != address(0)) ok = _call("acceptOwnerCandidacy", c, abi.encodeCall(eth.acceptOwnerCandidacy, ()));
        } else if (op < 17) {
            path = P_VOTE;
            address d = _pickActive(x);
            address c = _pickAccepted(r >> 16);
            if (d != address(0) && c != address(0)) {
                ok = _call("voteForOwnerCandidate", d, abi.encodeCall(eth.voteForOwnerCandidate, (c)));
            }
        } else if (op < 18) {
            path = P_CANCEL;
            (address c, address nom) = _pickCandidacy(x);
            if (c != address(0)) ok = _call("cancelOwnerCandidacy", nom, abi.encodeCall(eth.cancelOwnerCandidacy, (c)));
        } else if (op < 20) {
            address d = _pickActive(x);
            if (eth.ownerElected() && !eth.startContractRecovery()) {
                path = P_RECOVERY_START;
                if (d != address(0)) {
                    ok = _call("startContractRecoveryProcess", d, abi.encodeCall(eth.startContractRecoveryProcess, ()));
                }
            } else {
                path = P_RECOVERY_EXECUTE;
                if (d != address(0)) ok = _call("executeContractRecovery", d, abi.encodeCall(eth.executeContractRecovery, ()));
            }
        } else if (op < 22) {
            path = P_QUORUM_CALL;
            address d = _pickActive(x);
            if (d != address(0)) ok = _call("quorumCall", d, abi.encodeCall(eth.quorumCall, ()));
        } else if (op < 27) {
            path = P_PRESENT;
            address d = _pickActive(x);
            if (d != address(0)) ok = _call("present", d, abi.encodeCall(eth.present, ()));
        } else {
            path = P_QUORATE;
            address d = _pickActive(x);
            if (d != address(0)) ok = _call("quorate", d, abi.encodeCall(eth.quorate, ()));
        }
        elected = !electedBefore && eth.ownerElected();
        // Let time pass so that owner-inactivity paths become reachable.
        vm.warp(vm.getBlockTimestamp() + 1 days + ((r >> 32) % 20 days));
    }

    // Random sequence of governance operations; the invariants hold after every step.
    function testFuzz_governanceInvariants(uint256 seed) public {
        _checkInvariants();
        for (uint256 k; k < STEPS; k++) {
            _step(seed, k);
            _checkInvariants();
        }
    }

    // Replays COVERAGE_SEEDS fixed seeds and requires every governance path to
    // succeed at least once, so the fuzz above can never pass vacuously.
    function test_coverage_everyGovernancePathIsExercised() public {
        vm.pauseGasMetering();
        uint256 snap = vm.snapshotState();
        uint256[NPATHS] memory hits;
        for (uint256 seed; seed < COVERAGE_SEEDS; seed++) {
            vm.revertToState(snap);
            for (uint256 k; k < STEPS; k++) {
                (uint256 path, bool ok, bool elected) = _step(seed, k);
                if (ok) hits[path]++;
                if (elected) hits[P_ELECTION]++;
                _checkInvariants();
            }
        }

        emit log_named_uint("ok owner actions", hits[P_OWNER]);
        emit log_named_uint("ok acceptDelegate", hits[P_ACCEPT_DELEGATE]);
        emit log_named_uint("ok nominateOwnerCandidate", hits[P_NOMINATE]);
        emit log_named_uint("ok acceptOwnerCandidacy", hits[P_ACCEPT_CANDIDACY]);
        emit log_named_uint("ok voteForOwnerCandidate", hits[P_VOTE]);
        emit log_named_uint("elections completed", hits[P_ELECTION]);
        emit log_named_uint("ok cancelOwnerCandidacy", hits[P_CANCEL]);
        emit log_named_uint("ok startContractRecoveryProcess", hits[P_RECOVERY_START]);
        emit log_named_uint("ok executeContractRecovery", hits[P_RECOVERY_EXECUTE]);
        emit log_named_uint("ok quorumCall", hits[P_QUORUM_CALL]);
        emit log_named_uint("ok present", hits[P_PRESENT]);
        emit log_named_uint("ok quorate", hits[P_QUORATE]);

        assertGt(hits[P_OWNER], 0, "coverage: owner actions");
        assertGt(hits[P_ACCEPT_DELEGATE], 0, "coverage: acceptDelegate");
        assertGt(hits[P_NOMINATE], 0, "coverage: nominateOwnerCandidate");
        assertGt(hits[P_ACCEPT_CANDIDACY], 0, "coverage: acceptOwnerCandidacy");
        assertGt(hits[P_VOTE], 0, "coverage: voteForOwnerCandidate");
        assertGt(hits[P_ELECTION], 0, "coverage: elections");
        assertGt(hits[P_CANCEL], 0, "coverage: cancelOwnerCandidacy");
        assertGt(hits[P_RECOVERY_START], 0, "coverage: startContractRecoveryProcess");
        assertGt(hits[P_RECOVERY_EXECUTE], 0, "coverage: executeContractRecovery");
        assertGt(hits[P_QUORUM_CALL], 0, "coverage: quorumCall");
        assertGt(hits[P_PRESENT], 0, "coverage: present");
        assertGt(hits[P_QUORATE], 0, "coverage: quorate");
    }

    // N-11: a delegate accepts while another delegate's nomination is still pending.
    function test_acceptWhileNominationPending() public {
        eth.addDelegate(_d(3), 20);
        vm.warp(vm.getBlockTimestamp() + eth.contractRecoveryStartWaitingTime());
        vm.prank(_d(0));
        eth.nominateOwnerCandidate(_c(0));
        vm.prank(_d(3));
        eth.acceptDelegate();
        _checkInvariants();
    }

    // N-11/N-13: quorate drops an absent delegate whose nomination is still pending;
    // the orphan nomination is cleared and a present delegate can nominate again.
    function test_quorateWithAbsentPendingNominator() public {
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(_d(0));
        eth.nominateOwnerCandidate(_c(0));
        vm.prank(_d(1));
        eth.quorumCall();
        vm.prank(_d(2));
        eth.present();
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        vm.prank(_d(1));
        eth.quorate();
        _checkInvariants();

        (bool active,,,,,) = eth.delegates(_d(0));
        assertFalse(active, "absent nominator removed");
        assertFalse(eth.pendingNomination(_c(0)), "orphan nomination cleared");
        (address cand,, address nom) = eth.ownerCandidates(_c(0));
        assertEq(cand, address(0), "candidate record cleared");
        assertEq(nom, address(0), "nominator record cleared");
        vm.expectRevert();
        eth.pendingNominationList(0);

        vm.prank(_c(0));
        vm.expectRevert(bytes("Not nominated"));
        eth.acceptOwnerCandidacy();

        vm.prank(_d(1));
        eth.nominateOwnerCandidate(_c(0));
        vm.prank(_c(0));
        eth.acceptOwnerCandidacy();
        vm.prank(_d(2));
        eth.voteForOwnerCandidate(_c(0));
        assertTrue(eth.ownerElected(), "present delegates elect");
        assertEq(eth.ownerElect(), _c(0));
        _checkInvariants();
    }

    // N-13: an accepted candidacy whose nominator is absent no longer stalls the
    // election; every candidacy is reset and the present delegates elect anew.
    function test_quorateWithAbsentAcceptedNominator() public {
        vm.warp(vm.getBlockTimestamp() + eth.quorumInactivityPeriod());
        vm.prank(_d(0));
        eth.nominateOwnerCandidate(_c(0));
        vm.prank(_c(0));
        eth.acceptOwnerCandidacy();
        vm.prank(_d(1));
        eth.nominateOwnerCandidate(_c(1));
        vm.prank(_c(1));
        eth.acceptOwnerCandidacy();
        assertFalse(eth.ownerElected(), "split vote before the quorum");
        vm.prank(_d(1));
        eth.quorumCall();
        vm.prank(_d(2));
        eth.present();
        vm.warp(vm.getBlockTimestamp() + eth.quorumRollcallWindow());
        vm.prank(_d(1));
        eth.quorate();
        _checkInvariants();

        assertEq(eth.getOwnerCandidates().length, 0, "every candidacy reset");
        (address cand0,,) = eth.ownerCandidates(_c(0));
        assertEq(cand0, address(0), "orphan candidacy cleared");
        (,,, address vf1,,) = eth.delegates(_d(1));
        assertEq(vf1, address(0), "present nominator's vote released");

        vm.prank(_d(1));
        eth.nominateOwnerCandidate(_c(1));
        vm.prank(_c(1));
        eth.acceptOwnerCandidacy();
        vm.prank(_d(2));
        eth.voteForOwnerCandidate(_c(1));
        assertTrue(eth.ownerElected(), "present delegates elect");
        assertEq(eth.ownerElect(), _c(1));
        _checkInvariants();
    }
}
