// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { StakeVault } from "../../contracts/v2/StakeVault.sol";
import { EvidenceRegistry } from "../../contracts/v2/EvidenceRegistry.sol";
import { IStakeCustody } from "../../contracts/v2/interfaces/IStakeCustody.sol";
import { IModuleRegistry } from "../../contracts/v2/interfaces/IModuleRegistry.sol";
import { IV2Types } from "../../contracts/v2/interfaces/IV2Types.sol";
import { V2EventCompleteness } from "../../contracts/v2/libraries/V2EventCompleteness.sol";
import { IClaimRegistry } from "../../contracts/interfaces/IClaimRegistry.sol";
import { MockERC20 } from "../../contracts/MockERC20.sol";
import { MockEvidenceClaimRegistry } from "../../contracts/mocks/MockEvidenceClaimRegistry.sol";

/// @title LogProjection
/// @notice Reference indexer for the V2-SC-132 catalogue. Reconstructs every
///         authoritative read cell of `StakeVault` and `EvidenceRegistry` from
///         the ordered log stream alone — no storage reads, no `eth_call`s.
/// @dev Intentionally imports nothing from the protocol: a real consumer has
///      only logs. Every branch is one published closing event, and the cells a
///      branch deliberately does *not* touch are named in comments, because
///      touching them would double-count a restatement.
contract LogProjection {
    error ProjectionUnderflow(bytes32 topic0, uint256 available, uint256 requested);

    bytes32 internal constant T_SUPPORTED_ASSET_UPDATED =
        keccak256("SupportedAssetUpdated(address,bool,address,uint64,uint16)");
    bytes32 internal constant T_LOCK_MUTATOR_UPDATED =
        keccak256("LockMutatorUpdated(address,bool,address,uint64,uint16)");
    bytes32 internal constant T_VAULT_DEPOSITED = keccak256("VaultDeposited(address,address,uint256)");
    bytes32 internal constant T_VAULT_LOCKED = keccak256("VaultLocked(address,address,uint256,uint256,uint8,uint256)");
    bytes32 internal constant T_VAULT_UNLOCKED =
        keccak256("VaultUnlocked(address,address,uint256,uint256,uint8,uint256)");
    bytes32 internal constant T_VAULT_WITHDRAWN = keccak256("VaultWithdrawn(address,address,uint256)");
    bytes32 internal constant T_VAULT_SLASHED =
        keccak256("VaultSlashed(address,address,uint256,uint256,uint8,uint256,bytes32,uint64,uint16)");
    bytes32 internal constant T_VAULT_SETTLED_CONCLUSIVE =
        keccak256("VaultSettledConclusive(address,address,uint256,uint256,uint256,uint256,uint64,uint16)");
    bytes32 internal constant T_VAULT_REFUNDED_INCONCLUSIVE =
        keccak256("VaultRefundedInconclusive(address,address,uint256,uint256,uint256,uint64,uint16)");
    bytes32 internal constant T_VAULT_CARRIED_FORWARD =
        keccak256("VaultCarriedForward(address,address,uint256,uint256,uint256,uint256,uint64,uint16)");
    bytes32 internal constant T_VAULT_ROLLED_OVER =
        keccak256("VaultRolledOver(address,address,uint256,uint256,uint256,uint256,uint64,uint16)");
    bytes32 internal constant T_VAULT_FINAL_UNLOCKED =
        keccak256("VaultFinalUnlocked(address,address,uint256,uint256,uint256,uint64,uint16)");
    bytes32 internal constant T_STAKE_DEPOSITED = keccak256("StakeDeposited(address,uint256,uint256,uint64,uint16)");
    bytes32 internal constant T_STAKE_RELEASED = keccak256("StakeReleased(address,uint256,uint256,uint64,uint16)");
    bytes32 internal constant T_STAKE_SLASHED =
        keccak256("StakeSlashed(address,uint256,uint256,bytes32,uint64,uint16)");
    bytes32 internal constant T_ALLOCATION_INCREASED =
        keccak256("ProtocolAllocationIncreased(address,uint256,bytes32)");
    bytes32 internal constant T_ALLOCATION_CONSUMED =
        keccak256("ProtocolAllocationConsumed(address,address,uint256,uint64,uint16)");
    bytes32 internal constant T_EVIDENCE_COMMITTED =
        keccak256("EvidenceCommitted(uint256,uint256,address,bytes32,bytes32,uint256,uint64,uint16)");
    bytes32 internal constant T_EVIDENCE_STATUS_CHANGED =
        keccak256("EvidenceStatusChanged(uint256,uint8,uint8,address,uint64,uint16)");
    bytes32 internal constant T_PAUSE_ACTIVATED = keccak256("EmergencyPauseActivatedV1(address,bytes32,uint64,uint16)");
    bytes32 internal constant T_PAUSE_RECOVERED = keccak256("EmergencyPauseRecoveredV1(address,uint64,uint16)");

    uint8 internal constant VERIFIER_PRINCIPAL = 1;
    uint8 internal constant EVIDENCE_STATUS_SUBMITTED = 1;
    uint8 internal constant OUTCOME_NONE = 0;
    uint8 internal constant OUTCOME_CONCLUDED = 1;
    uint8 internal constant OUTCOME_REFUNDED = 2;
    uint8 internal constant OUTCOME_CARRIED_FORWARD = 3;
    uint8 internal constant OUTCOME_ROLLED_OVER = 4;
    uint8 internal constant OUTCOME_UNLOCKED = 5;

    address public immutable stakingToken;

    // Cell 0 / cell 1: supported assets, lock mutators.
    mapping(address => bool) public supportedAsset;
    mapping(address => bool) public lockMutator;
    // Cell 2 / cell 3 / cell 4: claimable, locked principal, total custody.
    mapping(address => mapping(address => uint256)) public claimable;
    mapping(bytes32 => uint256) public locked;
    mapping(address => uint256) public custody;
    // Cell 5: protocol allocation.
    mapping(address => uint256) public protocolAllocation;
    // Cell 6 / cell 7: verifier stake and its per-claim total.
    mapping(uint256 => mapping(address => uint256)) public staked;
    mapping(uint256 => uint256) public totalStaked;
    // Cell 8: settlement outcome, plus the R5 rewire attribution.
    mapping(uint256 => mapping(uint256 => uint8)) public settlementOutcome;
    mapping(uint256 => mapping(uint256 => uint256)) public rewireBlock;
    // Cell 10 - cell 14: commitment, per-claim order, nonce, dedupe, status.
    mapping(uint256 => bytes32) public commitment;
    mapping(uint256 => uint256) public evidenceCount;
    mapping(address => uint256) public nextNonce;
    mapping(uint256 => uint8) public evidenceStatus;
    mapping(bytes32 => bool) internal _committedSet;
    // Cell 15: pause gate.
    bool public paused;

    mapping(bytes32 => uint256) public appliedCount;
    mapping(bytes32 => uint256) public skippedCount;
    mapping(bytes32 => uint256) public ignoredCount;

    constructor(address stakingToken_) {
        stakingToken = stakingToken_;
    }

    /// @notice Applies one log to the projection.
    /// @param includeRestatements When true, also apply each event to the cells
    ///        the catalogue lists as *restatements* of it. Used by tests to
    ///        prove that doing so double-counts and must never be done.
    /// @param blockNumber The block that carried the log, taken from the
    ///        receipt rather than the log. R5 requires this attribution because
    ///        a log's own `timestamp` field is proposer-influenceable.
    function applyLog(
        bytes32 topic0,
        bytes32[] calldata topics,
        bytes calldata data,
        uint256 blockNumber,
        bool includeRestatements
    ) external {
        if (topic0 == T_VAULT_DEPOSITED) {
            // Cell 2 (+R0 aggregate cell 6) and cell 4.
            (address asset, address account) =
                (address(uint160(uint256(topics[1]))), address(uint160(uint256(topics[2]))));
            uint256 amount = abi.decode(data, (uint256));
            claimable[asset][account] += amount;
            custody[asset] += amount;
        } else if (topic0 == T_VAULT_LOCKED) {
            // Cell 2 and cell 3 (+R0 aggregate cell 6). Restatement of cell 7.
            (address asset, address account, uint256 claimId) = _cell(topics);
            (uint256 round, uint8 category, uint256 amount) = abi.decode(data, (uint256, uint8, uint256));
            claimable[asset][account] = _debit(claimable[asset][account], amount, topic0);
            locked[_lockKey(asset, account, claimId, round, category)] += amount;
            if (includeRestatements) _restateStake(claimId, account, asset, category, amount, true, topic0);
        } else if (topic0 == T_VAULT_UNLOCKED) {
            // Cell 2 and cell 3 (+R0 aggregate cell 6). Restatement of cell 7.
            (address asset, address account, uint256 claimId) = _cell(topics);
            (uint256 round, uint8 category, uint256 amount) = abi.decode(data, (uint256, uint8, uint256));
            claimable[asset][account] += amount;
            locked[_lockKey(asset, account, claimId, round, category)] =
                _debit(locked[_lockKey(asset, account, claimId, round, category)], amount, topic0);
            if (includeRestatements) _restateStake(claimId, account, asset, category, amount, false, topic0);
        } else if (topic0 == T_VAULT_WITHDRAWN) {
            // Cell 2 and cell 4.
            (address asset, address account) =
                (address(uint160(uint256(topics[1]))), address(uint160(uint256(topics[2]))));
            uint256 amount = abi.decode(data, (uint256));
            claimable[asset][account] = _debit(claimable[asset][account], amount, topic0);
            custody[asset] = _debit(custody[asset], amount, topic0);
        } else if (topic0 == T_VAULT_SLASHED) {
            // Cell 3 only. It restates the allocation credit of cell 5 and the
            // verifier-stake debit of cell 7, and both are closed elsewhere, so
            // neither is applied here.
            (address asset, address account, uint256 claimId) = _cell(topics);
            (uint256 round, uint8 category, uint256 amount,,,) =
                abi.decode(data, (uint256, uint8, uint256, bytes32, uint64, uint16));
            locked[_lockKey(asset, account, claimId, round, category)] =
                _debit(locked[_lockKey(asset, account, claimId, round, category)], amount, topic0);
            skippedCount[topic0] += 2;
            if (includeRestatements) {
                protocolAllocation[asset] += amount;
                _restateStake(claimId, account, asset, category, amount, false, topic0);
            }
        } else if (topic0 == T_ALLOCATION_INCREASED) {
            // Cell 5.
            protocolAllocation[address(uint160(uint256(topics[1])))] += abi.decode(data, (uint256));
        } else if (topic0 == T_ALLOCATION_CONSUMED) {
            // Cell 2 (+R0 aggregate cell 6) and cell 5.
            (address asset, address beneficiary) =
                (address(uint160(uint256(topics[1]))), address(uint160(uint256(topics[2]))));
            (uint256 amount,,) = abi.decode(data, (uint256, uint64, uint16));
            protocolAllocation[asset] = _debit(protocolAllocation[asset], amount, topic0);
            claimable[asset][beneficiary] += amount;
        } else if (topic0 == T_STAKE_DEPOSITED || topic0 == T_STAKE_RELEASED) {
            // Cell 7 (+R0 aggregate). The stake family is canonical here (R6):
            // the vault lock family restates the same delta.
            (address account, uint256 claimId) = _stakeCell(topics);
            (uint256 amount,,) = abi.decode(data, (uint256, uint64, uint16));
            if (topic0 == T_STAKE_DEPOSITED) {
                staked[claimId][account] += amount;
                totalStaked[claimId] += amount;
            } else {
                staked[claimId][account] = _debit(staked[claimId][account], amount, topic0);
                totalStaked[claimId] = _debit(totalStaked[claimId], amount, topic0);
            }
        } else if (topic0 == T_STAKE_SLASHED) {
            (address account, uint256 claimId) = _stakeCell(topics);
            (uint256 amount,,) = abi.decode(data, (uint256, uint64, uint16));
            staked[claimId][account] = _debit(staked[claimId][account], amount, topic0);
            totalStaked[claimId] = _debit(totalStaked[claimId], amount, topic0);
        } else if (topic0 == T_VAULT_SETTLED_CONCLUSIVE) {
            // Cell 8. Restatement of cell 2: the principal and reward legs were
            // already applied by VaultUnlocked and ProtocolAllocationConsumed.
            (address asset, address account, uint256 claimId) = _cell(topics);
            (uint256 round, uint256 principal, uint256 reward,,) =
                abi.decode(data, (uint256, uint256, uint256, uint64, uint16));
            settlementOutcome[claimId][round] = OUTCOME_CONCLUDED;
            skippedCount[topic0] += 1;
            if (includeRestatements) claimable[asset][account] += principal + reward;
        } else if (topic0 == T_VAULT_REFUNDED_INCONCLUSIVE) {
            (,, uint256 claimId) = _cell(topics);
            (uint256 round,,,) = abi.decode(data, (uint256, uint256, uint64, uint16));
            settlementOutcome[claimId][round] = OUTCOME_REFUNDED;
        } else if (topic0 == T_VAULT_CARRIED_FORWARD || topic0 == T_VAULT_ROLLED_OVER) {
            // Cell 3 (net zero for the cell 6 aggregate) and cell 8. The rewire
            // timestamp is the emitting block, never the log's own `timestamp`,
            // so a proposer cannot rewind a consumer's round attribution.
            (address asset, address account, uint256 claimId) = _cell(topics);
            (uint256 fromRound, uint256 toRound, uint256 amount,,) =
                abi.decode(data, (uint256, uint256, uint256, uint64, uint16));
            locked[_lockKey(asset, account, claimId, fromRound, VERIFIER_PRINCIPAL)] =
                _debit(locked[_lockKey(asset, account, claimId, fromRound, VERIFIER_PRINCIPAL)], amount, topic0);
            locked[_lockKey(asset, account, claimId, toRound, VERIFIER_PRINCIPAL)] += amount;
            settlementOutcome[claimId][fromRound] =
                topic0 == T_VAULT_CARRIED_FORWARD ? OUTCOME_CARRIED_FORWARD : OUTCOME_ROLLED_OVER;
            rewireBlock[claimId][toRound] = blockNumber;
        } else if (topic0 == T_VAULT_FINAL_UNLOCKED) {
            (,, uint256 claimId) = _cell(topics);
            (uint256 round,,,) = abi.decode(data, (uint256, uint256, uint64, uint16));
            settlementOutcome[claimId][round] = OUTCOME_UNLOCKED;
        } else if (topic0 == T_SUPPORTED_ASSET_UPDATED) {
            // Cell 0.
            (bool enabled,,) = abi.decode(data, (bool, uint64, uint16));
            supportedAsset[address(uint160(uint256(topics[1])))] = enabled;
        } else if (topic0 == T_LOCK_MUTATOR_UPDATED) {
            // Cell 1.
            (bool enabled,,) = abi.decode(data, (bool, uint64, uint16));
            lockMutator[address(uint160(uint256(topics[1])))] = enabled;
        } else if (topic0 == T_EVIDENCE_COMMITTED) {
            // Cell 10 (commitment), cell 11 (per-claim order, R0), cell 12
            // (contributor nonce, R1) and cell 13 (dedupe set, R2).
            (uint256 claimId, uint256 evidenceId, address contributor) =
                (uint256(topics[1]), uint256(topics[2]), address(uint160(uint256(topics[3]))));
            (bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce,,) =
                abi.decode(data, (bytes32, bytes32, uint256, uint64, uint16));
            bytes32 key = _commitmentKey(claimId, contributor, contentDigest, metadataDigest);
            require(!_committedSet[key], "dedupe cell violated: a commitment was applied twice");
            _committedSet[key] = true;
            commitment[evidenceId] = contentDigest;
            ++evidenceCount[claimId];
            nextNonce[contributor] = nonce + 1;
            // R7: the commitment establishes the record in SUBMITTED; only a
            // status change moves it after that.
            evidenceStatus[evidenceId] = EVIDENCE_STATUS_SUBMITTED;
        } else if (topic0 == T_EVIDENCE_STATUS_CHANGED) {
            // Cell 10 and cell 14.
            (, uint8 status,,) = abi.decode(data, (uint8, uint8, uint64, uint16));
            evidenceStatus[uint256(topics[1])] = status;
        } else if (topic0 == T_PAUSE_ACTIVATED) {
            // Cell 15.
            paused = true;
        } else if (topic0 == T_PAUSE_RECOVERED) {
            // Cell 15.
            paused = false;
        } else {
            // A log that closes no cell of this projection. AccessControl
            // bookkeeping and superseded evidence events land here; a consumer
            // ignores them rather than failing, and the test suite is where an
            // unrecognised emission becomes a tripwire.
            ignoredCount[topic0] += 1;
            return;
        }

        appliedCount[topic0] += 1;
    }

    /// @notice Applies a cell-7 restatement. Reachable only when a consumer
    ///         treats a restatement as a source, which is the double-count the
    ///         catalogue's disjointness invariant exists to forbid.
    function _restateStake(
        uint256 claimId,
        address account,
        address asset,
        uint8 category,
        uint256 amount,
        bool credit,
        bytes32 topic0
    ) internal {
        if (asset != stakingToken || category != VERIFIER_PRINCIPAL) return;
        if (credit) staked[claimId][account] += amount;
        else staked[claimId][account] = _debit(staked[claimId][account], amount, topic0);
        skippedCount[topic0] += 1;
    }

    function _commitmentKey(uint256 claimId, address contributor, bytes32 contentDigest, bytes32 metadataDigest)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(claimId, contributor, contentDigest, metadataDigest));
    }

    function _cell(bytes32[] calldata topics) internal pure returns (address asset, address account, uint256 claimId) {
        return (address(uint160(uint256(topics[1]))), address(uint160(uint256(topics[2]))), uint256(topics[3]));
    }

    function _stakeCell(bytes32[] calldata topics) internal pure returns (address account, uint256 claimId) {
        return (address(uint160(uint256(topics[1]))), uint256(topics[2]));
    }

    function _lockKey(address asset, address account, uint256 claimId, uint256 round, uint8 category)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(asset, account, claimId, round, category));
    }

    /// @dev Returns the debited balance, and reverts when a source is missing:
    ///      an underflow here means the catalogue named a closing event that
    ///      never carried the delta the cell needed.
    function _debit(uint256 available, uint256 requested, bytes32 topic0) internal pure returns (uint256) {
        if (available < requested) revert ProjectionUnderflow(topic0, available, requested);
        return available - requested;
    }

    function lockedPrincipal(address asset, address account, uint256 claimId, uint256 round, uint8 category)
        external
        view
        returns (uint256)
    {
        return locked[_lockKey(asset, account, claimId, round, category)];
    }

    function settlementOutcomeOf(uint256 claimId, uint256 round) external view returns (uint8) {
        return settlementOutcome[claimId][round];
    }

    function isCommitted(uint256 claimId, address contributor, bytes32 contentDigest, bytes32 metadataDigest)
        external
        view
        returns (bool)
    {
        return _committedSet[_commitmentKey(claimId, contributor, contentDigest, metadataDigest)];
    }
}

/// @title ProjectionReplayTest
/// @notice Replays a real `StakeVault` + `EvidenceRegistry` log stream into
///         `LogProjection` and requires the projection to equal the live read
///         surface of both contracts.
contract ProjectionReplayTest is Test {
    StakeVault internal vault;
    EvidenceRegistry internal evidence;
    ReplayModuleRegistry internal registry;
    MockEvidenceClaimRegistry internal claimRegistry;
    MockERC20 internal token;
    MockERC20 internal alt;

    address internal admin = address(this);
    address internal verifier = address(0xBEEF);
    address internal verifier2 = address(0xCAFE);
    address internal contributor = address(0xF00D);
    address internal settlement = address(0xA001);
    address internal slashing = address(0xA002);

    uint256 internal constant CLAIM_A = 1;
    uint256 internal constant CLAIM_B = 2;
    uint256 internal constant CLAIM_C = 3;
    uint256 internal constant CLAIM_D = 4;
    uint256 internal constant CLAIM_E = 7;
    uint8 internal constant VERIFIER_PRINCIPAL = 1;
    uint8 internal constant CHALLENGE_BOND = 3;
    uint256 internal constant STAKE = 100 ether;
    bytes32 internal constant CONTENT_A = keccak256("content-a");
    bytes32 internal constant CONTENT_B = keccak256("content-b");
    bytes internal metaA = abi.encode(keccak256("metadata-a"));
    bytes internal metaB = abi.encode(keccak256("metadata-b"));

    /// @dev One entry per recorded log, carrying the block that produced it.
    struct Captured {
        address emitter;
        bytes32 topic0;
        bytes32[] topics;
        bytes data;
        uint256 blockNumber;
    }

    Captured[] internal captured;

    function setUp() public {
        registry = new ReplayModuleRegistry();
        claimRegistry = new MockEvidenceClaimRegistry();
        token = new MockERC20("Stake", "STK");
        alt = new MockERC20("Alt", "ALT");

        vm.recordLogs();
        vault = new StakeVault(address(registry), address(token), admin);
        evidence = new EvidenceRegistry(admin, address(claimRegistry));
        _capture(block.number);
    }

    // -------------------------------------------------------------------------
    // Scenario
    // -------------------------------------------------------------------------

    /// @dev Exercises every closing source of the stake-custody and evidence
    ///      cells in one ordered stream. Each `_at` is one block, so the R5
    ///      rewire attribution is observable.
    function _scenario() internal {
        // Administration and funding also mutate read cells (cells 0 and 1), so
        // they are part of the recorded stream rather than test scaffolding.
        _begin(2);
        vault.setSupportedAsset(address(alt), true);
        vault.setLockMutator(settlement, true);
        registry.registerModule(vault.MODULE_SETTLEMENT(), settlement);
        registry.registerModule(vault.MODULE_SLASHING(), slashing);

        token.mint(verifier, 1_000 ether);
        alt.mint(verifier, 1_000 ether);
        alt.mint(verifier2, 1_000 ether);
        vm.startPrank(verifier);
        token.approve(address(vault), type(uint256).max);
        alt.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(verifier2);
        alt.approve(address(vault), type(uint256).max);
        _commit();

        // A plain custody deposit, so the generic lock hook below has claimable
        // balance to draw on. `depositStake` locks immediately, so it cannot
        // also fund a second claim.
        _begin(99);
        vm.prank(verifier);
        vault.deposit(address(token), 60 ether);
        _commit();

        // Staking-token principal. The generic `lock` hook and the conclusive
        // settlement both write the round-less stake cell, so this stream
        // exercises every path that writes it, not only the family-6 surface.
        _begin(100);
        vm.prank(verifier);
        vault.depositStake(CLAIM_A, STAKE);
        _commit();
        _begin(101);
        vm.prank(settlement);
        vault.lock(address(token), verifier, CLAIM_B, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 60 ether);
        _commit();
        _begin(102);
        vm.prank(slashing);
        vault.slashStake(CLAIM_A, verifier, 10 ether, keccak256("slash"));
        _commit();
        _begin(103);
        vm.prank(settlement);
        vault.settleConclusive(address(token), verifier, CLAIM_B, 0, 30 ether, 0);
        _commit();
        // A reward credit funded by the slash above, settled on a claim that
        // holds no principal, so only the allocation leg moves.
        _begin(104);
        vm.prank(settlement);
        vault.settleConclusive(address(token), verifier, CLAIM_D, 0, 0, 5 ether);
        _commit();

        // Alt-asset custody: a challenge bond that stays locked, a
        // verifier-principal lock that is refunded, and a partial withdrawal.
        _begin(105);
        vm.prank(verifier);
        vault.deposit(address(alt), 50 ether);
        _commit();
        _begin(106);
        vm.prank(verifier2);
        vault.deposit(address(alt), 50 ether);
        _commit();
        _begin(107);
        vm.prank(settlement);
        vault.lock(address(alt), verifier2, CLAIM_C, 1, IV2Types.LockCategory(CHALLENGE_BOND), 20 ether);
        _commit();
        _begin(108);
        vm.prank(settlement);
        vault.lock(address(alt), verifier2, CLAIM_C, 2, IV2Types.LockCategory.VERIFIER_PRINCIPAL, 6 ether);
        _commit();
        _begin(109);
        vm.prank(settlement);
        vault.refundInconclusive(address(alt), verifier2, CLAIM_C, 2, 6 ether);
        _commit();

        // Two rewires and a final unlock on the remaining round-0 principal.
        // The rewires move the lock without touching the stake cell; the final
        // unlock debits both.
        _begin(110);
        vm.prank(settlement);
        vault.carryForwardAppeal(address(token), verifier, CLAIM_A, 0, 2, 40 ether);
        _commit();
        _begin(111);
        vm.prank(settlement);
        vault.rolloverRound(address(token), verifier, CLAIM_A, 2, 3, 15 ether);
        _commit();
        _begin(112);
        vm.prank(settlement);
        vault.finalUnlock(address(token), verifier, CLAIM_A, 3, 15 ether);
        _commit();
        _begin(113);
        vm.prank(verifier);
        vault.withdraw(address(alt), 30 ether);
        _commit();

        claimRegistry.setClaim(
            CLAIM_E, address(this), uint64(block.timestamp) + 1 days, IClaimRegistry.ClaimStatus.Pending
        );
        _begin(114);
        vm.prank(contributor);
        evidence.submitEvidence(CLAIM_E, CONTENT_A, metaA);
        _commit();
        _begin(115);
        vm.prank(contributor);
        evidence.submitEvidence(CLAIM_E, CONTENT_B, metaB);
        _commit();
        _begin(116);
        evidence.setEvidenceStatus(_firstEvidenceId(), IV2Types.EvidenceStatus.REJECTED);
        _commit();
        _begin(117);
        evidence.pause();
        evidence.unpause();
        _commit();
    }

    /// @notice Starts a step in its own block and begins recording its logs.
    /// @dev The block number is captured alongside the logs because R5 attributes
    ///      a rewire to the block that carried it, not to the log's own
    ///      timestamp field.
    function _begin(uint256 blockNumber) internal {
        vm.roll(blockNumber);
        vm.recordLogs();
    }

    /// @notice Ends the current step.
    function _commit() internal {
        _capture(block.number);
    }

    function _capture(uint256 blockNumber) internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            captured.push(
                Captured({
                    emitter: entries[i].emitter,
                    topic0: entries[i].topics[0],
                    topics: entries[i].topics,
                    data: entries[i].data,
                    blockNumber: blockNumber
                })
            );
        }
    }

    function _firstEvidenceId() internal view returns (uint256) {
        (uint256[] memory ids,) = evidence.claimEvidence(CLAIM_E, 0, 1);
        return ids[0];
    }

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    function test_LogStreamRebuildsEveryAuthoritativeReadCell() public {
        _scenario();
        LogProjection fresh = new LogProjection(address(token));
        _replay(captured, fresh, false);

        // Cell 0 / cell 1: administration flags, including the genesis entry
        // emitted by the vault constructor.
        assertEq(vault.supportedAssets(address(alt)), fresh.supportedAsset(address(alt)), "cell 0");
        assertEq(vault.supportedAssets(address(token)), fresh.supportedAsset(address(token)), "cell 0");
        assertEq(vault.lockMutators(settlement), fresh.lockMutator(settlement), "cell 1");
        assertEq(vault.lockMutators(address(slashing)), fresh.lockMutator(address(slashing)), "cell 1");

        // Cell 2: claimable balance per (asset, account).
        assertEq(fresh.claimable(address(token), verifier), vault.claimableBalance(address(token), verifier), "cell 2");
        assertEq(
            fresh.claimable(address(token), verifier2), vault.claimableBalance(address(token), verifier2), "cell 2"
        );
        assertEq(fresh.claimable(address(alt), verifier), vault.claimableBalance(address(alt), verifier), "cell 2");
        assertEq(fresh.claimable(address(alt), verifier2), vault.claimableBalance(address(alt), verifier2), "cell 2");

        // Cell 3: locked principal per lock cell, including the moved rounds.
        _assertLocked(fresh, address(token), verifier, CLAIM_A, 0, VERIFIER_PRINCIPAL);
        _assertLocked(fresh, address(token), verifier, CLAIM_A, 2, VERIFIER_PRINCIPAL);
        _assertLocked(fresh, address(token), verifier, CLAIM_A, 3, VERIFIER_PRINCIPAL);
        _assertLocked(fresh, address(token), verifier, CLAIM_B, 0, VERIFIER_PRINCIPAL);
        _assertLocked(fresh, address(alt), verifier2, CLAIM_C, 1, CHALLENGE_BOND);
        _assertLocked(fresh, address(alt), verifier2, CLAIM_C, 2, VERIFIER_PRINCIPAL);
        assertGt(fresh.lockedPrincipal(address(alt), verifier2, CLAIM_C, 1, CHALLENGE_BOND), 0, "the bond stays locked");

        // Cell 4 / cell 5: custody and protocol allocation.
        assertEq(fresh.custody(address(token)), vault.totalCustody(address(token)), "cell 4");
        assertEq(fresh.custody(address(alt)), vault.totalCustody(address(alt)), "cell 4");
        assertEq(fresh.protocolAllocation(address(token)), vault.protocolAllocation(address(token)), "cell 5");

        // Cell 6 (R0): the asset totals are the sum over the per-key cells, so a
        // consumer derives them without a second event family, and the replayed
        // totals satisfy the same conservation equation the vault enforces.
        (uint256 tokenCustody, uint256 tokenObligations) = vault.reconcile(address(token));
        uint256 tokenLocked = fresh.lockedPrincipal(address(token), verifier, CLAIM_A, 0, VERIFIER_PRINCIPAL)
            + fresh.lockedPrincipal(address(token), verifier, CLAIM_A, 2, VERIFIER_PRINCIPAL)
            + fresh.lockedPrincipal(address(token), verifier, CLAIM_A, 3, VERIFIER_PRINCIPAL)
            + fresh.lockedPrincipal(address(token), verifier, CLAIM_B, 0, VERIFIER_PRINCIPAL);
        uint256 tokenClaimable = fresh.claimable(address(token), verifier) + fresh.claimable(address(token), verifier2);
        assertEq(
            tokenCustody, tokenClaimable + tokenLocked + fresh.protocolAllocation(address(token)), "cell 6 conservation"
        );
        assertEq(tokenObligations, tokenCustody, "the live obligation view is balanced");

        (uint256 altCustody, uint256 altObligations) = vault.reconcile(address(alt));
        assertEq(
            altCustody,
            fresh.claimable(address(alt), verifier) + fresh.claimable(address(alt), verifier2)
                + fresh.lockedPrincipal(address(alt), verifier2, CLAIM_C, 1, CHALLENGE_BOND)
                + fresh.lockedPrincipal(address(alt), verifier2, CLAIM_C, 2, VERIFIER_PRINCIPAL),
            "cell 6 conservation on the alt asset"
        );
        assertEq(altObligations, altCustody, "the live alt obligation view is balanced");

        // Cell 7 (R6): the stake family is canonical for stake, and both the
        // per-account and per-claim total cells agree. The settlement-hook
        // unlock of principal is included: it is the path a lock-only consumer
        // over-reports.
        assertEq(fresh.staked(CLAIM_A, verifier), vault.staked(CLAIM_A, verifier), "cell 7");
        assertEq(fresh.staked(CLAIM_B, verifier), vault.staked(CLAIM_B, verifier), "cell 7");
        assertEq(fresh.totalStaked(CLAIM_A), vault.totalStaked(CLAIM_A), "cell 7 total");
        assertEq(fresh.totalStaked(CLAIM_B), vault.totalStaked(CLAIM_B), "cell 7 total");
        assertEq(
            fresh.totalStaked(CLAIM_A),
            fresh.staked(CLAIM_A, verifier) + fresh.staked(CLAIM_A, verifier2),
            "cell 7 reduces to the sum over per-key cells"
        );

        // Cell 8: settlement outcome per claim-round, including rounds that
        // only ever saw a rewire, and rounds that were never touched.
        _assertOutcome(fresh, CLAIM_A, 0, vault.settlementOutcome(CLAIM_A, 0));
        _assertOutcome(fresh, CLAIM_A, 1, vault.settlementOutcome(CLAIM_A, 1));
        _assertOutcome(fresh, CLAIM_A, 2, vault.settlementOutcome(CLAIM_A, 2));
        _assertOutcome(fresh, CLAIM_A, 3, vault.settlementOutcome(CLAIM_A, 3));
        _assertOutcome(fresh, CLAIM_B, 0, vault.settlementOutcome(CLAIM_B, 0));
        _assertOutcome(fresh, CLAIM_C, 2, vault.settlementOutcome(CLAIM_C, 2));
        _assertOutcome(fresh, CLAIM_D, 0, vault.settlementOutcome(CLAIM_D, 0));
        assertEq(fresh.settlementOutcomeOf(CLAIM_C, 1), 0, "a round with only a bond lock stays unresolved");

        // R5: a rewire is attributed to the block that carried it, not to the
        // log's own timestamp field.
        assertEq(fresh.rewireBlock(CLAIM_A, 2), 110, "R5 rewire block");
        assertEq(fresh.rewireBlock(CLAIM_A, 3), 111, "R5 rewire block");
        assertEq(fresh.rewireBlock(CLAIM_A, 1), 0, "a round that was never rewired has no rewire attribution");

        // Cell 10 - cell 13: commitment, per-claim order, nonce, dedupe set.
        (uint256[] memory ids,) = evidence.claimEvidence(CLAIM_E, 0, 10);
        assertEq(ids.length, 2, "two commitments");
        assertEq(fresh.evidenceCount(CLAIM_E), ids.length, "cell 11");
        assertEq(fresh.commitment(ids[0]), CONTENT_A, "cell 10");
        assertEq(fresh.commitment(ids[1]), CONTENT_B, "cell 10");
        assertEq(fresh.nextNonce(contributor), evidence.nextContributorNonce(contributor), "cell 12");
        assertTrue(fresh.isCommitted(CLAIM_E, contributor, CONTENT_A, keccak256(metaA)), "cell 13");
        assertTrue(fresh.isCommitted(CLAIM_E, contributor, CONTENT_B, keccak256(metaB)), "cell 13");
        assertFalse(
            fresh.isCommitted(CLAIM_E, contributor, CONTENT_B, keccak256(metaA)), "cell 13 keys on all four fields"
        );

        // Cell 14: lifecycle status.
        assertEq(uint8(evidence.getEvidence(ids[0]).status), fresh.evidenceStatus(ids[0]), "cell 14");
        assertEq(uint8(evidence.getEvidence(ids[1]).status), fresh.evidenceStatus(ids[1]), "cell 14");

        // Cell 15: the pause gate, which is authoritative because it gates
        // `submitEvidence` at the source.
        assertEq(fresh.paused(), evidence.paused(), "cell 15");
        assertGt(
            fresh.appliedCount(keccak256("EmergencyPauseActivatedV1(address,bytes32,uint64,uint16)")), 0, "pause logged"
        );
        assertGt(
            fresh.appliedCount(keccak256("EmergencyPauseRecoveredV1(address,uint64,uint16)")), 0, "recovery logged"
        );
    }

    /// @notice The restatement discipline is load-bearing: a consumer that also
    ///         applies a cell's restatements over-counts and diverges from the
    ///         contracts. Negative control for the catalogue's disjointness
    ///         invariant.
    function test_ApplyingRestatementsAsSourcesDoubleCounts() public {
        _scenario();
        LogProjection greedy = new LogProjection(address(token));
        _replay(captured, greedy, true);

        // Cell 7 was restated by VaultLocked, VaultUnlocked and VaultSlashed.
        assertGt(greedy.staked(CLAIM_A, verifier), vault.staked(CLAIM_A, verifier), "stake double-counted");
        // Cell 5 was restated by VaultSlashed.
        assertGt(
            greedy.protocolAllocation(address(token)),
            vault.protocolAllocation(address(token)),
            "allocation double-counted"
        );
        // Cell 2 was restated by VaultSettledConclusive.
        assertGt(
            greedy.claimable(address(token), verifier),
            vault.claimableBalance(address(token), verifier),
            "claimable double-counted"
        );
        // The strict projection saw the same logs and refused to apply them.
        assertGt(
            greedy.skippedCount(
                keccak256("VaultSlashed(address,address,uint256,uint256,uint8,uint256,bytes32,uint64,uint16)")
            ),
            0,
            "the slash log restates two cells"
        );
        assertGt(
            greedy.skippedCount(
                keccak256("VaultSettledConclusive(address,address,uint256,uint256,uint256,uint256,uint64,uint16)")
            ),
            0,
            "the conclusive settlement restates the claimable cell"
        );
    }

    /// @notice The projection's topic set is exactly the catalogue's published
    ///         closing events for these two modules; any other emission is a
    ///         documented legacy log or a tripwire.
    function test_EmissionsAreEitherPublishedClosingEventsOrDocumentedLegacyLogs() public {
        _scenario();
        LogProjection fresh = new LogProjection(address(token));
        _replay(captured, fresh, false);

        for (uint256 i; i < captured.length; ++i) {
            if (!_isUnderTest(captured[i].emitter)) continue;
            bytes32 topic0 = captured[i].topic0;
            if (_isPublishedSource(topic0)) {
                assertGt(fresh.appliedCount(topic0), 0, "a published closing event was not applied");
            } else {
                assertGt(fresh.ignoredCount(topic0), 0, "an emission closed no cell");
                assertTrue(
                    _isDocumentedLegacyLog(topic0),
                    string.concat("an undocumented emission is missing from the catalogue: ", vm.toString(topic0))
                );
            }
        }
    }

    function test_EveryCatalogueCellHasAClosingEvent() public pure {
        uint256 count = V2EventCompleteness.cellCount();
        for (uint256 i; i < count; ++i) {
            assertTrue(V2EventCompleteness.isCellComplete(i), "every cell is closed");
        }
    }

    /// @notice Every log this suite is willing to skip is published in the
    ///         manifest's non-canonical allow-list, so "quarantine unknown
    ///         signatures" has a machine-readable boundary for a consumer.
    function test_DocumentedLegacyLogsArePublishedInTheManifest() public view {
        string memory manifest = vm.readFile("deployments/config/event-completeness.json");
        bytes32[8] memory allow = [
            keccak256("EvidenceSubmitted(uint256,uint256,address,bytes32,uint64,uint16)"),
            keccak256("EvidenceSubmittedV1(uint256,uint256,address,bytes32,uint64,uint16)"),
            keccak256("RoleGranted(bytes32,address,address)"),
            keccak256("RoleRevoked(bytes32,address,address)"),
            keccak256("ModuleRegistered(bytes32,address,uint16,uint16,uint64,uint16)"),
            keccak256("ModuleRemoved(bytes32,address,uint64,uint16)"),
            keccak256("Paused(address)"),
            keccak256("Unpaused(address)")
        ];

        for (uint256 i; i < allow.length; ++i) {
            assertTrue(_isDocumentedLegacyLog(allow[i]), "the allow-list and this suite must agree");
            assertTrue(
                _publishedAsNonCanonical(manifest, allow[i]), "an allow-listed emission is missing from the manifest"
            );
        }
    }

    function _publishedAsNonCanonical(string memory manifest, bytes32 topic0) internal view returns (bool) {
        for (uint256 i; i < 8; ++i) {
            string memory row = string.concat(".nonCanonicalEmissions.emissions[", vm.toString(i), "].topic0");
            if (bytes32(vm.parseJsonBytes32(manifest, row)) == topic0) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _replay(Captured[] memory entries, LogProjection target, bool includeRestatements) internal {
        for (uint256 i; i < entries.length; ++i) {
            if (!_isUnderTest(entries[i].emitter)) continue;
            target.applyLog(
                entries[i].topic0, entries[i].topics, entries[i].data, entries[i].blockNumber, includeRestatements
            );
        }
    }

    function _isUnderTest(address emitter) internal view returns (bool) {
        return emitter == address(vault) || emitter == address(evidence);
    }

    function _assertLocked(
        LogProjection p,
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        uint8 category
    ) internal {
        assertEq(
            p.lockedPrincipal(asset, account, claimId, round, category),
            vault.lockedPrincipal(asset, account, claimId, round, IV2Types.LockCategory(category)),
            "cell 3 locked principal"
        );
    }

    function _assertOutcome(LogProjection p, uint256 claimId, uint256 round, IV2Types.SettlementOutcome expected)
        internal
    {
        assertEq(p.settlementOutcomeOf(claimId, round), uint8(expected), "cell 8 settlement outcome");
    }

    function _isPublishedSource(bytes32 topic0) internal pure returns (bool) {
        uint256 count = V2EventCompleteness.cellCount();
        for (uint256 i; i < count; ++i) {
            bytes32[] memory closing = V2EventCompleteness.closingEventsOf(i);
            for (uint256 j; j < closing.length; ++j) {
                if (closing[j] == topic0) return true;
            }
        }
        return false;
    }

    /// @dev Pre-existing canonical logs the catalogue deliberately does not
    ///      treat as closing sources: each is a subset of a cell that a
    ///      V2-SC-132 event already closes, or is AccessControl bookkeeping with
    ///      no read cell of its own.
    function _isDocumentedLegacyLog(bytes32 topic0) internal pure returns (bool) {
        return topic0 == keccak256("EvidenceSubmitted(uint256,uint256,address,bytes32,uint64,uint16)")
            || topic0 == keccak256("EvidenceSubmittedV1(uint256,uint256,address,bytes32,uint64,uint16)")
            || topic0 == keccak256("RoleGranted(bytes32,address,address)")
            || topic0 == keccak256("RoleRevoked(bytes32,address,address)")
            || topic0 == keccak256("ModuleRegistered(bytes32,address,uint16,uint16,uint64,uint16)")
            || topic0 == keccak256("ModuleRemoved(bytes32,address,uint64,uint16)")
            // OpenZeppelin's inherited `Pausable` base emits its own transition
            // events for the same two state changes the family-15 logs publish.
            || topic0 == keccak256("Paused(address)") || topic0 == keccak256("Unpaused(address)");
    }
}

/// @dev Local module registry. `contracts/mocks/MockModuleRegistry.sol` does
///      not compile at HEAD (it emits `ModuleRegistered` with four of the six
///      declared arguments), so this ticket's suite carries its own rather than
///      depending on a broken helper.
contract ReplayModuleRegistry is ERC165, IModuleRegistry {
    struct Entry {
        address implementation;
        bool registered;
    }

    mapping(bytes32 => Entry) internal _modules;

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IModuleRegistry).interfaceId || super.supportsInterface(interfaceId);
    }

    function registerModule(bytes32 moduleId, address implementation) external override {
        _modules[moduleId] = Entry({ implementation: implementation, registered: true });
    }

    function removeModule(bytes32 moduleId) external override {
        delete _modules[moduleId];
    }

    function module(bytes32 moduleId)
        external
        view
        override
        returns (address implementation, uint16 major, uint16 minor)
    {
        Entry storage entry = _modules[moduleId];
        return (entry.implementation, 2, 0);
    }

    function isRegistered(bytes32 moduleId) external view override returns (bool) {
        return _modules[moduleId].registered;
    }
}
