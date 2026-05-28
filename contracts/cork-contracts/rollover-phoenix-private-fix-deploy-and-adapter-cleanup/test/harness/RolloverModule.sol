// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

// Forked per plan Task 10; original license preserved. Only used in tests — not shipped as part of
// the deployed contracts.
//
// Sole purpose of the fork: rewrite the import of phoenix's `IPoolManager` from cellar's own
// convention (`phoenix/contracts/interfaces/IPoolManager.sol`) to our project's convention
// (`phoenix/interfaces/IPoolManager.sol`). Our `phoenix/` remap points at
// `lib/cellar/lib/phoenix/contracts/`, and foundry deduplicates any additional `phoenix/contracts/`
// remap because its target resolves to the same path. The remaining source is verbatim.
/// @dev Forked from cellar-private@e194384/src/modules/RolloverModule.sol. Re-sync on lib/cellar
///      bumps that classify as rollover-affecting (see plan/implementation-plan.md → Mid-plan
///      submodule bump procedure).

import {IPoolManager, MarketId} from "phoenix/interfaces/IPoolManager.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title RolloverModule
/// @notice Wraps unwindMint + deposit for rolling over from one Cork pool to another.
/// @dev One instance per PoolManager — each registered on the factory and attested separately.
///      Reads fillAmount and phase from transient storage slots set by CorkCellar.
///      Reverts if not in rollover phase or if fillAmount < sharesToRoll.
contract RolloverModule {
    error WrongPhase();
    error NothingToRoll();
    error FillAmountExceeded();

    /// @dev Must match CorkCellar.FILL_AMOUNT_SLOT exactly.
    bytes32 internal constant FILL_AMOUNT_SLOT = bytes32(uint256(keccak256("CorkCellar.fillAmount")) - 1);
    /// @dev Must match CorkCellar.FILL_PHASE_SLOT exactly.
    bytes32 internal constant FILL_PHASE_SLOT = bytes32(uint256(keccak256("CorkCellar.fillPhase")) - 1);
    /// @dev Phase value representing rollover (must match CorkCellar).
    uint256 internal constant ROLLOVER_PHASE = 0;

    IPoolManager public immutable POOL_MANAGER;

    constructor(address poolManager_) {
        POOL_MANAGER = IPoolManager(poolManager_);
    }

    /// @param srcCstToken The source cST token address
    /// @param srcCptToken The source cPT token address
    /// @param srcPoolId The source pool ID to unwind from
    /// @param dstPoolId The destination pool ID to deposit into
    /// @param settler The settler address (receives dstCST, may get leftover srcCST approval)
    /// @param dstCstToken The destination cST token address
    function execute(
        address srcCstToken,
        address srcCptToken,
        bytes32 srcPoolId,
        bytes32 dstPoolId,
        address settler,
        address dstCstToken
    ) external {
        // 1. Phase guard
        uint256 phase;
        bytes32 slot = FILL_PHASE_SLOT;
        assembly {
            phase := tload(slot)
        }
        if (phase != ROLLOVER_PHASE) revert WrongPhase();

        // 2. sharesToRoll = min(srcCst, srcCpt)
        uint256 srcCstBal = SafeTransferLib.balanceOf(srcCstToken, address(this));
        uint256 srcCptBal = SafeTransferLib.balanceOf(srcCptToken, address(this));
        uint256 sharesToRoll = srcCstBal < srcCptBal ? srcCstBal : srcCptBal;
        if (sharesToRoll == 0) revert NothingToRoll();

        // 3. fillAmount check
        uint256 fillAmount;
        bytes32 faSlot = FILL_AMOUNT_SLOT;
        assembly {
            fillAmount := tload(faSlot)
        }
        if (fillAmount < sharesToRoll) revert FillAmountExceeded();

        // 4. Derive collateral asset from PoolManager
        address caToken = POOL_MANAGER.market(MarketId.wrap(srcPoolId)).collateralAsset;

        // 5. Approve srcCst + srcCpt to PoolManager
        address pm = address(POOL_MANAGER);
        SafeTransferLib.safeApprove(srcCstToken, pm, sharesToRoll);
        SafeTransferLib.safeApprove(srcCptToken, pm, sharesToRoll);

        // 6. unwindMint
        uint256 caReceived =
            POOL_MANAGER.unwindMint(MarketId.wrap(srcPoolId), sharesToRoll, address(this), address(this));

        // 7. Approve CA to PoolManager, then deposit
        SafeTransferLib.safeApprove(caToken, pm, caReceived);
        uint256 sharesOut = POOL_MANAGER.deposit(MarketId.wrap(dstPoolId), caReceived, address(this));

        // 8. Transfer dstCst to settler
        SafeTransferLib.safeTransfer(dstCstToken, settler, sharesOut);

        // 9. Leftover srcCst approval
        if (fillAmount > sharesToRoll) {
            SafeTransferLib.safeApprove(srcCstToken, settler, fillAmount - sharesToRoll);
        }
    }
}
