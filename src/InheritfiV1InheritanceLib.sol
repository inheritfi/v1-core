// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "./InheritfiV1Types.sol";

/**
 * @title INHERITFI V1 Inheritance Lib
 * @notice External library containing the heavy inheritance and recovery logic
 *         extracted from InheritfiV1Base to reduce deployed contract bytecode size.
 * @author INHERITFI ( https://inheritfi.com / inheritfi.eth )
 *
 * External library functions are deployed once and called via DELEGATECALL,
 * reducing the consuming contract's bytecode below EIP-170 / EIP-3860 limits.
 */
library InheritfiV1InheritanceLib {

    // ─── Shared constants (must mirror InheritfiV1Base) ───────────────────────
    uint256 internal constant BP = 10_000;

    // ─── Events (must match InheritfiV1Base exactly) ──────────────────────────
    event HeirsUpdated(address indexed testator, uint256 count);
    event RecoveryUsersUpdated(address indexed testator, uint256 count);
    event InheritanceStarted(address indexed testator, address indexed initiator, uint256 ts);
    event InheritanceExecuted(address indexed testator, address indexed heir, uint256 amount, uint256 tax);
    event InheritanceRemainingExecuted(address indexed testator, address indexed heir, uint256 amount, uint256 tax);
    event RecoveryStarted(address indexed testator, address indexed initiator, uint256 ts);
    event RecoveryExecuted(address indexed testator, address indexed ru, uint256 amount, uint256 tax);
    event ActivityChecked(address indexed user, uint256 ts);

    // ─── Heir Management ──────────────────────────────────────────────────────

    /**
     * @notice Replace a testator's heir list atomically.
     * @dev Called via DELEGATECALL so `userData` lives in the calling contract's
     *      storage; `msg.sender` is the testator.
     */
    function setHeirs(
        mapping(address => UserData) storage userData,
        address[] memory wallets,
        uint256[] memory percentages,
        uint256 maxHeirs
    ) external {
        require(wallets.length == percentages.length && wallets.length > 0, "Bad input");
        require(wallets.length <= maxHeirs, "Too many heirs");
        UserData storage user = userData[msg.sender];
        require(!user.startInheritance && !user.startRecovery, "Process active");

        // Clear old heirs
        uint256 n = user.heirs.length;
        for (uint256 i; i < n; i++) delete user.heirIndex[user.heirs[i].wallet];
        delete user.heirs;

        uint256 total;
        for (uint256 i; i < wallets.length; i++) {
            address w = wallets[i];
            uint256 p = percentages[i];
            require(w != address(0) && w != msg.sender, "Bad heir");
            require(p > 0 && p <= BP, "Bad pct");
            require(user.heirIndex[w] == 0, "Dup heir");
            total += p;
            require(total <= BP, "Overflow");
            user.heirs.push();
            uint256 idx = user.heirs.length - 1;
            user.heirs[idx].wallet     = w;
            user.heirs[idx].percentage = p;
            user.heirIndex[w]          = idx + 1;
        }
        require(total == BP, "Total != 100%");
        user.activityTimestamp = block.timestamp;
        emit HeirsUpdated(msg.sender, wallets.length);
    }

    // ─── Recovery User Management ─────────────────────────────────────────────

    /**
     * @notice Replace a testator's recovery user list atomically.
     */
    function setRecoveryUsers(
        mapping(address => UserData) storage userData,
        address[] calldata wallets,
        uint256 maxRecoveryUsers
    ) external {
        require(wallets.length > 0 && wallets.length <= maxRecoveryUsers, "Bad count");
        UserData storage user = userData[msg.sender];
        require(!user.startInheritance && !user.startRecovery, "Process active");

        uint256 n = user.recoveryUsers.length;
        for (uint256 i; i < n; i++) delete user.isRecoveryUser[user.recoveryUsers[i]];
        delete user.recoveryUsers;

        for (uint256 i; i < wallets.length; i++) {
            address w = wallets[i];
            require(w != address(0) && w != msg.sender, "Bad addr");
            require(!user.isRecoveryUser[w], "Dup");
            user.recoveryUsers.push(w);
            user.isRecoveryUser[w] = true;
        }
        user.activityTimestamp = block.timestamp;
        emit RecoveryUsersUpdated(msg.sender, wallets.length);
    }

    // ─── Inheritance Process ──────────────────────────────────────────────────

    /**
     * @notice Start the inheritance process for a testator after inactivity.
     */
    function startInheritance(
        mapping(address => UserData) storage userData,
        address testator,
        address initiator,
        uint256 balance,
        uint256 inheritInactivityPeriod,
        uint256 recoveryExecutionWindow
    ) external {
        UserData storage user = userData[testator];
        require(!user.startInheritance, "Process active");
        if (user.startRecovery) {
            require(
                block.timestamp >= user.startRecoveryTimestamp + recoveryExecutionWindow,
                "Process active"
            );
            user.startRecovery          = false;
            user.startRecoveryTimestamp = 0;
        }
        require(block.timestamp >= user.activityTimestamp + inheritInactivityPeriod, "Too soon");
        require(balance > 0, "No balance");
        user.startInheritance          = true;
        user.startInheritanceTimestamp = block.timestamp;
        emit InheritanceStarted(testator, initiator, block.timestamp);
    }

    /**
     * @notice Compute an heir's share and update inheritance state.
     * @return tax   Amount to move to the treasury.
     * @return net   Amount to transfer to the heir.
     *
     * @dev Pays from the current balance: share = balance * pct / pct of heirs
     *      still unclaimed (this heir included). The last heir gets the whole
     *      balance. A zero share is paid and still marks the heir as claimed.
     */
    function executeInheritance(
        mapping(address => UserData) storage userData,
        address testator,
        address heir,
        uint256 testatorBalance,
        uint256 inheritWaitingTime,
        uint256 inheritanceTax
    ) external returns (uint256 tax, uint256 net) {
        UserData storage user = userData[testator];
        require(user.startInheritance, "Not started");
        require(!user.heirReceivedInheritance[heir], "Already claimed");
        require(!user.inheritanceClaimsClosed, "Claims closed");
        require(block.timestamp >= user.startInheritanceTimestamp + inheritWaitingTime, "Too soon");

        Heir storage h = user.heirs[user.heirIndex[heir] - 1];
        // Pro rata over the current balance among heirs who haven't claimed yet
        // (this heir included); the last one gets the whole balance.
        uint256 share = (testatorBalance * h.percentage) / (BP - user.inheritanceClaimedPct);

        tax = (share * inheritanceTax) / BP;
        net = share - tax;

        h.inheritanceReleased              += share;
        user.totalInheritanceRelease       += share;
        user.inheritanceClaimedPct         += h.percentage;
        user.heirReceivedInheritance[heir]  = true;
        user.heirsWhoReceived.push(heir);

        emit InheritanceExecuted(testator, heir, net, tax);
    }

    /**
     * @notice Distribute leftover balance to heirs who already claimed.
     * @dev Returns parallel arrays (recipient, tax, net) for the caller to
     *      execute transfers. Per-heir logic is in _processRemainingShare to
     *      avoid "Stack too deep".
     */
    function executeInheritanceRemaining(
        mapping(address => UserData) storage userData,
        address testator,
        uint256 testatorBalance,
        uint256 inheritWaitingTime,
        uint256 inheritRemainingWaitingTime,
        uint256 inheritanceTax
    ) external returns (
        address[] memory recipients,
        uint256[] memory taxes,
        uint256[] memory nets
    ) {
        UserData storage user = userData[testator];
        require(user.heirReceivedInheritance[msg.sender], "Not claimed yet");
        require(user.startInheritance, "Not started");
        require(
            block.timestamp >= user.startInheritanceTimestamp + inheritWaitingTime + inheritRemainingWaitingTime,
            "Too soon"
        );

        uint256 claimCount = user.heirsWhoReceived.length;
        require(testatorBalance > 0, "No balance");
        user.inheritanceClaimsClosed = true;

        uint256 totalPct;
        for (uint256 i; i < claimCount; i++) {
            totalPct += user.heirs[user.heirIndex[user.heirsWhoReceived[i]] - 1].percentage;
        }

        recipients = new address[](claimCount);
        taxes      = new uint256[](claimCount);
        nets       = new uint256[](claimCount);

        // Delegate per-heir body to avoid "Stack too deep". Same rule as collectTax:
        // shares are proportional and rounded down, and the last heir who claimed also
        // takes the rounding residue, so the testator's balance is fully distributed (B-05).
        uint256 distributed;
        for (uint256 i; i < claimCount; i++) {
            uint256 share = i == claimCount - 1
                ? testatorBalance - distributed
                : (testatorBalance * user.heirs[user.heirIndex[user.heirsWhoReceived[i]] - 1].percentage) / totalPct;
            distributed += share;
            _processRemainingShare(
                user,
                testator,
                i,
                share,
                inheritanceTax,
                recipients,
                taxes,
                nets
            );
        }
    }

    /**
     * @dev Processes one heir's remaining-inheritance share (avoids stack too deep).
     *
     * @param user          Storage pointer to the testator's UserData.
     * @param testator      Address of the testator (used only for the event).
     * @param i             Current loop index.
     * @param share         Gross share computed by the caller (see executeInheritanceRemaining).
     * @param inheritanceTax Tax rate in basis points.
     * @param recipients    Output array: heir addresses.
     * @param taxes         Output array: tax amounts per heir.
     * @param nets          Output array: net amounts per heir.
     *
     * @dev The caller gives the last heir who claimed the rounding residue (B-05),
     *      so the testator's whole balance is distributed and never exceeded.
     */
    function _processRemainingShare(
        UserData storage user,
        address testator,
        uint256 i,
        uint256 share,
        uint256 inheritanceTax,
        address[] memory recipients,
        uint256[] memory taxes,
        uint256[] memory nets
    ) private {
        address ha     = user.heirsWhoReceived[i];
        Heir storage h = user.heirs[user.heirIndex[ha] - 1];

        if (share > 0) {
            uint256 t  = (share * inheritanceTax) / BP;
            uint256 n_ = share - t;
            h.inheritanceReleased                 += share;
            user.totalInheritanceRemainingRelease += share;
            recipients[i] = ha;
            taxes[i]      = t;
            nets[i]       = n_;
            emit InheritanceRemainingExecuted(testator, ha, n_, t);
        }
    }

    /**
     * @notice Net amounts an heir would receive, mirroring the payout logic.
     * @return potential          executeInheritance share, net of tax, computed
     *                            from the current balance exactly as executeInheritance
     *                            does. 0 if already claimed or
     *                            if claims are closed. With no inheritance process
     *                            active, it is the share the heir would get if one
     *                            started now with the current balance.
     * @return potentialRemaining executeInheritanceRemaining share, net of tax.
     *                            0 unless the heir already claimed and the
     *                            remaining window is open.
     */
    function heirPotentials(
        mapping(address => UserData) storage userData,
        address testator,
        address heir,
        uint256 testatorBalance,
        uint256 inheritWaitingTime,
        uint256 inheritRemainingWaitingTime,
        uint256 inheritanceTax
    ) external view returns (uint256 potential, uint256 potentialRemaining) {
        UserData storage user = userData[testator];
        Heir storage h = user.heirs[user.heirIndex[heir] - 1];
        bool received = user.heirReceivedInheritance[heir];

        uint256 gross;
        if (!received && !user.inheritanceClaimsClosed) {
            gross = (testatorBalance * h.percentage) / (BP - user.inheritanceClaimedPct);
        }
        potential = gross - (gross * inheritanceTax) / BP;

        if (
            user.startInheritance && received &&
            block.timestamp >= user.startInheritanceTimestamp + inheritWaitingTime + inheritRemainingWaitingTime
        ) {
            uint256 totalPct;
            uint256 n = user.heirsWhoReceived.length;
            for (uint256 i; i < n; i++) {
                totalPct += user.heirs[user.heirIndex[user.heirsWhoReceived[i]] - 1].percentage;
            }
            uint256 distributed;
            for (uint256 i; i < n; i++) {
                address a = user.heirsWhoReceived[i];
                uint256 s = i == n - 1
                    ? testatorBalance - distributed
                    : (testatorBalance * user.heirs[user.heirIndex[a] - 1].percentage) / totalPct;
                if (a == heir) {
                    potentialRemaining = s - (s * inheritanceTax) / BP;
                    break;
                }
                distributed += s;
            }
        }
    }

    // ─── Recovery Process ─────────────────────────────────────────────────────

    /**
     * @notice Start the recovery process for a testator after inactivity.
     */
    function startRecovery(
        mapping(address => UserData) storage userData,
        address testator,
        address initiator,
        uint256 recoveryInactivityPeriod
    ) external {
        UserData storage user = userData[testator];
        require(!user.startRecovery, "Already started");
        require(block.timestamp >= user.activityTimestamp + recoveryInactivityPeriod, "Too soon");
        // Disarm the inheritance but keep its claim marks: if this recovery is
        // abandoned and the heirs resume it (AUD2-03), heirs who already claimed
        // cannot claim again and the split continues where it stopped.
        user.startInheritance          = false;
        user.startInheritanceTimestamp = 0;
        user.startRecovery          = true;
        user.startRecoveryTimestamp = block.timestamp;
        emit RecoveryStarted(testator, initiator, block.timestamp);
    }

    /**
     * @notice Validate recovery conditions and update state.
     * @return tax  Amount to collect.
     * @return net  Amount to transfer to recovery user.
     */
    function executeRecovery(
        mapping(address => UserData) storage userData,
        address testator,
        address recoveryUser,
        uint256 balance,
        uint256 recoveryWaitingTime,
        uint256 recoveryTax
    ) external returns (uint256 tax, uint256 net) {
        UserData storage user = userData[testator];
        require(user.startRecovery, "Not started");
        require(block.timestamp >= user.startRecoveryTimestamp + recoveryWaitingTime, "Too soon");
        require(balance > 0, "No balance");

        tax = (balance * recoveryTax) / BP;
        net = balance - tax;

        user.totalRecoveryRelease            += balance;
        userData[recoveryUser].totalReceived += net;
        user.startRecovery          = false;
        user.startRecoveryTimestamp = 0;
        // The whole balance left with the recovery: a later inheritance starts afresh.
        _clearInheritance(user);

        emit RecoveryExecuted(testator, recoveryUser, net, tax);
    }

    // ─── Activity Check ───────────────────────────────────────────────────────

    /**
     * @notice Update the caller's activity timestamp and clear any active processes.
     */
    function checkActivity(mapping(address => UserData) storage userData) external {
        UserData storage user = userData[msg.sender];
        user.activityTimestamp = block.timestamp;
        // Claim marks may also survive in a recovery armed over a cancelled inheritance.
        if (user.startInheritance || user.startRecovery) _clearInheritance(user);
        if (user.startRecovery) {
            user.startRecovery          = false;
            user.startRecoveryTimestamp = 0;
        }
        emit ActivityChecked(msg.sender, block.timestamp);
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /// @dev Resets all inheritance state for a user.
    function _clearInheritance(UserData storage user) private {
        user.startInheritance          = false;
        user.startInheritanceTimestamp = 0;
        user.inheritanceClaimedPct     = 0;
        user.inheritanceClaimsClosed   = false;
        uint256 n = user.heirsWhoReceived.length;
        for (uint256 i; i < n; i++) delete user.heirReceivedInheritance[user.heirsWhoReceived[i]];
        delete user.heirsWhoReceived;
    }
}
