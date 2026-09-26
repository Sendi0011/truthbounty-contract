// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IEventCompleteness } from "./interfaces/IEventCompleteness.sol";
import { IV2Module } from "./interfaces/IV2Module.sol";
import { V2Errors } from "./libraries/V2Errors.sol";
import { V2EventCompleteness } from "./libraries/V2EventCompleteness.sol";

/// @title EventCompletenessAnchor
/// @notice Read-only discovery anchor that publishes the authoritative event
///         completeness catalogue for one canonical V2 deployment (V2-SC-132).
/// @dev    Deployment-scoped, immutable after construction, and strictly
///         passive: the anchor holds no funds, authorizes no caller, and exposes
///         no state-changing function beyond the constructor. Publishing a
///         completeness record makes no off-chain or on-chain actor more
///         powerful — it only makes the protocol's existing promise about its own
///         log surface machine-readable.
///
///         Consumers MUST pin `catalogueRoot` at ingestion and re-derive it on
///         every replay. Reorg and rollback behaviour is *not* declared here; it
///         is published by `ConsumerGuaranteesAnchor` under V2-SC-134.
contract EventCompletenessAnchor is ERC165, IV2Module, IEventCompleteness {
    /// @notice Chain this anchor is bound to, fixed at deployment.
    uint64 public immutable CHAIN_ID;

    /// @notice Deployer/admin recorded for provenance only. It carries no runtime
    ///         authority: the anchor has no function it could call.
    address public immutable deployer;

    /// @notice The immutable record, published individually because Solidity
    ///         structs are not value types; `eventCompleteness()` reassembles it.
    uint16 private immutable _completenessVersion;
    uint256 private immutable _moduleCount;
    uint256 private immutable _cellCount;
    uint256 private immutable _bindingCount;
    bytes32 private immutable _catalogueRoot;
    bool private immutable _everyMutationEmits;
    bool private immutable _mutationsAreTerminal;
    bool private immutable _orderIsTotal;
    bool private immutable _projectionIsDeterministic;

    /// @param completeness_ The validated completeness record to publish.
    /// @param deployer_     Deployment provenance address; must not be zero.
    constructor(EventCompleteness memory completeness_, address deployer_) {
        if (deployer_ == address(0)) revert V2Errors.ZeroAddress();

        // Fails closed before any state is recorded: an incomplete or drifted
        // catalogue can never become the published record for a deployment.
        V2EventCompleteness.validate(completeness_);

        _completenessVersion = completeness_.completenessVersion;
        _moduleCount = completeness_.moduleCount;
        _cellCount = completeness_.cellCount;
        _bindingCount = completeness_.bindingCount;
        _catalogueRoot = completeness_.catalogueRoot;
        _everyMutationEmits = completeness_.everyMutationEmits;
        _mutationsAreTerminal = completeness_.mutationsAreTerminal;
        _orderIsTotal = completeness_.orderIsTotal;
        _projectionIsDeterministic = completeness_.projectionIsDeterministic;

        CHAIN_ID = uint64(block.chainid);
        deployer = deployer_;

        emit EventCompletenessPublished(completeness_);
    }

    /// @inheritdoc IEventCompleteness
    function eventCompleteness() external view override returns (EventCompleteness memory) {
        return EventCompleteness({
            chainId: CHAIN_ID,
            completenessVersion: _completenessVersion,
            moduleCount: _moduleCount,
            cellCount: _cellCount,
            bindingCount: _bindingCount,
            catalogueRoot: _catalogueRoot,
            everyMutationEmits: _everyMutationEmits,
            mutationsAreTerminal: _mutationsAreTerminal,
            orderIsTotal: _orderIsTotal,
            projectionIsDeterministic: _projectionIsDeterministic
        });
    }

    /// @inheritdoc IEventCompleteness
    function cellCoverage(uint256 cursor, uint256 limit) external view override returns (CellCoverage[] memory page) {
        if (limit == 0 || limit > V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE) {
            revert V2EventCompleteness.InvalidPageLimit(limit);
        }
        if (cursor >= _cellCount) revert V2EventCompleteness.IndexOutOfRange(cursor);

        uint256 end = cursor + limit;
        if (end > _cellCount) end = _cellCount;

        // Bounded by the caller-supplied, on-chain-capped page size: never a
        // full-catalogue allocation, and never an unbounded loop.
        page = new CellCoverage[](end - cursor);
        for (uint256 i = cursor; i < end;) {
            page[i - cursor] = CellCoverage({
                cellId: V2EventCompleteness.cellIdOf(i),
                moduleId: V2EventCompleteness.moduleOf(i),
                cellIndex: i,
                coverage: V2EventCompleteness.coverageOf(i),
                closingEventCount: V2EventCompleteness.closingEventsOf(i).length,
                closingSetRoot: V2EventCompleteness.closingSetRootOf(i),
                reductionRuleId: V2EventCompleteness.reductionRuleIdOf(i),
                restatementCount: V2EventCompleteness.restatementsOf(i).length,
                restatementSetRoot: V2EventCompleteness.restatementSetRootOf(i)
            });
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IEventCompleteness
    function moduleCoverage(uint256 index) external view override returns (ModuleCoverage memory) {
        if (index >= _moduleCount) revert V2EventCompleteness.IndexOutOfRange(index);
        return ModuleCoverage({
            moduleId: V2EventCompleteness.moduleIdOf(index),
            cellCount: V2EventCompleteness.cellCountOfModule(index),
            everyMutationEmits: V2EventCompleteness.everyMutationEmitsOfModule(index),
            isImmutable: V2EventCompleteness.isImmutableModule(index)
        });
    }

    /// @notice Canonical sources of one cell in a single call.
    /// @dev Convenience passthrough so a consumer can resolve one cell without
    ///      paging. `closingEvents` are the mutually exclusive sources replay
    ///      MUST apply; `restatements` describe the same deltas and MUST NOT be
    ///      applied as sources. `reductionRuleId` is `bytes32(0)` for Direct
    ///      cells and non-zero for every Aggregate or Derived cell.
    function cellSources(uint256 index)
        external
        view
        returns (bytes32[] memory closingEvents, bytes32[] memory restatements, bytes32 reductionRuleId, bool covered)
    {
        if (index >= _cellCount) revert V2EventCompleteness.IndexOutOfRange(index);
        closingEvents = V2EventCompleteness.closingEventsOf(index);
        restatements = V2EventCompleteness.restatementsOf(index);
        reductionRuleId = V2EventCompleteness.reductionRuleIdOf(index);
        covered = V2EventCompleteness.isCellComplete(index);
    }

    /// @notice Returns the coverage posting of the catalogue as a whole.
    /// @dev Executes the machine-checked half of the completeness claim
    ///      (`V2EventCompleteness.assertCatalogueComplete`) on demand, so a
    ///      consumer can re-prove closure instead of trusting the record.
    function proveCatalogueComplete() external pure returns (bool) {
        V2EventCompleteness.assertCatalogueComplete();
        return true;
    }

    /// @notice Immutable protocol version marker shared by canonical V2 modules.
    function protocolVersion() external pure returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    /// @notice ERC-165: advertises IV2Module, IEventCompleteness, and ERC-165.
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IV2Module).interfaceId || interfaceId == type(IEventCompleteness).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
