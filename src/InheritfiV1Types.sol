// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

/**
 * @title INHERITFI V1 Types
 * @notice Storage structs shared by InheritfiV1Base, InheritfiV1InheritanceLib and
 *         InheritfiV1GovernanceLib. Defined once so that the contract and the libraries
 *         always agree on the storage layout (audit finding M-12).
 * @author INHERITFI ( https://inheritfi.com / inheritfi.eth )
 */

struct Heir {
    address wallet;
    uint256 percentage;
    uint256 inheritanceReleased;
}

struct UserData {
    uint256 totalReceived;
    uint256 totalSent;
    uint256 totalRecoveryRelease;
    uint256 totalInheritanceRelease;
    uint256 totalInheritanceRemainingRelease;
    uint256 inheritanceClaimedPct;
    uint256 activityTimestamp;
    Heir[]  heirs;
    mapping(address => uint256) heirIndex;
    address[] recoveryUsers;
    mapping(address => bool) isRecoveryUser;
    bool    startInheritance;
    uint256 startInheritanceTimestamp;
    mapping(address => bool) heirReceivedInheritance;
    address[] heirsWhoReceived;
    bool    inheritanceClaimsClosed;
    bool    startRecovery;
    uint256 startRecoveryTimestamp;
}

struct Treasury {
    address wallet;
    uint256 percentage;
    address pendingWallet;
    uint256 pendingSince;
}

struct Delegate {
    bool    isActive;
    bool    isPending;
    uint256 weightedVoting;
    address votedFor;
    uint256 pendingSince;
    uint256 inviteEpoch;
}

struct OwnerCandidateRecord {
    address candidate;
    uint256 totalVotes;
    address nominator;
}
