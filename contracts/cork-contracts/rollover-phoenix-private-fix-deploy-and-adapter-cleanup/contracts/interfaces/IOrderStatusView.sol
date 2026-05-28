// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {OrderStatus} from "contracts/interfaces/RolloverTypes.sol";

/// @title IOrderStatusView
/// @notice Exposes the `orderStatus` mapping accessor that `BaseSettler` (and therefore both
///         `ExactFillSettler` and `PartialFillSettler`) provides. Extracted so fillers and other
///         integrators can read order status without importing the full settler surface.
interface IOrderStatusView {
    /// @notice Current lifecycle status for an order.
    /// @param orderId Canonical order identifier.
    function orderStatus(bytes32 orderId) external view returns (OrderStatus);
}
