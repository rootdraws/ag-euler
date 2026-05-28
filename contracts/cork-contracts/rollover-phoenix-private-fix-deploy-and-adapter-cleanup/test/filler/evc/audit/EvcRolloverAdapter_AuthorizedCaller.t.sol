// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {EvcExactFillAdapterTestBase} from "test/filler/evc/exact/EvcExactFillAdapterTestBase.sol";
import {EvcExactFillAdapter} from "contracts/fillers/EvcExactFillAdapter.sol";
import {IEvcExactFillAdapter} from "contracts/interfaces/IEvcExactFillAdapter.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {LibSettlerHashing} from "contracts/libs/LibSettlerHashing.sol";
import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title EvcRolloverAdapter_AuthorizedCaller
/// @notice Audit-cycle coverage for the AUTHORIZED_CALLER gate (pashov Critical-1 / Task 1 B1).
///         Each adapter is bound to a single curator subaccount at deploy; `execute` reverts
///         `EvcExactFillAdapter__InvalidCaller` on any other resolved `onBehalfOfAccount` and on
///         any direct (non-EVC) call. This suite pins the three branches: cross-caller attempt,
///         happy path for the bound caller, and direct-call rejection.
/// @dev Complements the invariant-level F9 check in `EvcAdapterInvariant.t.sol`. The invariant
///      campaign sweeps the handler's action surface; these leaves pin the specific revert
///      selector and exercise the gate from an integration-level perspective.
contract EvcRolloverAdapter_AuthorizedCaller is EvcExactFillAdapterTestBase {
    uint256 internal constant ORDER_SIZE = 1000e18;
    uint256 internal constant PREMIUM_DEPOSIT = 10e18;

    address internal seeder;
    address internal attacker;

    function setUp() public override {
        super.setUp();
        // Align the harness adapter's curator with the seeder identity so the happy-path leaf
        // drives the canonical `evcAdapterExact` instance.
        seeder = AUTHORIZED_CALLER;
        attacker = makeAddr("attacker-subaccount");
    }

    // ═══════════════════════════════════════════════════════════════
    //  1. Adversarial subaccount — B1 primary negative path
    // ═══════════════════════════════════════════════════════════════

    /// @notice Seed srcCST onto `evcAdapterExact` (bound to `seeder`). An attacker subaccount
    ///         opens an EVC batch with `onBehalfOfAccount = attacker` targeting the seeder's
    ///         adapter. The adapter's `AUTHORIZED_CALLER` check rejects, EVC bubbles the
    ///         selector, and the whole batch reverts — no state change on the adapter.
    function test_adversarialSubaccount_reverts_InvalidCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        // Seeder's preconditions: operator authorisation + ERC-6909 premium balance + srcCST seed.
        _authoriseAdapterOperator(seeder, evcAdapterExact);
        _prepareAdapterErc6909(seeder, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        uint256 adapterSrcCstBefore = IERC20(od.srcCstToken).balanceOf(address(evcAdapterExact));

        // Attacker dispatches an EVC batch with themselves as the on-behalf-of account.
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        _executeViaEvcBatch(
            evcAdapterExact,
            attacker,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            seeder,
            destination
        );

        // Seeder's pre-seeded state survives the rejected batch unchanged (atomic revert parity).
        assertEq(
            IERC20(od.srcCstToken).balanceOf(address(evcAdapterExact)),
            adapterSrcCstBefore,
            "adapter srcCST unchanged after rejected batch"
        );
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), 0, "attacker did not route dstCST to destination");
    }

    // ═══════════════════════════════════════════════════════════════
    //  2. Bound caller — happy path sanity
    // ═══════════════════════════════════════════════════════════════

    /// @notice The AUTHORIZED_CALLER subaccount still executes the canonical happy path. Asserts
    ///         the gate is a targeted reject for non-bound callers, not a blanket block.
    function test_boundCaller_happyPath() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        _authoriseAdapterOperator(seeder, evcAdapterExact);
        _prepareAdapterErc6909(seeder, evcAdapterExact, od.premiumToken, PREMIUM_DEPOSIT);
        _seedAdapterSrcCst(evcAdapterExact, od.srcCstToken, ORDER_SIZE);

        _executeViaEvcBatch(
            evcAdapterExact,
            seeder,
            _noItems(),
            _noItems(),
            abi.encode(order),
            sig,
            ofd,
            ORDER_SIZE,
            seeder,
            destination
        );

        bytes32 orderId = LibSettlerHashing.computeOrderId(address(exactSettler), order);
        assertEq(uint8(exactSettler.orderStatus(orderId)), uint8(OrderStatus.Settled), "order settled for bound caller");
        assertEq(IERC20(od.dstCstToken).balanceOf(destination), ORDER_SIZE, "dstCST delivered for bound caller");
    }

    // ═══════════════════════════════════════════════════════════════
    //  3. Direct call — msg.sender != EVC branch
    // ═══════════════════════════════════════════════════════════════

    /// @notice Direct `adapter.execute(...)` call (not from inside an EVC frame) reverts with the
    ///         same selector. Covers the first branch of `_requireAuthenticatedEvcCaller`.
    function test_directCall_reverts_InvalidCaller() external {
        (IOriginSettler.GaslessCrossChainOrder memory order,, bytes memory sig, bytes memory ofd) =
            _buildValidOrderWithSignedCellarIntent(user, ORDER_SIZE, destination);

        vm.prank(seeder);
        vm.expectRevert(IEvcExactFillAdapter.EvcExactFillAdapter__InvalidCaller.selector);
        evcAdapterExact.execute(abi.encode(order), sig, ofd, ORDER_SIZE, seeder, destination);
    }
}
