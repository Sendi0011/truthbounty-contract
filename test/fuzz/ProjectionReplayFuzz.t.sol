// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { LogProjection, ReplayModuleRegistry } from "../v2/ProjectionReplay.t.sol";
import { StakeVault } from "../../contracts/v2/StakeVault.sol";
import { IV2Types } from "../../contracts/v2/interfaces/IV2Types.sol";
import { V2EventCompleteness } from "../../contracts/v2/libraries/V2EventCompleteness.sol";
import { MockERC20 } from "../../contracts/MockERC20.sol";

/// @title ProjectionReplayFuzzTest
/// @notice Property tests for the V2-SC-132 replay contract. The deterministic
///         scenario in `ProjectionReplay.t.sol` proves that one ordering of one
///         amount set replays; these prove the projection does not depend on the
///         amounts, the partial fills, or the actor set.
contract ProjectionReplayFuzzTest is Test {
    StakeVault internal vault;
    ReplayModuleRegistry internal registry;
    MockERC20 internal token;
    MockERC20 internal alt;

    address internal settlement = address(0xA001);
    address internal slashing = address(0xA002);

    uint256 internal constant CLAIM = 1;
    uint8 internal constant VERIFIER_PRINCIPAL = 1;
    uint8 internal constant CHALLENGE_BOND = 3;
    uint256 internal constant ACTORS = 3;
    uint256 internal constant ROUNDS = 5;
    uint256 internal constant SEED_BALANCE = 1_000_000 ether;

    struct Captured {
        address emitter;
        bytes32 topic0;
        bytes32[] topics;
        bytes data;
        uint256 blockNumber;
    }

    Captured[] internal captured;
    address[ACTORS] internal actors;
    uint256 internal nextBlock = 2;

    function setUp() public {
        registry = new ReplayModuleRegistry();
        token = new MockERC20("Stake", "STK");
        alt = new MockERC20("Alt", "ALT");
        actors = [address(0xB001), address(0xB002), address(0xB003)];

        // Administration and funding mutate read cells (0, 1, 2, 4), so they are
        // part of the recorded stream rather than test scaffolding.
        _begin();
        vault = new StakeVault(address(registry), address(token), address(this));
        vault.setSupportedAsset(address(alt), true);
        vault.setLockMutator(settlement, true);
        registry.registerModule(vault.MODULE_SETTLEMENT(), settlement);
        registry.registerModule(vault.MODULE_SLASHING(), slashing);
        for (uint256 i; i < ACTORS; ++i) {
            token.mint(actors[i], SEED_BALANCE);
            alt.mint(actors[i], SEED_BALANCE);
            vm.startPrank(actors[i]);
            token.approve(address(vault), type(uint256).max);
            alt.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        _commit();
    }

    /// @notice A randomized custody history replays into the contracts' own view
    ///         values for every stake-custody cell, on both assets and both
    ///         staking categories.
    function testFuzz_ReplayMatchesStorage(uint96[8] memory amounts, uint8[8] memory actorSeed) public {
        _deposits(amounts, actorSeed);
        _locksAndSettlements(amounts, actorSeed);
        _slashAndRewire(amounts, actorSeed);
        _withdrawals(amounts, actorSeed);

        LogProjection projection = _replay();
        _assertAdminCells(projection);
        _assertBalanceCells(projection);
        _assertLockCells(projection);
        _assertAggregateCells(projection);
        _assertStakeCells(projection);
        _assertOutcomeCells(projection);
    }

    /// @notice R0: an asset's aggregate cell reduces to the sum over its per-key
    ///         cells plus the protocol allocation, on both assets.
    function testFuzz_AggregateReducesToPerKeySums(uint96[8] memory amounts, uint8[8] memory actorSeed) public {
        _deposits(amounts, actorSeed);
        _locksAndSettlements(amounts, actorSeed);
        _slashAndRewire(amounts, actorSeed);

        _assertAggregateCells(_replay());
    }

    /// @notice R6: the verifier-stake cell reduces to the sum over per-actor
    ///         stake cells, and the stake family alone produces it.
    function testFuzz_StakeCellReducesToPerKeySums(uint96[8] memory amounts, uint8[8] memory actorSeed) public {
        _deposits(amounts, actorSeed);
        _locksAndSettlements(amounts, actorSeed);

        LogProjection projection = _replay();
        uint256 sum;
        for (uint256 i; i < ACTORS; ++i) {
            sum += projection.staked(CLAIM, actors[i]);
        }
        assertEq(projection.totalStaked(CLAIM), vault.totalStaked(CLAIM), "cell 7 stake total");
        assertEq(projection.totalStaked(CLAIM), sum, "cell 7 reduces to the sum over per-key cells");
    }

    /// @notice A partial withdrawal leaves the conservation equation intact for a
    ///         remainder the fuzzer chooses.
    function testFuzz_PartialWithdrawalConservesCustody(uint96 amount, uint8 actorSeed) public {
        address actor = actors[actorSeed % ACTORS];
        uint256 funded = bound(uint256(amount), 1 ether, 10_000 ether);
        _deposits([uint96(funded), 0, 0, 0, 0, 0, 0, 0], [actorSeed, 0, 0, 0, 0, 0, 0, 0]);

        uint256 claimable = vault.claimableBalance(address(token), actor);
        if (claimable > 1) {
            _call(actor, abi.encodeCall(StakeVault.withdraw, (address(token), bound(claimable, 1, claimable - 1))));
        }

        LogProjection projection = _replay();
        assertEq(projection.custody(address(token)), vault.totalCustody(address(token)), "cell 4 after withdrawal");
        _assertAggregateCells(projection);
    }

    /// @notice The projection fold is a deterministic function of the stream, and
    ///         every step is the exact successor of its predecessor.
    function testFuzz_ReplayFoldIsDeterministic(bytes32[16] memory keys, uint256 seed) public {
        bytes32 first = V2EventCompleteness.EMPTY_FOLD;
        bytes32 second = V2EventCompleteness.EMPTY_FOLD;

        for (uint256 i; i < keys.length; ++i) {
            bytes32 eventKey = keccak256(abi.encode(seed, keys[i], i));
            bytes32 previous = first;
            first = V2EventCompleteness.replayFold(first, eventKey);
            assertTrue(V2EventCompleteness.isFoldCanonical(previous, eventKey, first), "the step is canonical");
            assertFalse(V2EventCompleteness.isFoldCanonical(previous, eventKey, previous), "the fold advanced");
            second = V2EventCompleteness.replayFold(second, eventKey);
        }

        assertEq(first, second, "the same stream always folds to the same value");
        assertNotEq(first, V2EventCompleteness.EMPTY_FOLD, "a non-empty stream differs from the empty fold");
    }

    /// @notice Re-observing a consumed key is a non-canonical transition, so a
    ///         consumer that applies one log twice is detectable rather than
    ///         silently absorbed.
    function testFuzz_ReplayingAConsumedKeyIsNotCanonical(bytes32 seed, uint256 salt) public {
        bytes32 first = keccak256(abi.encode(seed, salt));
        bytes32 second = keccak256(abi.encode(seed, salt, "next"));
        bytes32 fold = V2EventCompleteness.replayFold(V2EventCompleteness.EMPTY_FOLD, first);
        fold = V2EventCompleteness.replayFold(fold, second);
        assertFalse(
            V2EventCompleteness.isFoldCanonical(fold, first, fold), "re-observing a consumed key is not canonical"
        );
    }

    // -------------------------------------------------------------------------
    // Scenario
    // -------------------------------------------------------------------------

    function _deposits(uint96[8] memory amounts, uint8[8] memory actorSeed) internal {
        for (uint256 i; i < 4; ++i) {
            address asset = i % 2 == 0 ? address(token) : address(alt);
            uint256 amount = _pick(uint256(amounts[i]), 1_000 ether);
            _call(actors[actorSeed[i] % ACTORS], abi.encodeCall(StakeVault.deposit, (asset, amount)));
        }
    }

    function _locksAndSettlements(uint96[8] memory amounts, uint8[8] memory actorSeed) internal {
        // Staking-token verifier principal: locked, carried to another round, then
        // final. The carry leaves the stake cell alone and the unlock debits it.
        address a = actors[actorSeed[0] % ACTORS];
        uint256 claimable = vault.claimableBalance(address(token), a);
        uint256 principal = _pick(uint256(amounts[4]), claimable);
        if (principal > 0) {
            _call(
                settlement,
                abi.encodeCall(
                    StakeVault.lock, (address(token), a, CLAIM, 0, IV2Types.LockCategory(VERIFIER_PRINCIPAL), principal)
                )
            );
        }
        uint256 roundZero =
            vault.lockedPrincipal(address(token), a, CLAIM, 0, IV2Types.LockCategory(VERIFIER_PRINCIPAL));
        if (roundZero > 0) {
            _call(
                settlement,
                abi.encodeCall(
                    StakeVault.carryForwardAppeal,
                    (address(token), a, CLAIM, 0, 1, _pick(uint256(amounts[5]), roundZero))
                )
            );
        }
        uint256 roundOne = vault.lockedPrincipal(address(token), a, CLAIM, 1, IV2Types.LockCategory(VERIFIER_PRINCIPAL));
        if (roundOne > 0) {
            _call(
                settlement,
                abi.encodeCall(
                    StakeVault.finalUnlock, (address(token), a, CLAIM, 1, _pick(uint256(amounts[6]), roundOne))
                )
            );
        }

        // An alt-asset challenge bond that stays locked, so a second category and
        // a second asset are in the stream at the same time.
        address b = actors[actorSeed[1] % ACTORS];
        uint256 bond = _pick(uint256(amounts[7]), vault.claimableBalance(address(alt), b));
        if (bond > 0) {
            _call(
                settlement,
                abi.encodeCall(
                    StakeVault.lock, (address(alt), b, CLAIM, 2, IV2Types.LockCategory(CHALLENGE_BOND), bond)
                )
            );
        }

        // An alt-asset verifier-principal lock that is refunded, so the refund
        // hook debits the stake cell on a non-staking asset.
        address c = actors[actorSeed[2] % ACTORS];
        uint256 stake = _pick(uint256(amounts[0]), vault.claimableBalance(address(alt), c));
        if (stake > 0) {
            _call(
                settlement,
                abi.encodeCall(
                    StakeVault.lock, (address(alt), c, CLAIM, 3, IV2Types.LockCategory(VERIFIER_PRINCIPAL), stake)
                )
            );
            _call(settlement, abi.encodeCall(StakeVault.refundInconclusive, (address(alt), c, CLAIM, 3, stake)));
        }

        // A conclusive settlement with a reward, so the allocation leg and the
        // unlock leg are both in the stream.
        address d = actors[actorSeed[3] % ACTORS];
        uint256 settled = _pick(uint256(amounts[1]), vault.claimableBalance(address(token), d));
        if (settled > 0) {
            _call(
                settlement,
                abi.encodeCall(
                    StakeVault.lock, (address(token), d, CLAIM, 4, IV2Types.LockCategory(VERIFIER_PRINCIPAL), settled)
                )
            );
            uint256 reward = _pick(uint256(amounts[2]), 100 ether);
            _call(settlement, abi.encodeCall(StakeVault.settleConclusive, (address(token), d, CLAIM, 4, reward, 0)));
        }
    }

    function _slashAndRewire(uint96[8] memory amounts, uint8[8] memory actorSeed) internal {
        address a = actors[actorSeed[4] % ACTORS];
        uint256 slashed = _pick(uint256(amounts[3]), vault.staked(CLAIM, a));
        if (slashed > 0) {
            _call(slashing, abi.encodeCall(StakeVault.slashStake, (CLAIM, a, slashed, keccak256("fuzz-slash"))));
        }
        uint256 remaining =
            vault.lockedPrincipal(address(token), a, CLAIM, 1, IV2Types.LockCategory(VERIFIER_PRINCIPAL));
        if (remaining > 0) {
            _call(
                settlement,
                abi.encodeCall(
                    StakeVault.rolloverRound, (address(token), a, CLAIM, 1, 2, _pick(uint256(amounts[5]), remaining))
                )
            );
        }
    }

    function _withdrawals(uint96[8] memory amounts, uint8[8] memory actorSeed) internal {
        for (uint256 i; i < 2; ++i) {
            address asset = i == 0 ? address(token) : address(alt);
            address actor = actors[actorSeed[i] % ACTORS];
            uint256 taken = _pick(uint256(amounts[6 + i]), vault.claimableBalance(asset, actor));
            if (taken > 0) _call(actor, abi.encodeCall(StakeVault.withdraw, (asset, taken)));
        }
    }

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------

    function _replay() internal returns (LogProjection projection) {
        projection = new LogProjection(address(token));
        for (uint256 i; i < captured.length; ++i) {
            if (captured[i].emitter != address(vault)) continue;
            projection.applyLog(
                captured[i].topic0, captured[i].topics, captured[i].data, captured[i].blockNumber, false
            );
        }
    }

    function _assertAdminCells(LogProjection p) internal {
        assertEq(vault.supportedAssets(address(token)), p.supportedAsset(address(token)), "cell 0");
        assertEq(vault.supportedAssets(address(alt)), p.supportedAsset(address(alt)), "cell 0");
        assertEq(vault.lockMutators(settlement), p.lockMutator(settlement), "cell 1");
    }

    function _assertBalanceCells(LogProjection p) internal {
        for (uint256 i; i < ACTORS; ++i) {
            assertEq(
                p.claimable(address(token), actors[i]),
                vault.claimableBalance(address(token), actors[i]),
                "cell 2 token claimable"
            );
            assertEq(
                p.claimable(address(alt), actors[i]),
                vault.claimableBalance(address(alt), actors[i]),
                "cell 2 alt claimable"
            );
        }
        assertEq(p.custody(address(token)), vault.totalCustody(address(token)), "cell 4 token custody");
        assertEq(p.custody(address(alt)), vault.totalCustody(address(alt)), "cell 4 alt custody");
        assertEq(
            p.protocolAllocation(address(token)), vault.protocolAllocation(address(token)), "cell 5 protocol allocation"
        );
    }

    function _assertLockCells(LogProjection p) internal {
        for (uint256 i; i < ACTORS; ++i) {
            for (uint256 round; round < ROUNDS; ++round) {
                for (uint256 c; c < 2; ++c) {
                    uint8 category = c == 0 ? VERIFIER_PRINCIPAL : CHALLENGE_BOND;
                    assertEq(
                        p.lockedPrincipal(address(token), actors[i], CLAIM, round, category),
                        vault.lockedPrincipal(address(token), actors[i], CLAIM, round, IV2Types.LockCategory(category)),
                        "cell 3 token lock"
                    );
                    assertEq(
                        p.lockedPrincipal(address(alt), actors[i], CLAIM, round, category),
                        vault.lockedPrincipal(address(alt), actors[i], CLAIM, round, IV2Types.LockCategory(category)),
                        "cell 3 alt lock"
                    );
                }
            }
        }
    }

    function _assertAggregateCells(LogProjection p) internal {
        for (uint256 j; j < 2; ++j) {
            address asset = j == 0 ? address(token) : address(alt);
            (uint256 custody, uint256 obligations) = vault.reconcile(asset);
            assertEq(obligations, custody, "the live obligations stay balanced");

            uint256 claimable;
            uint256 locked;
            for (uint256 i; i < ACTORS; ++i) {
                claimable += p.claimable(asset, actors[i]);
                for (uint256 round; round < ROUNDS; ++round) {
                    locked += p.lockedPrincipal(asset, actors[i], CLAIM, round, VERIFIER_PRINCIPAL);
                    locked += p.lockedPrincipal(asset, actors[i], CLAIM, round, CHALLENGE_BOND);
                }
            }
            assertEq(p.custody(asset), claimable + locked + p.protocolAllocation(asset), "R0 conservation");
        }
    }

    function _assertStakeCells(LogProjection p) internal {
        for (uint256 i; i < ACTORS; ++i) {
            assertEq(p.staked(CLAIM, actors[i]), vault.staked(CLAIM, actors[i]), "cell 7 per-key stake");
        }
        assertEq(p.totalStaked(CLAIM), vault.totalStaked(CLAIM), "cell 7 stake total");
    }

    function _assertOutcomeCells(LogProjection p) internal {
        for (uint256 round; round < ROUNDS; ++round) {
            assertEq(
                p.settlementOutcomeOf(CLAIM, round),
                uint8(vault.settlementOutcome(CLAIM, round)),
                "cell 8 settlement outcome"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Log capture
    // -------------------------------------------------------------------------

    function _begin() internal {
        vm.roll(nextBlock++);
        vm.recordLogs();
    }

    function _commit() internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            captured.push(
                Captured({
                    emitter: entries[i].emitter,
                    topic0: entries[i].topics[0],
                    topics: entries[i].topics,
                    data: entries[i].data,
                    blockNumber: block.number
                })
            );
        }
    }

    /// @dev A step may revert on the protocol's own invariants (a settlement that
    ///      is already final, a slash beyond the stake). A reverted call emits no
    ///      logs, which is the property consumers rely on, so it is asserted
    ///      rather than ignored.
    function _call(address caller, bytes memory callData) internal {
        _begin();
        vm.prank(caller);
        (bool ok,) = address(vault).call(callData);
        if (!ok) {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            assertEq(entries.length, 0, "a reverted call must emit no logs");
        }
        _commit();
    }

    function _pick(uint256 seed, uint256 available) internal pure returns (uint256) {
        if (available == 0) return 0;
        return bound(seed, 1, available);
    }
}
