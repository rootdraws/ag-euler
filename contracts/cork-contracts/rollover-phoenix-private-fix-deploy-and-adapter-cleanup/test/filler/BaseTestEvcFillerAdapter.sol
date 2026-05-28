// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EthereumVaultConnector} from "evc/EthereumVaultConnector.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

import {EvcExactFillAdapter} from "contracts/fillers/EvcExactFillAdapter.sol";
import {EvcPartialFillAdapter} from "contracts/fillers/EvcPartialFillAdapter.sol";
import {BaseTestFiller} from "test/filler/BaseTestFiller.sol";

/// @title BaseTestEvcFillerAdapter
/// @notice Test harness for Cork EVC-aware rollover *adapter* tests. Extends `BaseTestFiller` —
///         which already deploys the registry, `CorkCellarFactory`, user / smart-wallet cellars,
///         all cellar modules, `ERC6909Premium`, both settlers, and both canonical shared-
///         singleton reference filler instances — and layers a real `EthereumVaultConnector`
///         plus the two per-subaccount adapter deployments (`EvcExactFillAdapter` +
///         `EvcPartialFillAdapter`).
abstract contract BaseTestEvcFillerAdapter is BaseTestFiller {
    EthereumVaultConnector internal evc;
    EvcExactFillAdapter internal evcAdapterExact;
    EvcPartialFillAdapter internal evcAdapterPartial;
    /// @notice The curator subaccount each canonical adapter is bound to. Every harness-built
    ///         `evc.batch` / `evc.call` uses this as `onBehalfOfAccount` so the adapter's
    ///         `AUTHORIZED_CALLER` check accepts it. Leaves targeting a different caller MUST
    ///         deploy their own adapter with the appropriate `authorizedCaller_`.
    address internal AUTHORIZED_CALLER;

    function setUp() public virtual override {
        super.setUp();
        evc = new EthereumVaultConnector();
        AUTHORIZED_CALLER = makeAddr("evcAdapter_authorizedCaller");
        evcAdapterExact = new EvcExactFillAdapter(address(exactSettler), address(0), address(evc), AUTHORIZED_CALLER);
        evcAdapterPartial =
            new EvcPartialFillAdapter(address(partialSettler), address(factory), address(evc), AUTHORIZED_CALLER);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════
    //  Adapter-level convenience helpers
    // ═══════════════════════════════════════════════════════════════════════════════════════

    /// @notice Authorise the Exact adapter as an EVC operator for `subaccount`.
    function _authoriseAdapterOperator(address subaccount, EvcExactFillAdapter adapter) internal {
        vm.prank(subaccount);
        evc.setAccountOperator(subaccount, address(adapter), true);
    }

    /// @notice Authorise the Partial adapter as an EVC operator for `subaccount`.
    function _authoriseAdapterOperator(address subaccount, EvcPartialFillAdapter adapter) internal {
        vm.prank(subaccount);
        evc.setAccountOperator(subaccount, address(adapter), true);
    }

    /// @notice Raw-address variant for polymorphic handlers.
    function _authoriseAdapterOperatorRaw(address subaccount, address adapter) internal {
        vm.prank(subaccount);
        evc.setAccountOperator(subaccount, adapter, true);
    }

    /// @notice Seed `subaccount`'s ERC-6909 premium balance and authorise both the adapter's
    ///         bound settler and the adapter itself as ERC-6909 operators for the subaccount
    ///         (Exact variant).
    function _prepareAdapterErc6909(
        address subaccount,
        EvcExactFillAdapter adapter,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareAdapterErc6909Internal(subaccount, adapter.SETTLER(), address(adapter), premiumToken, premiumAmount);
    }

    /// @notice Partial variant of `_prepareAdapterErc6909`.
    function _prepareAdapterErc6909(
        address subaccount,
        EvcPartialFillAdapter adapter,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareAdapterErc6909Internal(subaccount, adapter.SETTLER(), address(adapter), premiumToken, premiumAmount);
    }

    /// @notice Low-level variant used by polymorphic handlers that hold the adapter via a shape
    ///         interface. `adapter` is the raw adapter address; `boundSettler` is its SETTLER
    ///         immutable (read by the caller and passed in).
    function _prepareAdapterErc6909(
        address subaccount,
        address adapter,
        address boundSettler,
        address premiumToken,
        uint256 premiumAmount
    ) internal {
        _prepareAdapterErc6909Internal(subaccount, boundSettler, adapter, premiumToken, premiumAmount);
    }

    /// @notice Low-level seed variant used by polymorphic handlers.
    function _seedAdapterSrcCstRaw(address adapter, address srcCstToken, uint256 amount) internal {
        _seedAdapterSrcCstInternal(adapter, srcCstToken, amount);
    }

    function _prepareAdapterErc6909Internal(
        address subaccount,
        address boundSettler,
        address adapter,
        address premiumToken,
        uint256 premiumAmount
    ) private {
        _depositPremium(subaccount, premiumToken, premiumAmount);
        vm.prank(subaccount);
        premium.setOperator(boundSettler, true);
        vm.prank(subaccount);
        premium.setOperator(adapter, true);
    }

    /// @notice Seed the Exact adapter directly with `amount` of `srcCstToken`.
    function _seedAdapterSrcCst(EvcExactFillAdapter adapter, address srcCstToken, uint256 amount) internal {
        _seedAdapterSrcCstInternal(address(adapter), srcCstToken, amount);
    }

    /// @notice Seed the Partial adapter directly with `amount` of `srcCstToken`.
    function _seedAdapterSrcCst(EvcPartialFillAdapter adapter, address srcCstToken, uint256 amount) internal {
        _seedAdapterSrcCstInternal(address(adapter), srcCstToken, amount);
    }

    function _seedAdapterSrcCstInternal(address adapter, address srcCstToken, uint256 amount) private {
        (bool ok,) = srcCstToken.call(abi.encodeWithSignature("mint(address,uint256)", adapter, amount));
        require(ok, "BaseTestEvcFillerAdapter: srcCst mint failed");
    }

    /// @notice Build an `evc.batch([...prefix, executeItem, ...suffix])` invocation targeting the
    ///         Exact adapter with `onBehalfOfAccount = subaccount` on every item and dispatch
    ///         pranked as the subaccount.
    function _executeViaEvcBatch(
        EvcExactFillAdapter adapter,
        address subaccount,
        IEVC.BatchItem[] memory prefixItems,
        IEVC.BatchItem[] memory suffixItems,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) internal {
        _executeViaEvcBatchInternal(
            address(adapter),
            EvcExactFillAdapter.execute.selector,
            subaccount,
            prefixItems,
            suffixItems,
            orderData,
            signature,
            originFillerData,
            srcCstAmount,
            debitFrom,
            destination
        );
    }

    /// @notice Partial variant of `_executeViaEvcBatch`.
    function _executeViaEvcBatch(
        EvcPartialFillAdapter adapter,
        address subaccount,
        IEVC.BatchItem[] memory prefixItems,
        IEVC.BatchItem[] memory suffixItems,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) internal {
        _executeViaEvcBatchInternal(
            address(adapter),
            EvcPartialFillAdapter.execute.selector,
            subaccount,
            prefixItems,
            suffixItems,
            orderData,
            signature,
            originFillerData,
            srcCstAmount,
            debitFrom,
            destination
        );
    }

    function _executeViaEvcBatchInternal(
        address adapter,
        bytes4 executeSelector,
        address subaccount,
        IEVC.BatchItem[] memory prefixItems,
        IEVC.BatchItem[] memory suffixItems,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) private {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](prefixItems.length + 1 + suffixItems.length);
        uint256 cursor = 0;
        for (uint256 i = 0; i < prefixItems.length; i++) {
            items[cursor++] = prefixItems[i];
        }
        items[cursor++] = IEVC.BatchItem({
            targetContract: adapter,
            onBehalfOfAccount: subaccount,
            value: 0,
            data: abi.encodeWithSelector(
                executeSelector, orderData, signature, originFillerData, srcCstAmount, debitFrom, destination
            )
        });
        for (uint256 i = 0; i < suffixItems.length; i++) {
            items[cursor++] = suffixItems[i];
        }
        vm.prank(subaccount);
        evc.batch(items);
    }

    /// @notice Dispatch `adapter.execute(...)` through `evc.call` pranked as subaccount (Exact).
    function _executeViaEvcCall(
        EvcExactFillAdapter adapter,
        address subaccount,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) internal {
        _executeViaEvcCallInternal(
            address(adapter),
            EvcExactFillAdapter.execute.selector,
            subaccount,
            orderData,
            signature,
            originFillerData,
            srcCstAmount,
            debitFrom,
            destination
        );
    }

    /// @notice Partial variant of `_executeViaEvcCall`.
    function _executeViaEvcCall(
        EvcPartialFillAdapter adapter,
        address subaccount,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) internal {
        _executeViaEvcCallInternal(
            address(adapter),
            EvcPartialFillAdapter.execute.selector,
            subaccount,
            orderData,
            signature,
            originFillerData,
            srcCstAmount,
            debitFrom,
            destination
        );
    }

    function _executeViaEvcCallInternal(
        address adapter,
        bytes4 executeSelector,
        address subaccount,
        bytes memory orderData,
        bytes memory signature,
        bytes memory originFillerData,
        uint256 srcCstAmount,
        address debitFrom,
        address destination
    ) private {
        vm.prank(subaccount);
        evc.call(
            adapter,
            subaccount,
            0,
            abi.encodeWithSelector(
                executeSelector, orderData, signature, originFillerData, srcCstAmount, debitFrom, destination
            )
        );
    }

    /// @notice Post-execute invariant asserter for Exact adapters.
    function _adapterSnapshot(
        EvcExactFillAdapter adapter,
        address srcCstToken,
        address dstCstToken,
        uint256 expectedSrcCstLeftover
    ) internal view {
        _adapterSnapshotInternal(address(adapter), adapter.SETTLER(), srcCstToken, dstCstToken, expectedSrcCstLeftover);
    }

    /// @notice Post-execute invariant asserter for Partial adapters.
    function _adapterSnapshot(
        EvcPartialFillAdapter adapter,
        address srcCstToken,
        address dstCstToken,
        uint256 expectedSrcCstLeftover
    ) internal view {
        _adapterSnapshotInternal(address(adapter), adapter.SETTLER(), srcCstToken, dstCstToken, expectedSrcCstLeftover);
    }

    function _adapterSnapshotInternal(
        address adapter,
        address settler_,
        address srcCstToken,
        address dstCstToken,
        uint256 expectedSrcCstLeftover
    ) private view {
        assertEq(
            IERC20(srcCstToken).balanceOf(adapter),
            expectedSrcCstLeftover,
            "BaseTestEvcFillerAdapter: INV-F1 srcCst leftover mismatch"
        );
        assertEq(IERC20(dstCstToken).balanceOf(adapter), 0, "BaseTestEvcFillerAdapter: INV-F1 adapter holds dstCst");
        assertEq(
            IERC20(srcCstToken).allowance(adapter, settler_),
            0,
            "BaseTestEvcFillerAdapter: INV-F2 srcCst allowance to settler"
        );
        assertEq(
            IERC20(dstCstToken).allowance(adapter, settler_),
            0,
            "BaseTestEvcFillerAdapter: INV-F2 dstCst allowance to settler"
        );
    }
}
