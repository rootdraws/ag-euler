// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PartialFillSettlerTestBase} from "test/partial/PartialFillSettlerTestBase.sol";
import {IOriginSettler} from "contracts/interfaces/IOriginSettler.sol";
import {OrderData, OriginFillerData} from "contracts/libs/LibRolloverOrder.sol";
import {InvalidOrderTokenPair} from "contracts/interfaces/RolloverTypes.sol";

contract PartialFillSettler_resolveFor is PartialFillSettlerTestBase {
    // ═══════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════

    function _wellFormedOrder()
        internal
        view
        returns (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od)
    {
        (order, od,) = _createPartialOrder(user, DEFAULT_ORDER_SIZE);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Tests -- well-formed order
    // ═══════════════════════════════════════════════════════════════

    function test_resolveFor_wellFormed_returnsTwoOutputs() external view {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _wellFormedOrder();
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, address(0xF1));

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolveFor(order, originFillerData);

        assertEq(resolved.maxSpent.length, 2, "maxSpent should have 2 outputs");
        assertEq(resolved.minReceived.length, 2, "minReceived should have 2 outputs");
        assertEq(resolved.fillInstructions.length, 2, "fillInstructions should have 2 entries");
    }

    function test_resolveFor_wellFormed_outputsReflectOrderSizeAndPremium() external view {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _wellFormedOrder();
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, address(0xF1));

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolveFor(order, originFillerData);

        assertEq(resolved.minReceived[0].amount, DEFAULT_ORDER_SIZE, "rollover output amount");
        assertEq(
            resolved.minReceived[0].token, bytes32(uint256(uint160(address(vaultUnderlying)))), "rollover output token"
        );

        assertEq(resolved.minReceived[1].amount, od.minPremiumPerShare, "premium output amount");

        assertEq(resolved.maxSpent[0].amount, DEFAULT_ORDER_SIZE, "maxSpent[0] mirrors minReceived[0]");
        assertEq(resolved.maxSpent[1].amount, od.minPremiumPerShare, "maxSpent[1] mirrors minReceived[1]");
    }

    function test_resolveFor_wellFormed_bakesOutputAmountIntoFirstOutput() external view {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _wellFormedOrder();

        uint256 overrideAmount = 777e18;
        bytes memory originFillerData = _buildOriginFillerData(overrideAmount, address(0xF1));

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolveFor(order, originFillerData);

        assertEq(resolved.minReceived[0].amount, overrideAmount, "outputs[0] should use overrideAmount");
        assertEq(resolved.maxSpent[0].amount, overrideAmount, "maxSpent[0] should use overrideAmount");

        assertEq(resolved.minReceived[1].amount, od.minPremiumPerShare, "outputs[1] should not be overridden");
    }

    function test_resolveFor_wellFormed_originDataIsByteExact() external view {
        (IOriginSettler.GaslessCrossChainOrder memory order,) = _wellFormedOrder();
        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, address(0xF1));

        IOriginSettler.ResolvedCrossChainOrder memory resolved = settler.resolveFor(order, originFillerData);

        // originData is abi.encode(GaslessCrossChainOrder) so fill() can decode it
        bytes memory expectedOriginData = abi.encode(order);

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

    function test_resolveFor_srcCstTokenEqualsPremiumToken_revertsInvalidOrderTokenPair() external {
        (IOriginSettler.GaslessCrossChainOrder memory order, OrderData memory od) = _wellFormedOrder();

        od.premiumToken = od.srcCstToken;
        order.orderData = abi.encode(od);

        bytes memory originFillerData = _buildOriginFillerData(DEFAULT_ORDER_SIZE, address(0xF1));

        vm.expectRevert(InvalidOrderTokenPair.selector);
        settler.resolveFor(order, originFillerData);
    }
}
