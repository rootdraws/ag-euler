// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData} from "contracts/libs/LibRolloverOrder.sol";
import {CORK_ROLLOVER_ORDER_TYPE} from "contracts/libs/LibSettlerHashing.sol";
import {InvalidOrderTokenPair} from "contracts/interfaces/RolloverTypes.sol";

contract PartialFillSettler_resolve is PartialFillSettlerTestBase {
    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _buildOnchainOrder(OrderData memory od)
        internal
        view
        returns (IOriginSettler.OnchainCrossChainOrder memory)
    {
        return IOriginSettler.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 2 hours),
            orderDataType: CORK_ROLLOVER_ORDER_TYPE,
            orderData: abi.encode(od)
        });
    }

    function _wellFormedOrder()
        internal
        view
        returns (IOriginSettler.OnchainCrossChainOrder memory onchain, OrderData memory od)
    {
        (, od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
        onchain = _buildOnchainOrder(od);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Tests -- well-formed order
    // ═══════════════════════════════════════════════════════════════

    function test_resolve_wellFormed_returnsTwoOutputs() external view {
        (IOriginSettler.OnchainCrossChainOrder memory onchain,) = _wellFormedOrder();

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolve(onchain);

        assertEq(resolved.maxSpent.length, 2, "maxSpent should have 2 outputs");
        assertEq(resolved.minReceived.length, 2, "minReceived should have 2 outputs");
        assertEq(resolved.fillInstructions.length, 2, "fillInstructions should have 2 entries");
    }

    function test_resolve_wellFormed_minReceivedReflectsOrderSizeAndPremium() external view {
        (IOriginSettler.OnchainCrossChainOrder memory onchain, OrderData memory od) = _wellFormedOrder();

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolve(onchain);

        assertEq(resolved.minReceived[0].amount, od.orderSize, "rollover output amount");
        assertEq(resolved.minReceived[1].amount, od.minPremiumPerShare, "premium output amount");

        assertEq(resolved.maxSpent[0].amount, od.orderSize, "maxSpent[0] mirrors minReceived[0]");
        assertEq(resolved.maxSpent[1].amount, od.minPremiumPerShare, "maxSpent[1] mirrors minReceived[1]");
    }

    function test_resolve_wellFormed_originDataIsByteExact() external view {
        (IOriginSettler.OnchainCrossChainOrder memory onchain,) = _wellFormedOrder();

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolve(onchain);

        // resolve() builds a synthetic GaslessCrossChainOrder and encodes it
        IOriginSettler.GaslessCrossChainOrder memory synth = IOriginSettler.GaslessCrossChainOrder({
            originSettler: address(settler),
            user: address(this),
            nonce: 0,
            originChainId: block.chainid,
            openDeadline: 0,
            fillDeadline: onchain.fillDeadline,
            orderDataType: onchain.orderDataType,
            orderData: onchain.orderData
        });
        bytes memory expectedOriginData = abi.encode(synth);

        assertEq(
            keccak256(resolved.fillInstructions[0].originData),
            keccak256(expectedOriginData),
            "fillInstructions[0].originData mismatch"
        );
        assertEq(
            keccak256(resolved.fillInstructions[1].originData),
            keccak256(expectedOriginData),
            "fillInstructions[1].originData mismatch"
        );

        bytes32 settlerBytes = bytes32(uint256(uint160(address(settler))));
        assertEq(resolved.fillInstructions[0].destinationSettler, settlerBytes, "destinationSettler[0]");
        assertEq(resolved.fillInstructions[1].destinationSettler, settlerBytes, "destinationSettler[1]");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Tests -- invalid token pair
    // ═══════════════════════════════════════════════════════════════

    function test_resolve_srcCstTokenEqualsPremiumToken_revertsInvalidOrderTokenPair() external {
        (, OrderData memory od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);

        od.premiumToken = od.srcCstToken;
        IOriginSettler.OnchainCrossChainOrder memory onchain = _buildOnchainOrder(od);

        vm.expectRevert(InvalidOrderTokenPair.selector);
        settler.resolve(onchain);
    }
}
