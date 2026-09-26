// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IClaimRegistry } from "../interfaces/IClaimRegistry.sol";
import { ITruthBountyEvents } from "../interfaces/ITruthBountyEvents.sol";
import { IEvidence } from "./interfaces/IEvidence.sol";
import { IV2Module } from "./interfaces/IV2Module.sol";
import { IV2Types } from "./interfaces/IV2Types.sol";
import { ProtocolExecutionBounds } from "../performance/ProtocolExecutionBounds.sol";

/// @title EvidenceRegistry
/// @notice Content-addressed V2 evidence commitment registry.
/// @dev Stores only immutable digests and deterministic IDs. Raw evidence
///      content, CIDs, URLs, signatures, and private data stay off-chain.
///
///      Event completeness (V2-SC-132): every authoritative read cell —
///      commitment fields, per-claim ordering, contributor nonce, dedupe set,
///      lifecycle status, and the pause gate — is closed by at least one
///      canonical event, so replaying the ordered log stream reconstructs the
///      full read state. The authoritative enumeration is published on-chain by
///      `EventCompletenessAnchor`.
contract EvidenceRegistry is ERC165, AccessControl, Pausable, IEvidence, ITruthBountyEvents {
    bytes32 public constant EVIDENCE_ADMIN_ROLE = keccak256("EVIDENCE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 public constant MAX_EVIDENCE_PER_CLAIM = ProtocolExecutionBounds.MAX_EVIDENCE_PER_CLAIM;

    /// @notice Fixed, domain-separated reason attached to admin-driven pause logs.
    /// @dev `EmergencyPauseActivatedV1` requires a `bytes32 reason`; the pause
    ///      authority for this module is the `PAUSER_ROLE` holder and no
    ///      per-call reason is collected, so the constant keeps the log
    ///      deterministic across deployments.
    bytes32 public constant ADMIN_PAUSE_REASON = keccak256("EVIDENCE_REGISTRY_ADMIN_PAUSE");

    IClaimRegistry public immutable claimRegistry;

    struct EvidenceCommitment {
        uint256 id;
        uint256 claimId;
        address contributor;
        bytes32 contentDigest;
        bytes32 metadataDigest;
        uint256 nonce;
        uint64 committedAt;
        IV2Types.EvidenceStatus status;
    }

    mapping(uint256 => EvidenceCommitment) private _evidenceById;
    mapping(uint256 => uint256[]) private _claimEvidenceIds;
    mapping(address => uint256) private _nextContributorNonce;
    mapping(bytes32 => bool) private _commitmentExists;

    error ZeroAdmin();
    error ZeroClaimRegistry();
    error ZeroDigest();
    error InvalidClaim(uint256 claimId);
    error EvidenceWindowClosed(uint256 claimId, uint64 deadline, uint64 timestamp);
    error ClaimFinalized(uint256 claimId, IClaimRegistry.ClaimStatus status);
    error InvalidNonce(address contributor, uint256 expected, uint256 provided);
    error DuplicateEvidence(bytes32 commitmentKey);
    error EvidenceNotFound(uint256 evidenceId);
    error InvalidPageLimit(uint256 limit);
    error EvidenceLimitReached(uint256 claimId, uint256 max);

    event EvidenceCommitted(
        uint256 indexed claimId,
        uint256 indexed evidenceId,
        address indexed contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce,
        uint64 timestamp,
        uint16 version
    );

    constructor(address initialAdmin, address claimRegistry_) {
        if (initialAdmin == address(0)) revert ZeroAdmin();
        if (claimRegistry_ == address(0)) revert ZeroClaimRegistry();

        claimRegistry = IClaimRegistry(claimRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(EVIDENCE_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IV2Module).interfaceId || interfaceId == type(IEvidence).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IEvidence
    function submitEvidence(uint256 claimId, bytes32 contentHash, bytes calldata metadata)
        external
        override
        returns (uint256 evidenceId)
    {
        return commitEvidence(claimId, contentHash, keccak256(metadata), _nextContributorNonce[msg.sender]);
    }

    /// @notice Commit evidence digests to an existing claim.
    /// @param claimId Existing claim that receives the evidence commitment.
    /// @param contentDigest Digest of the off-chain evidence content.
    /// @param metadataDigest Digest of off-chain evidence metadata.
    /// @param nonce Contributor nonce used in deterministic evidence ID derivation.
    function commitEvidence(uint256 claimId, bytes32 contentDigest, bytes32 metadataDigest, uint256 nonce)
        public
        whenNotPaused
        returns (uint256 evidenceId)
    {
        if (contentDigest == bytes32(0) || metadataDigest == bytes32(0)) revert ZeroDigest();
        if (!claimRegistry.claimExists(claimId)) revert InvalidClaim(claimId);

        IClaimRegistry.Claim memory claim = claimRegistry.getClaim(claimId);
        if (!_acceptsEvidence(claim.status)) revert ClaimFinalized(claimId, claim.status);

        uint64 now_ = uint64(block.timestamp);
        if (now_ > claim.verificationDeadline) {
            revert EvidenceWindowClosed(claimId, claim.verificationDeadline, now_);
        }

        uint256 expectedNonce = _nextContributorNonce[msg.sender];
        if (nonce != expectedNonce) revert InvalidNonce(msg.sender, expectedNonce, nonce);

        bytes32 commitmentKey = keccak256(abi.encode(claimId, msg.sender, contentDigest, metadataDigest));
        if (_commitmentExists[commitmentKey]) revert DuplicateEvidence(commitmentKey);
        if (_claimEvidenceIds[claimId].length >= MAX_EVIDENCE_PER_CLAIM) {
            revert EvidenceLimitReached(claimId, MAX_EVIDENCE_PER_CLAIM);
        }

        evidenceId = computeEvidenceId(claimId, msg.sender, contentDigest, metadataDigest, nonce);
        _commitmentExists[commitmentKey] = true;
        _nextContributorNonce[msg.sender] = nonce + 1;

        _evidenceById[evidenceId] = EvidenceCommitment({
            id: evidenceId,
            claimId: claimId,
            contributor: msg.sender,
            contentDigest: contentDigest,
            metadataDigest: metadataDigest,
            nonce: nonce,
            committedAt: now_,
            status: IV2Types.EvidenceStatus.SUBMITTED
        });
        _claimEvidenceIds[claimId].push(evidenceId);

        emit EvidenceSubmitted(evidenceId, claimId, msg.sender, contentDigest, uint64(block.timestamp), 1);
        emit EvidenceSubmittedV1(claimId, evidenceId, msg.sender, contentDigest, now_, EVENT_SCHEMA_VERSION);
        emit EvidenceCommitted(
            claimId, evidenceId, msg.sender, contentDigest, metadataDigest, nonce, now_, EVENT_SCHEMA_VERSION
        );
    }

    /// @inheritdoc IEvidence
    function setEvidenceStatus(uint256 evidenceId, IV2Types.EvidenceStatus status)
        external
        override
        onlyRole(EVIDENCE_ADMIN_ROLE)
    {
        EvidenceCommitment storage evidence = _evidenceById[evidenceId];
        if (evidence.status == IV2Types.EvidenceStatus.NONE) revert EvidenceNotFound(evidenceId);

        IV2Types.EvidenceStatus previous = evidence.status;
        evidence.status = status;
        emit EvidenceStatusChanged(evidenceId, previous, status, msg.sender, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IEvidence
    function getEvidence(uint256 evidenceId) external view override returns (IV2Types.Evidence memory) {
        EvidenceCommitment storage evidence = _existingEvidence(evidenceId);
        return IV2Types.Evidence({
            id: evidence.id,
            claimId: evidence.claimId,
            submitter: evidence.contributor,
            contentHash: evidence.contentDigest,
            submittedAt: evidence.committedAt,
            status: evidence.status
        });
    }

    /// @notice Returns the full digest commitment for an evidence ID.
    function getEvidenceCommitment(uint256 evidenceId) external view returns (EvidenceCommitment memory) {
        return _existingEvidence(evidenceId);
    }

    /// @inheritdoc IEvidence
    function claimEvidence(uint256 claimId, uint256 cursor, uint256 limit)
        external
        view
        override
        returns (uint256[] memory evidenceIds, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert InvalidPageLimit(limit);

        uint256[] storage ids = _claimEvidenceIds[claimId];
        uint256 length = ids.length;
        if (cursor >= length) return (new uint256[](0), length);

        uint256 end = cursor + limit;
        if (end > length) end = length;

        evidenceIds = new uint256[](end - cursor);
        for (uint256 i = cursor; i < end;) {
            evidenceIds[i - cursor] = ids[i];
            unchecked {
                ++i;
            }
        }

        return (evidenceIds, end);
    }

    function computeEvidenceId(
        uint256 claimId,
        address contributor,
        bytes32 contentDigest,
        bytes32 metadataDigest,
        uint256 nonce
    ) public view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(block.chainid, address(this), claimId, contributor, contentDigest, metadataDigest, nonce)
            )
        );
    }

    function nextContributorNonce(address contributor) external view returns (uint256) {
        return _nextContributorNonce[contributor];
    }

    function evidenceCount(uint256 claimId) external view returns (uint256) {
        return _claimEvidenceIds[claimId].length;
    }

    /// @notice Stops all evidence commitment. Emits `EmergencyPauseActivatedV1`.
    /// @dev The pause flag gates every `commitEvidence` call, so it is an
    ///      authoritative read cell (V2-SC-132): it is now published as a
    ///      canonical family-15 log instead of mutating silently.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit EmergencyPauseActivatedV1(msg.sender, ADMIN_PAUSE_REASON, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Resumes evidence commitment. Emits `EmergencyPauseRecoveredV1`.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit EmergencyPauseRecoveredV1(msg.sender, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    function _existingEvidence(uint256 evidenceId) private view returns (EvidenceCommitment storage evidence) {
        evidence = _evidenceById[evidenceId];
        if (evidence.status == IV2Types.EvidenceStatus.NONE) revert EvidenceNotFound(evidenceId);
    }

    function _acceptsEvidence(IClaimRegistry.ClaimStatus status) private pure returns (bool) {
        return status == IClaimRegistry.ClaimStatus.Pending || status == IClaimRegistry.ClaimStatus.UnderVerification;
    }
}
