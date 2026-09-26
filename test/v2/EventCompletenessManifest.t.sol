// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { EventCompletenessAnchor } from "../../contracts/v2/EventCompletenessAnchor.sol";
import { IEventCompleteness } from "../../contracts/v2/interfaces/IEventCompleteness.sol";
import { V2EventCompleteness } from "../../contracts/v2/libraries/V2EventCompleteness.sol";

/// @title EventCompletenessManifest
/// @notice Deployment-artifact drift validation for V2-SC-132. The published
///         manifest at deployments/config/event-completeness.json must agree
///         field-by-field with the catalogue the library actually enumerates:
///         totals, catalogue root, and every per-cell identity, coverage class,
///         reduction rule, closing set and restatement set.
/// @dev An off-chain consumer is only as trustworthy as the pinned catalogue it
///      replays. If a maintainer adds a cell, reclassifies a cell, or moves an
///      emission between a cell's closing set and its restatement set without
///      regenerating the manifest, this suite fails here rather than silently at
///      a consumer's replay.
contract EventCompletenessManifestTest is Test {
    ManifestJsonProbe internal probe;

    string internal manifestJson;

    function setUp() public {
        // forge-repo-root relative path: the manifest is validated exactly as
        // committed, not as a copy under a test fixture directory.
        manifestJson = vm.readFile("deployments/config/event-completeness.json");
        probe = new ManifestJsonProbe();
    }

    function _element(string memory path, uint256 index) internal pure returns (string memory) {
        return string.concat(path, "[", vm.toString(index), "]");
    }

    function _list(string memory path) internal view returns (string[] memory) {
        return abi.decode(vm.parseJson(manifestJson, path), (string[]));
    }

    function _resolves(string memory path) internal view returns (bool) {
        (bool ok,) = address(probe).staticcall(abi.encodeCall(ManifestJsonProbe.probeUint, (manifestJson, path)));
        return ok;
    }

    // =========================================================================
    // Manifest identity and totals
    // =========================================================================

    function test_ManifestExistsAndParses() public view {
        assertTrue(bytes(manifestJson).length > 0, "manifest must not be empty");
        assertEq(vm.parseJsonUint(manifestJson, ".manifestVersion"), 1);
        assertEq(vm.parseJsonString(manifestJson, ".issue"), "V2-SC-132");
        assertEq(vm.parseJsonUint(manifestJson, ".chainId"), 11155420);
        assertEq(
            vm.parseJsonString(manifestJson, ".specification"),
            "TruthBounty Canonical V2 Event Completeness for Projection Replay (docs/v2/event-completeness-projection-replay.md)"
        );
        assertEq(
            vm.parseJsonString(manifestJson, ".catalogue"),
            "contracts/v2/libraries/V2EventCompleteness.sol",
            "the manifest must name the catalogue it mirrors"
        );
    }

    function test_ManifestTotalsMatchCatalogue() public view {
        assertEq(
            vm.parseJsonUint(manifestJson, ".completeness.completenessVersion"),
            V2EventCompleteness.COMPLETENESS_VERSION,
            "completenessVersion drift"
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".completeness.moduleCount"),
            V2EventCompleteness.moduleCount(),
            "moduleCount drift"
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".completeness.cellCount"),
            V2EventCompleteness.cellCount(),
            "cellCount drift"
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".completeness.bindingCount"),
            V2EventCompleteness.bindingCount(),
            "bindingCount drift"
        );
        assertEq(
            bytes32(vm.parseJsonBytes32(manifestJson, ".completeness.catalogueRoot")),
            V2EventCompleteness.catalogueRoot(),
            "catalogueRoot drift"
        );
        assertTrue(vm.parseJsonBool(manifestJson, ".completeness.everyMutationEmits"));
        assertTrue(vm.parseJsonBool(manifestJson, ".completeness.mutationsAreTerminal"));
        assertTrue(vm.parseJsonBool(manifestJson, ".completeness.orderIsTotal"));
        assertTrue(vm.parseJsonBool(manifestJson, ".completeness.projectionIsDeterministic"));
    }

    function test_ManifestRestatementTotalMatchesCatalogue() public view {
        uint256 expected;
        for (uint256 i; i < V2EventCompleteness.cellCount(); ++i) {
            expected += V2EventCompleteness.restatementsOf(i).length;
        }
        assertEq(vm.parseJsonUint(manifestJson, ".completeness.restatementCount"), expected, "restatementCount drift");
    }

    function test_ManifestCoverageVocabularyMatchesEnum() public view {
        assertEq(
            vm.parseJsonUint(manifestJson, ".coverageVocabulary.Direct"), uint8(IEventCompleteness.Coverage.Direct)
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".coverageVocabulary.Aggregate"),
            uint8(IEventCompleteness.Coverage.Aggregate)
        );
        assertEq(
            vm.parseJsonUint(manifestJson, ".coverageVocabulary.Derived"), uint8(IEventCompleteness.Coverage.Derived)
        );
    }

    // =========================================================================
    // Modules
    // =========================================================================

    function test_ManifestModulesMatchCatalogue() public view {
        uint256 count = V2EventCompleteness.moduleCount();
        uint256 cells;

        for (uint256 i; i < count; ++i) {
            string memory row = _element(".modules", i);
            assertEq(vm.parseJsonUint(manifestJson, string.concat(row, ".index")), i, "module order drift");
            assertEq(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".moduleId"))),
                V2EventCompleteness.moduleIdOf(i),
                "moduleId drift"
            );
            assertEq(
                vm.parseJsonUint(manifestJson, string.concat(row, ".cellCount")),
                V2EventCompleteness.cellCountOfModule(i),
                "module cellCount drift"
            );
            assertTrue(vm.parseJsonBool(manifestJson, string.concat(row, ".everyMutationEmits")));
            assertEq(
                vm.parseJsonBool(manifestJson, string.concat(row, ".isImmutable")),
                V2EventCompleteness.isImmutableModule(i),
                "immutability drift"
            );
            assertFalse(bytes(vm.parseJsonString(manifestJson, string.concat(row, ".module"))).length == 0);
            cells += V2EventCompleteness.cellCountOfModule(i);
        }

        // A cell claimed by two modules, or by none, breaks the partition the
        // catalogue relies on.
        assertEq(cells, V2EventCompleteness.cellCount(), "module cell counts must partition the catalogue");
    }

    function test_ManifestHasNoExtraModuleRow() public view {
        assertFalse(_resolves(_element(".modules", V2EventCompleteness.moduleCount())), "manifest over-claims a module");
    }

    // =========================================================================
    // Cells
    // =========================================================================

    function test_ManifestCellsMatchCatalogue() public view {
        uint256 count = V2EventCompleteness.cellCount();

        for (uint256 i; i < count; ++i) {
            string memory row = _element(".cells", i);
            assertEq(vm.parseJsonUint(manifestJson, string.concat(row, ".index")), i, "cell order drift");
            assertEq(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".cellId"))),
                V2EventCompleteness.cellIdOf(i),
                "cellId drift"
            );
            assertEq(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".moduleId"))),
                V2EventCompleteness.moduleOf(i),
                "cell moduleId drift"
            );
            assertEq(
                vm.parseJsonUint(manifestJson, string.concat(row, ".coverageOrdinal")),
                uint256(V2EventCompleteness.coverageOf(i)),
                "coverage drift"
            );
            assertEq(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".reductionRuleId"))),
                V2EventCompleteness.reductionRuleIdOf(i),
                "reductionRuleId drift"
            );
            assertEq(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".closingSetRoot"))),
                V2EventCompleteness.closingSetRootOf(i),
                "closingSetRoot drift"
            );
            assertEq(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".restatementSetRoot"))),
                V2EventCompleteness.restatementSetRootOf(i),
                "restatementSetRoot drift"
            );
            assertFalse(bytes(vm.parseJsonString(manifestJson, string.concat(row, ".module"))).length == 0);
            assertFalse(bytes(vm.parseJsonString(manifestJson, string.concat(row, ".readSurface"))).length == 0);
            assertFalse(bytes(vm.parseJsonString(manifestJson, string.concat(row, ".coverage"))).length == 0);
        }
    }

    function test_ManifestHasExactlyOneRowPerCatalogueCell() public view {
        // A trailing row would let the manifest advertise a cell the library
        // does not enumerate, which is precisely the drift a consumer must not
        // be able to miss.
        assertFalse(_resolves(_element(".cells", V2EventCompleteness.cellCount())), "manifest over-claims a cell");
    }

    function test_ManifestCoverageAndRuleAreCoherent() public view {
        uint256 count = V2EventCompleteness.cellCount();

        for (uint256 i; i < count; ++i) {
            uint8 coverage = V2EventCompleteness.coverageOf(i);
            bytes32 ruleId = V2EventCompleteness.reductionRuleIdOf(i);
            bool direct = coverage == uint8(IEventCompleteness.Coverage.Direct);

            assertEq(direct, ruleId == bytes32(0), "a Direct cell publishes no rule, and no other cell omits one");
            if (!direct) {
                // Every non-Direct rule must be named in the manifest
                // vocabulary, so a consumer can resolve the reduction by name
                // instead of re-deriving it from prose.
                assertTrue(_publishesRule(ruleId), "an unpublished reduction rule is unresolvable off-chain");
            }
        }
    }

    function _publishesRule(bytes32 ruleId) internal view returns (bool) {
        uint256 published = _ruleCount();
        for (uint256 i; i < published; ++i) {
            if (
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(_element(".reductionRules", i), ".id")))
                    == ruleId
            ) {
                return true;
            }
        }
        return false;
    }

    function _ruleCount() internal view returns (uint256) {
        uint256 count;
        while (_resolves(string.concat(_element(".reductionRules", count), ".id"))) {
            ++count;
        }
        return count;
    }

    function test_ManifestReductionRuleVocabularyIsPinned() public view {
        uint256 count = _ruleCount();
        assertEq(count, 8, "the catalogue publishes eight reduction rules");
        for (uint256 i; i < count; ++i) {
            string memory row = _element(".reductionRules", i);
            assertFalse(bytes(vm.parseJsonString(manifestJson, string.concat(row, ".name"))).length == 0);
            assertTrue(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".id")))
                    == keccak256(bytes(vm.parseJsonString(manifestJson, string.concat(row, ".name")))),
                "a rule id must be the keccak of its published name"
            );
        }
    }

    // =========================================================================
    // Event sets
    // =========================================================================

    function test_ManifestEventSetsMatchCatalogue() public view {
        uint256 count = V2EventCompleteness.cellCount();
        uint256 closingTotal;
        uint256 restatementTotal;

        for (uint256 i; i < count; ++i) {
            string memory row = _element(".cells", i);
            bytes32[] memory closing = V2EventCompleteness.closingEventsOf(i);
            bytes32[] memory restated = V2EventCompleteness.restatementsOf(i);
            string[] memory publishedClosing = _list(string.concat(row, ".closingEvents"));
            string[] memory publishedRestated = _list(string.concat(row, ".restatements"));

            assertGt(closing.length, 0, "no cell may publish an empty closing set");
            assertEq(publishedClosing.length, closing.length, "closing set size drift");
            assertEq(publishedRestated.length, restated.length, "restatement set size drift");

            for (uint256 a; a < closing.length; ++a) {
                assertEq(keccak256(bytes(publishedClosing[a])), closing[a], "closing set drift or reorder");
            }
            for (uint256 a; a < restated.length; ++a) {
                assertEq(keccak256(bytes(publishedRestated[a])), restated[a], "restatement set drift or reorder");
            }
            closingTotal += closing.length;
            restatementTotal += restated.length;
        }

        assertEq(closingTotal, V2EventCompleteness.bindingCount(), "binding total drift");
        assertEq(restatementTotal, vm.parseJsonUint(manifestJson, ".completeness.restatementCount"));
    }

    function test_ManifestEventSetsAreExhaustivelyNamed() public view {
        uint256 count = V2EventCompleteness.cellCount();
        for (uint256 i; i < count; ++i) {
            string memory row = _element(".cells", i);
            // One past the end of each set must not resolve: a manifest that
            // names more events than the catalogue binds over-claims coverage.
            assertFalse(
                _resolves(
                    string.concat(
                        row, ".closingEvents[", vm.toString(V2EventCompleteness.closingEventsOf(i).length), "]"
                    )
                ),
                "manifest names more closing events than the catalogue binds"
            );
            assertFalse(
                _resolves(
                    string.concat(row, ".restatements[", vm.toString(V2EventCompleteness.restatementsOf(i).length), "]")
                ),
                "manifest names more restatements than the catalogue binds"
            );
        }
    }

    function test_ManifestNeverListsASourceAsARestatement() public view {
        uint256 count = V2EventCompleteness.cellCount();
        for (uint256 i; i < count; ++i) {
            string memory row = _element(".cells", i);
            string[] memory closing = _list(string.concat(row, ".closingEvents"));
            string[] memory restated = _list(string.concat(row, ".restatements"));

            for (uint256 b; b < restated.length; ++b) {
                for (uint256 a; a < closing.length; ++a) {
                    assertTrue(
                        keccak256(bytes(restated[b])) != keccak256(bytes(closing[a])),
                        "a restatement must never also be a source for the same cell"
                    );
                }
            }
        }
    }

    function test_ManifestExercisesTheRestatementPath() public view {
        // The discipline is only meaningful if the catalogue actually has
        // double-count hazards to disambiguate.
        uint256 restatements;
        for (uint256 i; i < V2EventCompleteness.cellCount(); ++i) {
            restatements += V2EventCompleteness.restatementsOf(i).length;
        }
        assertGt(restatements, 0);
    }

    // =========================================================================
    // Publication
    // =========================================================================

    function test_ManifestRecordPublishesThroughTheAnchor() public {
        IEventCompleteness.EventCompleteness memory record = IEventCompleteness.EventCompleteness({
            chainId: uint64(vm.parseJsonUint(manifestJson, ".chainId")),
            completenessVersion: uint16(vm.parseJsonUint(manifestJson, ".completeness.completenessVersion")),
            moduleCount: vm.parseJsonUint(manifestJson, ".completeness.moduleCount"),
            cellCount: vm.parseJsonUint(manifestJson, ".completeness.cellCount"),
            bindingCount: vm.parseJsonUint(manifestJson, ".completeness.bindingCount"),
            catalogueRoot: bytes32(vm.parseJsonBytes32(manifestJson, ".completeness.catalogueRoot")),
            everyMutationEmits: vm.parseJsonBool(manifestJson, ".completeness.everyMutationEmits"),
            mutationsAreTerminal: vm.parseJsonBool(manifestJson, ".completeness.mutationsAreTerminal"),
            orderIsTotal: vm.parseJsonBool(manifestJson, ".completeness.orderIsTotal"),
            projectionIsDeterministic: vm.parseJsonBool(manifestJson, ".completeness.projectionIsDeterministic")
        });

        // Must not revert: the published manifest always describes a
        // self-consistent, closed catalogue.
        V2EventCompleteness.validate(record);

        vm.chainId(record.chainId);
        EventCompletenessAnchor anchor = new EventCompletenessAnchor(record, address(this));
        IEventCompleteness.EventCompleteness memory published = anchor.eventCompleteness();
        assertEq(published.catalogueRoot, record.catalogueRoot);
        assertEq(published.bindingCount, record.bindingCount);
        assertEq(published.cellCount, record.cellCount);
        assertEq(published.moduleCount, record.moduleCount);
    }

    function test_ManifestCatalogueRootIsNonTrivial() public view {
        bytes32 pinned = bytes32(vm.parseJsonBytes32(manifestJson, ".completeness.catalogueRoot"));
        assertEq(pinned, V2EventCompleteness.catalogueRoot());
        assertTrue(pinned != bytes32(0), "a zero catalogue root is not a commitment");
    }

    // =========================================================================
    // Non-canonical emissions
    // =========================================================================

    /// @dev "Quarantine unknown signatures" is only actionable if the emissions a
    ///      consumer is allowed to skip are published, not merely described in
    ///      prose. This pins the allow-list, and `ProjectionReplay.t.sol` pins it
    ///      again from the log side, so the two cannot drift apart silently.
    function test_ManifestPublishesNonCanonicalEmissions() public view {
        uint256 count = _nonCanonicalCount();
        assertEq(count, 8, "the manifest publishes every documented non-canonical emission");
        assertEq(count, vm.parseJsonUint(manifestJson, ".nonCanonicalEmissions.count"), "the published count matches");

        for (uint256 i; i < count; ++i) {
            string memory row = _element(".nonCanonicalEmissions.emissions", i);
            string memory signature = vm.parseJsonString(manifestJson, string.concat(row, ".signature"));
            assertFalse(bytes(signature).length == 0, "a non-canonical emission is published by signature");
            assertEq(
                bytes32(vm.parseJsonBytes32(manifestJson, string.concat(row, ".topic0"))),
                keccak256(bytes(signature)),
                "a published topic0 must be the keccak of its signature"
            );
            assertFalse(
                bytes(vm.parseJsonString(manifestJson, string.concat(row, ".reason"))).length == 0,
                "a non-canonical emission is published with its reason"
            );
        }
    }

    /// @dev A non-canonical emission must not also be a closing source: the
    ///      allow-list exists precisely because these logs are superseded.
    function test_NonCanonicalEmissionsCloseNoCell() public view {
        uint256 count = _nonCanonicalCount();
        uint256 cellCount = V2EventCompleteness.cellCount();

        for (uint256 i; i < count; ++i) {
            bytes32 topic0 = bytes32(
                vm.parseJsonBytes32(
                    manifestJson, string.concat(_element(".nonCanonicalEmissions.emissions", i), ".topic0")
                )
            );
            for (uint256 c; c < cellCount; ++c) {
                assertFalse(_closesCell(topic0, c), "an allow-listed non-canonical emission must not close a cell");
            }
        }
    }

    function _closesCell(bytes32 topic0, uint256 cellIndex) internal view returns (bool) {
        bytes32[] memory closing = V2EventCompleteness.closingEventsOf(cellIndex);
        for (uint256 i; i < closing.length; ++i) {
            if (closing[i] == topic0) return true;
        }
        return false;
    }

    function _nonCanonicalCount() internal view returns (uint256) {
        uint256 count;
        while (_resolves(string.concat(_element(".nonCanonicalEmissions.emissions", count), ".topic0"))) {
            ++count;
        }
        return count;
    }
}

/// @notice External JSON probe. A negative manifest assertion is made by asking
///         whether a path resolves at all, and a cheatcode failure is only
///         observable through a real external call.
contract ManifestJsonProbe {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function probeUint(string memory json, string memory path) external pure returns (uint256) {
        return vm.parseJsonUint(json, path);
    }
}
