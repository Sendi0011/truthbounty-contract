// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { EventCompletenessAnchor } from "../../contracts/v2/EventCompletenessAnchor.sol";
import { IEventCompleteness } from "../../contracts/v2/interfaces/IEventCompleteness.sol";
import { IV2Module } from "../../contracts/v2/interfaces/IV2Module.sol";
import { V2Errors } from "../../contracts/v2/libraries/V2Errors.sol";
import { V2EventCompleteness } from "../../contracts/v2/libraries/V2EventCompleteness.sol";

/// @title EventCompletenessTest
/// @notice V2-SC-132 unit coverage for the canonical event-completeness
///         catalogue and its read-only publication anchor: positive publication
///         surface, fail-closed validation of every record field, bounded
///         pagination, and ordered projection-fold determinism.
contract EventCompletenessTest is Test {
    uint64 internal constant CHAIN_ID = 11155420;

    EventCompletenessAnchor internal anchor;
    address internal deployer = address(0xDEAD);

    function setUp() public {
        vm.chainId(CHAIN_ID);
        anchor = new EventCompletenessAnchor(V2EventCompleteness.defaultRecord(CHAIN_ID), deployer);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mutableDefault() internal pure returns (IEventCompleteness.EventCompleteness memory) {
        return V2EventCompleteness.defaultRecord(CHAIN_ID);
    }

    // =========================================================================
    // Positive: the canonical record and its publication
    // =========================================================================

    function test_DefaultRecordIsValid() public view {
        V2EventCompleteness.validate(V2EventCompleteness.defaultRecord(CHAIN_ID));
    }

    function test_DefaultRecordTotals() public pure {
        IEventCompleteness.EventCompleteness memory r = V2EventCompleteness.defaultRecord(CHAIN_ID);
        assertEq(r.chainId, CHAIN_ID);
        assertEq(r.completenessVersion, V2EventCompleteness.COMPLETENESS_VERSION);
        assertEq(r.moduleCount, V2EventCompleteness.moduleCount());
        assertEq(r.cellCount, V2EventCompleteness.cellCount());
        assertEq(r.bindingCount, V2EventCompleteness.bindingCount());
        assertEq(r.catalogueRoot, V2EventCompleteness.catalogueRoot());
        assertTrue(r.everyMutationEmits);
        assertTrue(r.mutationsAreTerminal);
        assertTrue(r.orderIsTotal);
        assertTrue(r.projectionIsDeterministic);
    }

    function test_CatalogueIsComplete() public pure {
        V2EventCompleteness.assertCatalogueComplete();
        uint256 count = V2EventCompleteness.cellCount();
        assertGt(count, 0, "catalogue must not be empty");
        assertLe(count, V2EventCompleteness.MAX_CELLS, "catalogue must stay bounded");

        uint256 total;
        uint256 restatements;
        for (uint256 i; i < count; ++i) {
            assertTrue(V2EventCompleteness.isCellComplete(i), "every cell needs a closing event");
            assertTrue(V2EventCompleteness.closingSetRootOf(i) != bytes32(0), "closing set must commit");
            assertLe(
                V2EventCompleteness.closingEventsOf(i).length,
                V2EventCompleteness.MAX_CLOSING_EVENTS,
                "closing set must stay bounded"
            );
            assertLe(
                V2EventCompleteness.restatementsOf(i).length,
                V2EventCompleteness.MAX_RESTATEMENTS,
                "restatement set must stay bounded"
            );
            // A non-empty restatement set must commit; an empty one is zero.
            if (V2EventCompleteness.restatementsOf(i).length == 0) {
                assertEq(V2EventCompleteness.restatementSetRootOf(i), bytes32(0), "empty set must not commit");
            } else {
                assertTrue(V2EventCompleteness.restatementSetRootOf(i) != bytes32(0), "restatement set must commit");
            }
            total += V2EventCompleteness.closingEventsOf(i).length;
            restatements += V2EventCompleteness.restatementsOf(i).length;
        }
        assertEq(total, V2EventCompleteness.bindingCount());
        assertLe(total, V2EventCompleteness.MAX_BINDINGS, "catalogue must stay bounded");
        // Restatements exist precisely because the catalogue had to disambiguate
        // double-counting risks; an all-zero count would mean the discipline is
        // declared but never exercised.
        assertGt(restatements, 0, "the catalogue must exercise the restatement path");
    }

    function test_RestatementsAreDisjointFromClosingEvents() public pure {
        uint256 count = V2EventCompleteness.cellCount();
        for (uint256 i; i < count; ++i) {
            bytes32[] memory closing = V2EventCompleteness.closingEventsOf(i);
            bytes32[] memory restated = V2EventCompleteness.restatementsOf(i);
            for (uint256 a; a < closing.length; ++a) {
                for (uint256 b; b < restated.length; ++b) {
                    assertTrue(closing[a] != restated[b], "a source must never be a restatement");
                }
            }
        }
    }

    function test_CoverageAndReductionRuleAreCoherent() public pure {
        uint256 count = V2EventCompleteness.cellCount();
        uint256 aggregates;
        uint256 derived;
        for (uint256 i; i < count; ++i) {
            uint8 coverage = V2EventCompleteness.coverageOf(i);
            assertLe(coverage, uint8(IEventCompleteness.Coverage.Derived), "coverage must be in range");

            bytes32 rule = V2EventCompleteness.reductionRuleIdOf(i);
            if (coverage == uint8(IEventCompleteness.Coverage.Direct)) {
                assertEq(rule, bytes32(0), "a direct cell must not publish a rule");
            } else {
                assertTrue(rule != bytes32(0), "a non-direct cell must publish its rule");
                if (coverage == uint8(IEventCompleteness.Coverage.Aggregate)) {
                    ++aggregates;
                } else {
                    ++derived;
                }
            }
        }
        assertGt(aggregates, 0, "the catalogue must exercise the aggregate path");
        assertGt(derived, 0, "the catalogue must exercise the derived path");
    }

    function test_CellIdentitiesAreUnique() public pure {
        uint256 count = V2EventCompleteness.cellCount();
        for (uint256 i; i < count; ++i) {
            for (uint256 j = i + 1; j < count; ++j) {
                assertTrue(
                    V2EventCompleteness.cellIdOf(i) != V2EventCompleteness.cellIdOf(j), "cell identities must be unique"
                );
            }
        }
    }

    function test_ModuleCellCountsPartitionTheCatalogue() public pure {
        uint256 sum;
        for (uint256 m; m < V2EventCompleteness.moduleCount(); ++m) {
            sum += V2EventCompleteness.cellCountOfModule(m);
        }
        assertEq(sum, V2EventCompleteness.cellCount());
        assertEq(V2EventCompleteness.moduleCount(), 8, "canonical module count");
    }

    function test_ImmutableModulesCarryNoCells() public pure {
        for (uint256 m; m < V2EventCompleteness.moduleCount(); ++m) {
            if (V2EventCompleteness.isImmutableModule(m)) {
                assertEq(V2EventCompleteness.cellCountOfModule(m), 0, "an immutable module has no mutable cells");
                assertTrue(V2EventCompleteness.everyMutationEmitsOfModule(m), "vacuously complete");
            } else {
                assertGt(V2EventCompleteness.cellCountOfModule(m), 0, "a mutable module must own cells");
            }
        }
    }

    function test_AnchorPublishesRecordVerbatim() public view {
        IEventCompleteness.EventCompleteness memory published = anchor.eventCompleteness();
        IEventCompleteness.EventCompleteness memory expected = V2EventCompleteness.defaultRecord(CHAIN_ID);

        assertEq(published.chainId, expected.chainId);
        assertEq(published.completenessVersion, expected.completenessVersion);
        assertEq(published.moduleCount, expected.moduleCount);
        assertEq(published.cellCount, expected.cellCount);
        assertEq(published.bindingCount, expected.bindingCount);
        assertEq(published.catalogueRoot, expected.catalogueRoot);
        assertTrue(published.everyMutationEmits);
        assertTrue(published.mutationsAreTerminal);
        assertTrue(published.orderIsTotal);
        assertTrue(published.projectionIsDeterministic);
    }

    function test_ConstructorEmitsPublicationEvent() public {
        IEventCompleteness.EventCompleteness memory r = V2EventCompleteness.defaultRecord(CHAIN_ID);
        vm.chainId(31337);
        vm.expectEmit(true, true, true, true);
        emit IEventCompleteness.EventCompletenessPublished(r);
        new EventCompletenessAnchor(r, deployer);
    }

    function test_ChainIdBoundAtDeployment() public view {
        assertEq(anchor.CHAIN_ID(), CHAIN_ID);
    }

    function test_DeployerProvenanceRecorded() public view {
        assertEq(anchor.deployer(), deployer);
    }

    function test_ProtocolVersionIsV2() public view {
        (uint16 major, uint16 minor) = anchor.protocolVersion();
        assertEq(major, 2);
        assertEq(minor, 0);
    }

    function test_SupportsInterfaceSurface() public view {
        assertTrue(anchor.supportsInterface(type(IEventCompleteness).interfaceId));
        assertTrue(anchor.supportsInterface(type(IV2Module).interfaceId));
        assertTrue(anchor.supportsInterface(type(IERC165).interfaceId));
        assertFalse(anchor.supportsInterface(0xffffffff), "wildcard must be rejected");
    }

    function test_ProveCatalogueCompleteOnDemand() public view {
        assertTrue(anchor.proveCatalogueComplete());
    }

    // =========================================================================
    // Positive: bounded pagination of the catalogue
    // =========================================================================

    function test_CellCoveragePagesWholeCatalogue() public view {
        uint256 total = anchor.eventCompleteness().cellCount;
        uint256 seen;

        for (uint256 cursor; cursor < total; cursor += V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE) {
            IEventCompleteness.CellCoverage[] memory page =
                anchor.cellCoverage(cursor, V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE);
            assertLe(page.length, V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE, "page must respect the on-chain cap");
            for (uint256 i; i < page.length; ++i) {
                uint256 index = cursor + i;
                assertEq(page[i].cellIndex, index);
                assertEq(page[i].cellId, V2EventCompleteness.cellIdOf(index));
                assertEq(page[i].moduleId, V2EventCompleteness.moduleOf(index));
                assertEq(page[i].coverage, V2EventCompleteness.coverageOf(index));
                assertEq(page[i].closingEventCount, V2EventCompleteness.closingEventsOf(index).length);
                assertEq(page[i].closingSetRoot, V2EventCompleteness.closingSetRootOf(index));
                assertEq(page[i].reductionRuleId, V2EventCompleteness.reductionRuleIdOf(index));
                assertEq(page[i].restatementCount, V2EventCompleteness.restatementsOf(index).length);
                assertEq(page[i].restatementSetRoot, V2EventCompleteness.restatementSetRootOf(index));
                assertGt(page[i].closingEventCount, 0, "no uncovered cell may be published");
                ++seen;
            }
        }
        assertEq(seen, total, "paging must cover every cell exactly once");
    }

    function test_CellCoverageLastPageIsClampedToCatalogue() public view {
        uint256 total = anchor.eventCompleteness().cellCount;
        uint256 cursor = total - 1;
        IEventCompleteness.CellCoverage[] memory page =
            anchor.cellCoverage(cursor, V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE);
        assertEq(page.length, 1, "the final page must clamp, never over-read");
    }

    function test_CellSourcesPassthrough() public view {
        uint256 index = V2EventCompleteness.CELL_VAULT_CLAIMABLE;
        (bytes32[] memory closing, bytes32[] memory restated, bytes32 ruleId, bool covered) = anchor.cellSources(index);
        assertTrue(covered);
        assertEq(closing, V2EventCompleteness.closingEventsOf(index));
        assertEq(restated, V2EventCompleteness.restatementsOf(index));
        assertEq(ruleId, V2EventCompleteness.reductionRuleIdOf(index));
        // The claimable cell is the canonical double-count hazard: the summary
        // settlement emission restates the primitives, so it must be published
        // as a cross-check and never as a source.
        assertGt(restated.length, 0, "the claimable cell must publish its restatement");
        assertEq(ruleId, bytes32(0), "a direct cell publishes no reduction rule");
    }

    function test_CellSourcesPublishesDerivedRule() public view {
        (,, bytes32 ruleId,) = anchor.cellSources(V2EventCompleteness.CELL_VAULT_SETTLEMENT_OUTCOME);
        assertEq(ruleId, V2EventCompleteness.RULE_SETTLEMENT_OUTCOME_FROM_EVENT);
    }

    function test_ModuleCoverageEnumeratesCanonicalModules() public view {
        uint256 moduleCount = anchor.eventCompleteness().moduleCount;
        bytes32[] memory seen = new bytes32[](moduleCount);
        for (uint256 i; i < moduleCount; ++i) {
            IEventCompleteness.ModuleCoverage memory m = anchor.moduleCoverage(i);
            assertEq(m.moduleId, V2EventCompleteness.moduleIdOf(i));
            assertEq(m.cellCount, V2EventCompleteness.cellCountOfModule(i));
            assertEq(m.isImmutable, V2EventCompleteness.isImmutableModule(i));
            assertTrue(m.everyMutationEmits);
            seen[i] = m.moduleId;
        }
        // Module identities are unique, so a consumer can key a projection by them.
        for (uint256 i; i < seen.length; ++i) {
            for (uint256 j = i + 1; j < seen.length; ++j) {
                assertTrue(seen[i] != seen[j], "module identities must be unique");
            }
        }
    }

    // =========================================================================
    // Negative: fail-closed publication
    // =========================================================================

    function test_RevertWhen_DeployerZeroAddress() public {
        vm.expectRevert(V2Errors.ZeroAddress.selector);
        new EventCompletenessAnchor(V2EventCompleteness.defaultRecord(CHAIN_ID), address(0));
    }

    function test_RevertWhen_ChainIdZero() public {
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "chainId must be non-zero"));
        new EventCompletenessAnchor(V2EventCompleteness.defaultRecord(0), deployer);
    }

    function test_RevertWhen_CompletenessVersionDrifts() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.completenessVersion = V2EventCompleteness.COMPLETENESS_VERSION + 1;
        vm.expectRevert(
            abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "unsupported completeness version")
        );
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_ModuleCountDrifts() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.moduleCount = r.moduleCount + 1;
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "moduleCount drift"));
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_CellCountDrifts() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.cellCount = r.cellCount - 1;
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "cellCount drift"));
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_BindingCountDrifts() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.bindingCount = r.bindingCount + 1;
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "bindingCount drift"));
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_CatalogueRootDrifts() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.catalogueRoot = keccak256("tampered catalogue");
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "catalogueRoot drift"));
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_EveryMutationEmitsIsFalse() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.everyMutationEmits = false;
        vm.expectRevert(
            abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "every authoritative mutation must emit")
        );
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_MutationsAreTerminalIsFalse() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.mutationsAreTerminal = false;
        vm.expectRevert(
            abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "mutations must be terminal on emission")
        );
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_OrderIsTotalIsFalse() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.orderIsTotal = false;
        vm.expectRevert(
            abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "canonical order must be total")
        );
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_ProjectionIsDeterministicIsFalse() public {
        IEventCompleteness.EventCompleteness memory r = _mutableDefault();
        r.projectionIsDeterministic = false;
        vm.expectRevert(
            abi.encodeWithSelector(
                V2EventCompleteness.InvalidRecord.selector, "projection replay must be deterministic"
            )
        );
        new EventCompletenessAnchor(r, deployer);
    }

    function test_RevertWhen_ZeroedRecord() public {
        IEventCompleteness.EventCompleteness memory r;
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.InvalidRecord.selector, "chainId must be non-zero"));
        new EventCompletenessAnchor(r, deployer);
    }

    // =========================================================================
    // Negative: bounded reads
    // =========================================================================

    function test_RevertWhen_PageLimitIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.InvalidPageLimit.selector, 0));
        anchor.cellCoverage(0, 0);
    }

    function test_RevertWhen_PageLimitExceedsCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                V2EventCompleteness.InvalidPageLimit.selector, V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE + 1
            )
        );
        anchor.cellCoverage(0, V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE + 1);
    }

    function test_RevertWhen_CursorOutOfRange() public {
        uint256 total = anchor.eventCompleteness().cellCount;
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.IndexOutOfRange.selector, total));
        anchor.cellCoverage(total, 1);
    }

    function test_RevertWhen_ModuleIndexOutOfRange() public {
        uint256 total = anchor.eventCompleteness().moduleCount;
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.IndexOutOfRange.selector, total));
        anchor.moduleCoverage(total);
    }

    function test_RevertWhen_CellIndexOutOfRangeInLibrary() public {
        CompletenessHarness harness = new CompletenessHarness();
        uint256 out = V2EventCompleteness.cellCount();
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.IndexOutOfRange.selector, out));
        harness.closingEventsOf(out);
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.IndexOutOfRange.selector, out));
        harness.cellIdOf(out);
    }

    function test_RevertWhen_CellIndexOutOfRangeInPassthrough() public {
        uint256 out = anchor.eventCompleteness().cellCount;
        vm.expectRevert(abi.encodeWithSelector(V2EventCompleteness.IndexOutOfRange.selector, out));
        anchor.cellSources(out);
    }

    // =========================================================================
    // Replay: the ordered projection fold
    // =========================================================================

    function test_FoldIsDeterministic() public pure {
        bytes32 a = V2EventCompleteness.replayFold(V2EventCompleteness.EMPTY_FOLD, keccak256("log-a"));
        bytes32 b = V2EventCompleteness.replayFold(a, keccak256("log-b"));
        assertTrue(b != V2EventCompleteness.EMPTY_FOLD, "fold must advance");
        assertTrue(V2EventCompleteness.isFoldCanonical(V2EventCompleteness.EMPTY_FOLD, keccak256("log-a"), a));
        assertTrue(!V2EventCompleteness.isFoldCanonical(a, keccak256("log-b"), keccak256("wrong")));
    }

    function test_FoldIsOrderSensitive() public pure {
        bytes32 keyA = keccak256("log-a");
        bytes32 keyB = keccak256("log-b");
        bytes32 ab =
            V2EventCompleteness.replayFold(V2EventCompleteness.replayFold(V2EventCompleteness.EMPTY_FOLD, keyA), keyB);
        bytes32 ba =
            V2EventCompleteness.replayFold(V2EventCompleteness.replayFold(V2EventCompleteness.EMPTY_FOLD, keyB), keyA);
        assertTrue(ab != ba, "a reordering must be detectable as a root mismatch");
    }

    function test_EmptyFoldIsAConstant() public pure {
        assertEq(
            V2EventCompleteness.EMPTY_FOLD, keccak256("TRUTHBOUNTY.V2.EVENT_COMPLETENESS.EMPTY_FOLD.v1"), "seed drift"
        );
    }
}

/// @notice External harness so the library's own bounds can be exercised: an
///         internal library call is inlined into the caller and cannot produce
///         the external revert a consumer would observe.
contract CompletenessHarness {
    function closingEventsOf(uint256 index) external pure returns (bytes32[] memory) {
        return V2EventCompleteness.closingEventsOf(index);
    }

    function cellIdOf(uint256 index) external pure returns (bytes32) {
        return V2EventCompleteness.cellIdOf(index);
    }
}
