// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "./InheritfiV1Types.sol";

/**
 * @title INHERITFI V1 Governance Lib
 * @notice External library containing delegate management, owner-election, and
 *         treasury management logic extracted from InheritfiV1Base.
 * @author INHERITFI ( https://inheritfi.com / inheritfi.eth )
 *
 * Deployed once; called via DELEGATECALL from InheritfiV1Base, so it operates
 * on the calling contract's storage slots directly.
 */
library InheritfiV1GovernanceLib {

    uint256 internal constant BP           = 10_000;
    uint256 internal constant MAX_WV       = 50;
    uint256 internal constant ELEC_THRESH  = 51;

    // ─── Events ───────────────────────────────────────────────────────────────
    event TreasuryUpdated(uint256 ts);
    event TreasuryPendingChange(address indexed t, address indexed newW);
    event TreasuryChangeAccepted(address indexed old, address indexed newW);
    event TreasuryChangeCancelled(address indexed t);

    event DelegateAdded(address indexed d, uint256 wv, uint256 ts);
    event DelegateRemoved(address indexed d, uint256 ts);
    event DelegateAccepted(address indexed d, uint256 ts);
    event DelegateWeightUpdated(address indexed d, uint256 oldW, uint256 newW);

    event OwnerCandidateNominated(address indexed c, address indexed n, uint256 ts);
    event OwnerCandidateAccepted(address indexed c, uint256 ts);
    event OwnerCandidateVoted(address indexed c, address indexed v, uint256 votes, uint256 total);
    event OwnerCandidateCancelled(address indexed c, address indexed n, uint256 ts);
    event OwnerElectChosen(address indexed elect, uint256 votes, uint256 ts);
    event ContractRecoveryStarted(address indexed initiator, uint256 ts);
    event ContractRecoveryExecuted(address indexed newOwner, uint256 ts);

    event QuorumCallInitiated(address indexed initiator, uint256 ts);
    event PresentConfirmed(address indexed delegate, uint256 ts);
    event QuorumCallCancelled(uint256 ts);
    event OwnerQuorateExecuted(uint256 presentCount, uint256 ts);
    event EmergencySingleOwnerElect(address indexed newOwner, uint256 ts);

    // ─── Treasury ─────────────────────────────────────────────────────────────

    /**
     * @notice Replace the treasury list atomically.
     * @return ts Timestamp of the update.
     */
    function setTreasuries(
        Treasury[] storage treasuries,
        mapping(address => bool) storage treasuryWallet,
        address[] calldata wallets,
        uint256[] calldata percentages,
        uint256 maxTreasuries
    ) external returns (uint256 ts) {
        require(wallets.length == percentages.length && wallets.length > 0, "Bad input");
        require(wallets.length <= maxTreasuries, "Too many");
        uint256 total;
        for (uint256 i; i < wallets.length; i++) {
            require(wallets[i] != address(0) && wallets[i] != address(this), "Bad addr");
            require(percentages[i] > 0 && percentages[i] <= BP, "Bad pct");
            total += percentages[i];
            require(total <= BP, "Overflow");
        }
        require(total == BP, "Total != 100%");
        // `delete` on a storage pointer to a dynamic array is illegal - use pop-loop.
        // Each removed treasury also loses its membership flag.
        uint256 existing = treasuries.length;
        for (uint256 k = existing; k > 0; k--) {
            treasuryWallet[treasuries[k - 1].wallet] = false;
            treasuries.pop();
        }
        for (uint256 i; i < wallets.length; i++) {
            require(!treasuryWallet[wallets[i]], "Dup addr");
            treasuryWallet[wallets[i]] = true;
            treasuries.push(Treasury({
                wallet: wallets[i],
                percentage: percentages[i],
                pendingWallet: address(0),
                pendingSince: 0
            }));
        }
        ts = block.timestamp;
        emit TreasuryUpdated(ts);
    }

    /**
     * @notice Propose a new wallet for the caller's treasury entry.
     */
    function proposeTreasuryWalletChange(Treasury[] storage treasuries, mapping(address => bool) storage treasuryWallet, address newWallet) external {
        require(newWallet != address(0), "Bad addr");
        require(!treasuryWallet[newWallet], "Already treasury");
        for (uint256 i; i < treasuries.length; i++) {
            if (treasuries[i].wallet == msg.sender) {
                treasuries[i].pendingWallet = newWallet;
                treasuries[i].pendingSince  = block.timestamp;
                emit TreasuryPendingChange(msg.sender, newWallet);
                return;
            }
        }
        revert("Not treasury");
    }

    /**
     * @notice Accept a pending treasury wallet change.
     * @dev Only after taxCollectionWaitingTime since the proposal, so the owner
     *      can react to a malicious change before the new wallet receives any
     *      tax. Other treasuries keep collecting meanwhile.
     */
    function acceptTreasuryWalletChange(
        Treasury[] storage treasuries,
        mapping(address => bool) storage treasuryWallet,
        uint256 taxCollectionWaitingTime
    ) external {
        require(!treasuryWallet[msg.sender], "Already treasury");
        for (uint256 i; i < treasuries.length; i++) {
            if (treasuries[i].pendingWallet == msg.sender) {
                require(block.timestamp >= treasuries[i].pendingSince + taxCollectionWaitingTime, "Too soon");
                address old = treasuries[i].wallet;
                treasuryWallet[old]        = false;
                treasuryWallet[msg.sender] = true;
                treasuries[i].wallet        = msg.sender;
                treasuries[i].pendingWallet = address(0);
                treasuries[i].pendingSince  = 0;
                emit TreasuryChangeAccepted(old, msg.sender);
                emit TreasuryUpdated(block.timestamp);
                return;
            }
        }
        revert("No pending change");
    }

    /**
     * @notice Cancel a pending treasury wallet change.
     */
    function cancelTreasuryWalletChange(Treasury[] storage treasuries) external {
        for (uint256 i; i < treasuries.length; i++) {
            if (treasuries[i].wallet == msg.sender && treasuries[i].pendingWallet != address(0)) {
                treasuries[i].pendingWallet = address(0);
                treasuries[i].pendingSince  = 0;
                emit TreasuryChangeCancelled(msg.sender);
                return;
            }
        }
        revert("Nothing to cancel");
    }

    // ─── Delegate Management ──────────────────────────────────────────────────

    /**
     * @notice Offer a delegate role to an address.
     * @dev An invitation can be accepted only within delegateInvitationWindow
     *      and while the owner that issued it (ownershipEpoch) is still the
     *      owner; otherwise it counts as expired everywhere.
     */
    function addDelegate(
        mapping(address => Delegate) storage delegates,
        address d,
        uint256 wv,
        address owner,
        uint256 maxDelegates,
        uint256 delegateListLen,
        uint256 delegateInvitationWindow,
        uint256 ownershipEpoch
    ) external {
        require(d != address(0) && d != owner, "Bad delegate");
        require(!delegates[d].isActive, "Exists");
        require(
            !delegates[d].isPending ||
            block.timestamp > delegates[d].pendingSince + delegateInvitationWindow ||
            delegates[d].inviteEpoch != ownershipEpoch,
            "Invite pending"
        );
        require(delegateListLen < maxDelegates, "Max reached");
        require(wv > 0 && wv <= MAX_WV, "Bad weight");
        delegates[d].isPending      = true;
        delegates[d].pendingSince   = block.timestamp;
        delegates[d].inviteEpoch    = ownershipEpoch;
        delegates[d].weightedVoting = wv;
        emit DelegateAdded(d, wv, block.timestamp);
    }

    /**
     * @notice Accept a pending delegate role and join the active pool.
     *
     * @dev Maintains the invariant that the sum of active delegates'
     *      weightedVoting equals 100 whenever at least two delegates are
     *      active. The rebalance happens here at acceptDelegate(), when a
     *      delegate actually joins the active pool.
     */
    function acceptDelegate(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage delegateList,
        uint256 delegateInvitationWindow,
        uint256 maxDelegates,
        uint256 ownershipEpoch
    ) external {
        require(delegates[msg.sender].isPending, "No pending role");
        require(block.timestamp <= delegates[msg.sender].pendingSince + delegateInvitationWindow, "Invite expired");
        require(delegates[msg.sender].inviteEpoch == ownershipEpoch, "Invite expired");
        require(delegateList.length < maxDelegates, "Max reached");
        uint256 newWv = delegates[msg.sender].weightedVoting;
        if (delegateList.length > 0) {
            // Make room for the newcomer; reverts only on the 1→2 transition
            // when the offered weight isn't exactly 50 (hard math limit).
            _rebalanceExistingToTarget(delegates, ownerCandidates, pendingNomination, delegateList, address(0), 100 - newWv);
        }
        delegates[msg.sender].isPending = false;
        delegates[msg.sender].pendingSince = 0;
        delegates[msg.sender].inviteEpoch = 0;
        delegates[msg.sender].isActive  = true;
        delegateList.push(msg.sender);
        emit DelegateAccepted(msg.sender, block.timestamp);
    }

    /**
     * @notice Update a delegate's voting weight.
     * @dev Only reachable through onlyOwnerAlive, which has already cleared
     *      every candidacy and vote, so no tally needs to follow the change.
     */
    function setDelegateWeight(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage delegateList,
        address d,
        uint256 newW
    ) external {
        require(delegates[d].isActive, "Not active");
        require(newW > 0 && newW <= MAX_WV, "Bad weight");
        uint256 old = delegates[d].weightedVoting;
        if (delegateList.length > 1) {
            // With ≥2 active delegates (this one plus at least one other),
            // every other active delegate absorbs the opposite change,
            // proportionally, so the total stays exactly 100.
            _rebalanceExistingToTarget(delegates, ownerCandidates, pendingNomination, delegateList, d, 100 - newW);
        }
        delegates[d].weightedVoting = newW;
        emit DelegateWeightUpdated(d, old, newW);
    }

    /**
     * @notice Remove a delegate from the roster.
     * @dev Only reachable through onlyOwnerAlive, which has already cleared
     *      every candidacy and vote, so there is no vote to retract.
     */
    function removeDelegate(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage delegateList,
        address d
    ) external {
        require(delegates[d].isActive || delegates[d].isPending, "Not found");
        bool wasActive = delegates[d].isActive;
        delete delegates[d];
        if (wasActive) {
            uint256 n = delegateList.length;
            for (uint256 i; i < n; i++) {
                if (delegateList[i] == d) {
                    delegateList[i] = delegateList[n - 1];
                    delegateList.pop();
                    break;
                }
            }
            if (delegateList.length >= 2) {
                // ≥2 remain: redistribute the removed weight proportionally,
                // capped at MAX_WV. Always feasible (headroom ≥ 100).
                _rebalanceExistingToTarget(delegates, ownerCandidates, pendingNomination, delegateList, address(0), 100);
            }
            // 0 or 1 remain: no total is enforced; any remaining delegate
            // simply keeps whatever weight they already had.
        }
        emit DelegateRemoved(d, block.timestamp);
    }

    // ─── Owner Election ───────────────────────────────────────────────────────

    /**
     * @notice Nominate a candidate for owner election.
     */
    function nominateOwnerCandidate(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage pendingNominationList,
        address candidate,
        bool ownerElected,
        bool startContractRecovery,
        uint256 lastOwnerActivityTimestamp,
        uint256 contractRecoveryStartWaitingTime,
        uint256 delegateInvitationWindow,
        uint256 ownershipEpoch
    ) external {
        require(!ownerElected && !startContractRecovery, "Bad state");
        require(block.timestamp >= lastOwnerActivityTimestamp + contractRecoveryStartWaitingTime, "Owner active");
        require(candidate != address(0), "Bad addr");
        require(
            !delegates[candidate].isActive &&
            (!delegates[candidate].isPending ||
             block.timestamp > delegates[candidate].pendingSince + delegateInvitationWindow ||
             delegates[candidate].inviteEpoch != ownershipEpoch),
            "Is delegate"
        );
        require(!pendingNomination[candidate], "Already nominated");
        require(ownerCandidates[candidate].candidate == address(0), "Active candidate");
        require(delegates[msg.sender].votedFor == address(0), "Already voted");
        pendingNomination[candidate]         = true;
        pendingNominationList.push(candidate);
        delegates[msg.sender].votedFor       = candidate;
        ownerCandidates[candidate].nominator = msg.sender;
        ownerCandidates[candidate].candidate = candidate;
        emit OwnerCandidateNominated(candidate, msg.sender, block.timestamp);
    }

    /**
     * @notice Accept an owner candidacy nomination.
     */
    function acceptOwnerCandidacy(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage pendingNominationList,
        address[] storage ownerCandidateList
    ) external {
        require(pendingNomination[msg.sender], "Not nominated");
        pendingNomination[msg.sender] = false;
        _removePendingNomination(pendingNominationList, msg.sender);
        address nom = ownerCandidates[msg.sender].nominator;
        ownerCandidates[msg.sender].totalVotes = delegates[nom].weightedVoting;
        ownerCandidateList.push(msg.sender);
        emit OwnerCandidateAccepted(msg.sender, block.timestamp);
    }

    /**
     * @notice Vote for an active owner candidate.
     * @return elected  Whether the election threshold was crossed.
     */
    function voteForOwnerCandidate(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address candidate,
        bool ownerElected
    ) external returns (bool elected) {
        require(!ownerElected, "Already elected");
        require(
            ownerCandidates[candidate].candidate == candidate && !pendingNomination[candidate],
            "Not active"
        );
        require(delegates[msg.sender].votedFor == address(0), "Already voted");
        delegates[msg.sender].votedFor          = candidate;
        ownerCandidates[candidate].totalVotes  += delegates[msg.sender].weightedVoting;
        uint256 votes = ownerCandidates[candidate].totalVotes;
        elected = votes >= ELEC_THRESH;
        emit OwnerCandidateVoted(candidate, msg.sender, delegates[msg.sender].weightedVoting, votes);
        if (elected) emit OwnerElectChosen(candidate, votes, block.timestamp);
    }

    /**
     * @notice Cancel an owner candidacy (only the nominator may do so).
     */
    function cancelOwnerCandidacy(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage pendingNominationList,
        address[] storage ownerCandidateList,
        address[] storage delegateList,
        address candidate
    ) external {
        require(ownerCandidates[candidate].nominator == msg.sender, "Not nominator");
        _deleteCandidate(delegates, ownerCandidates, pendingNomination, pendingNominationList, ownerCandidateList, delegateList, candidate);
        emit OwnerCandidateCancelled(candidate, msg.sender, block.timestamp);
    }

    // ─── Contract Recovery ────────────────────────────────────────────────────

    /**
     * @notice Start the contract recovery process.
     * @return ts Timestamp of the start.
     */
    function startContractRecoveryProcess(
        bool startContractRecovery_,
        bool ownerElected,
        uint256 lastOwnerActivityTimestamp,
        uint256 contractRecoveryStartWaitingTime
    ) external returns (uint256 ts) {
        require(!startContractRecovery_ && ownerElected, "Bad state");
        require(block.timestamp >= lastOwnerActivityTimestamp + contractRecoveryStartWaitingTime, "Owner active");
        ts = block.timestamp;
        emit ContractRecoveryStarted(msg.sender, ts);
    }

    /**
     * @notice Execute the contract recovery process.
     * @return newOwner The new owner address.
     */
    function executeContractRecovery(
        bool startContractRecovery_,
        bool ownerElected,
        uint256 startContractRecoveryTimestamp,
        uint256 contractRecoveryWaitingTime,
        address ownerElect
    ) external returns (address newOwner) {
        require(startContractRecovery_ && ownerElected, "Bad state");
        require(block.timestamp >= startContractRecoveryTimestamp + contractRecoveryWaitingTime, "Too soon");
        newOwner = ownerElect;
        emit ContractRecoveryExecuted(newOwner, block.timestamp);
    }

    /**
     * @notice Initiate a quorum call after a period of owner inactivity.
     */
    function initiateOwnerQuorumCall(
        mapping(address => Delegate) storage delegates,
        mapping(address => bool) storage presentConfirmed,
        address[] storage presentList,
        bool quorumCallActive_,
        bool ownerElected,
        bool startContractRecovery_,
        uint256 lastOwnerActivityTimestamp,
        uint256 quorumInactivityPeriod,
        address caller
    ) external {
        require(delegates[caller].isActive, "Not delegate");
        require(!ownerElected && !startContractRecovery_, "Bad state");
        require(!quorumCallActive_, "Already active");
        require(block.timestamp >= lastOwnerActivityTimestamp + quorumInactivityPeriod, "Owner active");
        presentConfirmed[caller] = true;
        presentList.push(caller);
        emit QuorumCallInitiated(caller, block.timestamp);
        emit PresentConfirmed(caller, block.timestamp);
    }

    /**
     * @notice Confirm the caller is still present during a quorum roll-call.
     * @return allPresent  True if every active delegate confirmed → caller
     *                      should cancel the quorum call.
     */
    function confirmOwnerPresent(
        mapping(address => Delegate) storage delegates,
        mapping(address => bool) storage presentConfirmed,
        address[] storage presentList,
        bool quorumCallActive_,
        uint256 quorumCallTimestamp,
        uint256 quorumRollcallWindow,
        uint256 delegateCount,
        address caller
    ) external returns (bool allPresent) {
        require(delegates[caller].isActive, "Not delegate");
        require(quorumCallActive_, "No quorum call");
        require(!presentConfirmed[caller], "Already confirmed");
        require(block.timestamp < quorumCallTimestamp + quorumRollcallWindow, "Roll-call closed");
        presentConfirmed[caller] = true;
        presentList.push(caller);
        emit PresentConfirmed(caller, block.timestamp);
        allPresent = (presentList.length == delegateCount);
        if (allPresent) emit QuorumCallCancelled(block.timestamp);
    }

    /**
     * @notice After the roll-call window closes, resolve the quorum call.
     * @return soloSurvivor  Non-zero only when exactly one delegate responded
     *                        -> caller should transfer ownership to them directly.
     */
    function executeOwnerQuorate(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage delegateList,
        mapping(address => bool) storage presentConfirmed,
        address[] storage presentList,
        bool quorumCallActive_,
        uint256 quorumCallTimestamp,
        uint256 quorumRollcallWindow,
        address caller
    ) external returns (address soloSurvivor) {
        require(delegates[caller].isActive, "Not delegate");
        require(quorumCallActive_, "No quorum call");
        require(block.timestamp >= quorumCallTimestamp + quorumRollcallWindow, "Roll-call still open");
        require(presentConfirmed[caller], "Not present");

        uint256 pCount = presentList.length;

        if (pCount == 1) {
            soloSurvivor = presentList[0];
            emit EmergencySingleOwnerElect(soloSurvivor, block.timestamp);
            return soloSurvivor;
        }

        _redistributeDelegateWV(delegates, ownerCandidates, pendingNomination, delegateList, presentConfirmed);
        emit OwnerQuorateExecuted(pCount, block.timestamp);
    }

    /// @notice Wipe every delegate and clear roll-call bookkeeping.
    /// @dev Used only by the sole-survivor path of quorate()
    function settleSoloSurvivorQuorum(
        mapping(address => Delegate) storage delegates,
        address[] storage delegateList,
        mapping(address => bool) storage presentConfirmed,
        address[] storage presentList
    ) external {
        uint256 n = delegateList.length;
        for (uint256 i; i < n; i++) delete delegates[delegateList[i]];
        for (uint256 i = delegateList.length; i > 0; i--) delegateList.pop();
        uint256 pn = presentList.length;
        for (uint256 i; i < pn; i++) delete presentConfirmed[presentList[i]];
        for (uint256 i = presentList.length; i > 0; i--) presentList.pop();
    }

    /// @notice Clear roll-call bookkeeping after a quorum call ends.
    /// @dev Caller resets the active/timestamp/initiator flags itself since
    ///      those are plain value types.
    function clearQuorumCall(
        mapping(address => bool) storage presentConfirmed,
        address[] storage presentList
    ) external {
        uint256 n = presentList.length;
        for (uint256 i; i < n; i++) delete presentConfirmed[presentList[i]];
        for (uint256 i = presentList.length; i > 0; i--) presentList.pop();
    }

    /**
     * @dev Drops absent delegates and redistributes their weight to the
     *      present ones, capped at MAX_WV. Tolerates leftover (best-effort)
     *      since this runs only in an emergency quorum rescue.
     */
    function _redistributeDelegateWV(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage delegateList,
        mapping(address => bool) storage presentConfirmed
    ) private {
        uint256 absentWV = _removeAbsentDelegates(delegates, delegateList, presentConfirmed);
        _distributeAmong(delegates, ownerCandidates, pendingNomination, delegateList, address(0), absentWV); // leftover tolerated
    }

    /// @dev Sums the WV of every absent delegate and drops it from the roster.
    ///      quorate() clears every candidacy and vote beforehand, so there is
    ///      no vote to retract.
    function _removeAbsentDelegates(
        mapping(address => Delegate) storage delegates,
        address[] storage delegateList,
        mapping(address => bool) storage presentConfirmed
    ) private returns (uint256 absentWV) {
        uint256 dl = delegateList.length;
        for (uint256 i; i < dl; i++) {
            address d = delegateList[i];
            if (!presentConfirmed[d]) {
                absentWV += delegates[d].weightedVoting;
            }
        }
        for (uint256 i; i < delegateList.length; ) {
            if (!presentConfirmed[delegateList[i]]) {
                delete delegates[delegateList[i]];
                delegateList[i] = delegateList[delegateList.length - 1];
                delegateList.pop();
            } else {
                i++;
            }
        }
    }

    /// @dev Grows or shrinks `list` (minus `skip`) to sum exactly `targetTotal`.
    ///      Reverts if growth can't be placed without breaching MAX_WV, or if
    ///      shrinking would leave a delegate below 1 (targetTotal smaller than
    ///      the number of delegates, unreachable while maxDelegates <= 50).
    function _rebalanceExistingToTarget(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage list,
        address skip,
        uint256 targetTotal
    ) private {
        uint256 n = list.length;
        uint256 currentTotal;
        for (uint256 i; i < n; i++) {
            if (list[i] != skip) currentTotal += delegates[list[i]].weightedVoting;
        }
        if (targetTotal >= currentTotal) {
            uint256 leftover = _distributeAmong(delegates, ownerCandidates, pendingNomination, list, skip, targetTotal - currentTotal);
            require(leftover == 0, "Cannot balance to 100");
        } else {
            _scaleDown(delegates, ownerCandidates, pendingNomination, list, skip, targetTotal);
        }
    }

    /// @dev Proportionally scales `list` (minus `skip`) DOWN to `targetTotal`.
    ///      Removes (currentTotal - targetTotal) in proportion to each delegate's
    ///      weight above 1, so every delegate keeps at least 1 and no delegate
    ///      ever grows (so none can exceed MAX_WV). Rounding leftovers are taken
    ///      one unit at a time from delegates that can still give one.
    ///      Keeps each delegate's live vote (if any) in sync with the change.
    function _scaleDown(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage list,
        address skip,
        uint256 targetTotal
    ) private {
        uint256 n = list.length;
        uint256 currentTotal;
        uint256 reducible;
        for (uint256 i; i < n; i++) {
            if (list[i] == skip) continue;
            uint256 w = delegates[list[i]].weightedVoting;
            currentTotal += w;
            reducible += w - 1;
        }
        uint256 toRemove = currentTotal - targetTotal;
        require(toRemove <= reducible, "Cannot balance to 100");

        uint256[] memory newW = new uint256[](n);
        uint256 removed;
        for (uint256 i; i < n; i++) {
            if (list[i] == skip) continue;
            uint256 w = delegates[list[i]].weightedVoting;
            uint256 cut = (toRemove * (w - 1)) / reducible;
            newW[i] = w - cut;
            removed += cut;
        }
        // Rounding leftover: take one unit from each delegate that can still give one.
        for (uint256 i; i < n && removed < toRemove; i++) {
            if (list[i] == skip || newW[i] <= 1) continue;
            newW[i] -= 1;
            removed += 1;
        }
        require(removed == toRemove, "Cannot balance to 100");

        for (uint256 i; i < n; i++) {
            address d = list[i];
            if (d == skip) continue;
            uint256 w = delegates[d].weightedVoting;
            if (newW[i] != w) {
                delegates[d].weightedVoting = newW[i];
                address vf = delegates[d].votedFor;
                if (_isLiveVote(ownerCandidates, pendingNomination, vf)) {
                    ownerCandidates[vf].totalVotes = ownerCandidates[vf].totalVotes - w + newW[i];
                }
            }
        }
    }

    /// @dev Proportionally grows `list` (minus `skip`) by `amount`, never
    ///      pushing anyone past MAX_WV; excludes anyone already at MAX_WV
    ///      from every round. Returns whatever could not be placed (0 when
    ///      the caller's aggregate headroom was sufficient).
    function _distributeAmong(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage list,
        address skip,
        uint256 amount
    ) private returns (uint256 remaining) {
        uint256 n = list.length;
        remaining = amount;
        for (uint256 round; remaining > 0 && round < n; round++) {
            uint256 distributedThisRound = _distributeDelegateRound(delegates, ownerCandidates, pendingNomination, list, skip, n, remaining);
            if (distributedThisRound == 0) break;
            remaining -= distributedThisRound;
        }
    }

    /// @dev One growth round: shares `remaining` among `list` (minus `skip`)
    ///      that are below MAX_WV, proportional to current weight, clamped to
    ///      headroom, keeping any live vote's totalVotes in sync.
    function _distributeDelegateRound(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage list,
        address skip,
        uint256 n,
        uint256 remaining
    ) private returns (uint256 distributedThisRound) {
        uint256 eligibleWV;
        uint256 lastEligibleIdx = type(uint256).max;
        for (uint256 i; i < n; i++) {
            address d = list[i];
            if (d == skip) continue;
            uint256 w = delegates[d].weightedVoting;
            if (w < MAX_WV) { eligibleWV += w; lastEligibleIdx = i; }
        }
        if (eligibleWV == 0) return 0;

        for (uint256 i; i < n; i++) {
            address d = list[i];
            if (d == skip) continue;
            uint256 w = delegates[d].weightedVoting;
            if (w >= MAX_WV) continue;
            uint256 headroom = MAX_WV - w;
            uint256 share = (i == lastEligibleIdx)
                ? remaining - distributedThisRound
                : (remaining * w) / eligibleWV;
            if (share > headroom) share = headroom;
            if (share > 0) {
                delegates[d].weightedVoting = w + share;
                address vf = delegates[d].votedFor;
                if (_isLiveVote(ownerCandidates, pendingNomination, vf)) {
                    ownerCandidates[vf].totalVotes += share;
                }
                distributedThisRound += share;
            }
        }
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @dev True when `vf` is an accepted candidate whose tally must follow weight
    ///      changes. Pending nominations are excluded: their totalVotes is set when
    ///      the nominee accepts (acceptOwnerCandidacy).
    function _isLiveVote(
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address vf
    ) private view returns (bool) {
        return vf != address(0) && ownerCandidates[vf].candidate == vf && !pendingNomination[vf];
    }

    /**
     * @dev Removes `candidate` from the pending-nomination list, if present.
     *      Swap-and-pop; order is not significant.
     */
    function _removePendingNomination(
        address[] storage pendingNominationList,
        address candidate
    ) internal {
        uint256 n = pendingNominationList.length;
        for (uint256 i; i < n; i++) {
            if (pendingNominationList[i] == candidate) {
                pendingNominationList[i] = pendingNominationList[n - 1];
                pendingNominationList.pop();
                break;
            }
        }
    }

    /// @dev Removes a candidate and clears every delegate's vote for it.
    function _deleteCandidate(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage pendingNominationList,
        address[] storage ownerCandidateList,
        address[] storage delegateList,
        address candidate
    ) internal {
        uint256 n = delegateList.length;
        for (uint256 i; i < n; i++) {
            if (delegates[delegateList[i]].votedFor == candidate) {
                delegates[delegateList[i]].votedFor = address(0);
            }
        }
        uint256 m = ownerCandidateList.length;
        for (uint256 i; i < m; i++) {
            if (ownerCandidateList[i] == candidate) {
                ownerCandidateList[i] = ownerCandidateList[m - 1];
                ownerCandidateList.pop();
                break;
            }
        }
        delete ownerCandidates[candidate];
        delete pendingNomination[candidate];
        _removePendingNomination(pendingNominationList, candidate);
    }

    /**
     * @notice Clear all owner candidates and reset every delegate's vote.
     */
    function clearCandidates(
        mapping(address => Delegate) storage delegates,
        mapping(address => OwnerCandidateRecord) storage ownerCandidates,
        mapping(address => bool) storage pendingNomination,
        address[] storage pendingNominationList,
        address[] storage ownerCandidateList,
        address[] storage delegateList
    ) external {
        uint256 n = delegateList.length;
        for (uint256 i; i < n; i++) delegates[delegateList[i]].votedFor = address(0);
        uint256 m = ownerCandidateList.length;
        for (uint256 i; i < m; i++) {
            address c = ownerCandidateList[i];
            delete ownerCandidates[c];
            delete pendingNomination[c];
        }
        uint256 q = pendingNominationList.length;
        for (uint256 i; i < q; i++) {
            address pc = pendingNominationList[i];
            delete ownerCandidates[pc];
            delete pendingNomination[pc];
        }
        for (uint256 i = q; i > 0; i--) pendingNominationList.pop();
        // `delete` on a storage pointer to a dynamic array is illegal - use pop-loop.
        uint256 p = ownerCandidateList.length;
        for (uint256 i = p; i > 0; i--) ownerCandidateList.pop();
    }
}
