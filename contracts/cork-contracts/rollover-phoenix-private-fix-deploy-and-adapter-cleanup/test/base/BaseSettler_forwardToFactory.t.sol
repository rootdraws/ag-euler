// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseSettlerTestBase} from "test/base/BaseSettlerTestBase.sol";
import {CellarIntent, Call, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {CorkCellar} from "cellar/CorkCellar.sol";

contract BaseSettler_forwardToFactory is BaseSettlerTestBase {
    CellarIntent internal intent;
    bytes internal cellarSig;
    address internal cellar;
    bytes32 internal orderDigest;

    function setUp() public override {
        super.setUp();
        cellar = factory.cellarOf(user.addr);
        orderDigest = keccak256("order-digest");
        cellarSig = hex"aabb";

        Call[] memory rolloverHooks = new Call[](0);
        Call[] memory premiumHooks = new Call[](0);
        intent = CellarIntent({
            orderDigest: orderDigest,
            expectedCaller: address(factory),
            settler: address(mockSettler),
            deadline: block.timestamp + 1 hours,
            orderSize: 1000e18,
            allowPartialFills: false,
            allowUnderfill: false,
            rolloverHooks: rolloverHooks,
            premiumHooks: premiumHooks
        });
    }

    function test_forwardToFactory_success_returnsActualRolled() public {
        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(ICorkCellarFactory.executeIntentHooks.selector),
            abi.encode(uint256(500e18))
        );
        uint256 result =
            mockSettler.exposed_forwardToFactory(cellar, orderDigest, 0, intent, cellarSig, 1000e18, address(this));
        assertEq(result, 500e18);
    }

    function test_forwardToFactory_bubblesOverfillCeiling() public {
        vm.mockCallRevert(
            address(factory),
            abi.encodeWithSelector(ICorkCellarFactory.executeIntentHooks.selector),
            abi.encodeWithSelector(CorkCellar.CorkCellar__OverfillCeiling.selector)
        );
        vm.expectRevert(CorkCellar.CorkCellar__OverfillCeiling.selector);
        mockSettler.exposed_forwardToFactory(cellar, orderDigest, 0, intent, cellarSig, 1000e18, address(this));
    }

    function test_forwardToFactory_bubblesUnderfillNotAllowed() public {
        vm.mockCallRevert(
            address(factory),
            abi.encodeWithSelector(ICorkCellarFactory.executeIntentHooks.selector),
            abi.encodeWithSelector(CorkCellar.CorkCellar__UnderfillNotAllowed.selector)
        );
        vm.expectRevert(CorkCellar.CorkCellar__UnderfillNotAllowed.selector);
        mockSettler.exposed_forwardToFactory(cellar, orderDigest, 0, intent, cellarSig, 1000e18, address(this));
    }

    function test_forwardToFactory_bubblesZeroRollover() public {
        vm.mockCallRevert(
            address(factory),
            abi.encodeWithSelector(ICorkCellarFactory.executeIntentHooks.selector),
            abi.encodeWithSelector(CorkCellar.CorkCellar__ZeroRollover.selector)
        );
        vm.expectRevert(CorkCellar.CorkCellar__ZeroRollover.selector);
        mockSettler.exposed_forwardToFactory(cellar, orderDigest, 0, intent, cellarSig, 1000e18, address(this));
    }

    function test_forwardToFactory_bubblesSettlerMismatch() public {
        vm.mockCallRevert(
            address(factory),
            abi.encodeWithSelector(ICorkCellarFactory.executeIntentHooks.selector),
            abi.encodeWithSelector(CorkCellar.CorkCellar__SettlerMismatch.selector)
        );
        vm.expectRevert(CorkCellar.CorkCellar__SettlerMismatch.selector);
        mockSettler.exposed_forwardToFactory(cellar, orderDigest, 0, intent, cellarSig, 1000e18, address(this));
    }

    function test_forwardToFactory_bubblesPremiumAlreadyFiredForFiller() public {
        vm.mockCallRevert(
            address(factory),
            abi.encodeWithSelector(ICorkCellarFactory.executeIntentHooks.selector),
            abi.encodeWithSelector(CorkCellar.CorkCellar__PremiumAlreadyFiredForFiller.selector)
        );
        vm.expectRevert(CorkCellar.CorkCellar__PremiumAlreadyFiredForFiller.selector);
        mockSettler.exposed_forwardToFactory(cellar, orderDigest, 1, intent, cellarSig, 1000e18, address(this));
    }
}
