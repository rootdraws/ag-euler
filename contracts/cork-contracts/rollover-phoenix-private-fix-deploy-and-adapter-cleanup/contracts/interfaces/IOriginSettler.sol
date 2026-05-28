// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IOriginSettler
/// @notice ERC-7683 origin-chain settler interface. A filler or relayer calls an origin settler to
///         open a cross-chain order (either gasless, via `openFor` with a user signature, or
///         user-initiated, via `open`). Off-chain solvers call `resolve` / `resolveFor` to obtain a
///         `ResolvedCrossChainOrder` describing the exact `Output`s that will be produced and the
///         `FillInstruction`s that a destination settler must execute.
/// @dev This interface is reproduced verbatim from the ERC-7683 specification. Cork's
///      `ExactFillSettler` and `PartialFillSettler` both implement this surface plus
///      `IDestinationSettler` (Cork rollover orders are same-chain, so one contract fills both
///      roles).
interface IOriginSettler {
    /// @notice ERC-7683 order struct used for user-initiated, on-chain opens. The user calls
    ///         `open(OnchainCrossChainOrder)` directly; no signature is required because
    ///         `msg.sender` is the maker.
    /// @param fillDeadline Unix timestamp after which the order can no longer be filled.
    /// @param orderDataType Application-specific discriminator that identifies the shape of
    ///        `orderData`. For Cork rollover orders this is `keccak256("CorkRolloverOrder_v1")`
    ///        (RFC 003 §A.2).
    /// @param orderData ABI-encoded application-specific order body. For Cork this is the encoded
    ///        `OrderData` struct plus the UW's cellar signature (RFC 003 §A.3).
    struct OnchainCrossChainOrder {
        uint32 fillDeadline;
        bytes32 orderDataType;
        bytes orderData;
    }

    /// @notice ERC-7683 order struct used for gasless opens. A filler or relayer calls
    ///         `openFor(order, signature, originFillerData)`; the settler recovers the maker from
    ///         `signature` over this struct using an EIP-712 typed-data hash.
    /// @param originSettler The settler contract expected to validate and open this order. MUST
    ///        match `address(this)` at `openFor` time.
    /// @param user The order maker (signs over the order hash against the settler's EIP-712
    ///        domain).
    /// @param nonce User-scoped nonce.
    /// @param originChainId Chain ID the order is bound to at origin.
    /// @param openDeadline Unix timestamp after which `openFor` reverts.
    /// @param fillDeadline Unix timestamp after which the destination settler rejects fills.
    /// @param orderDataType Application-specific discriminator (see `OnchainCrossChainOrder`).
    /// @param orderData ABI-encoded application-specific order body.
    struct GaslessCrossChainOrder {
        address originSettler;
        address user;
        uint256 nonce;
        uint256 originChainId;
        uint32 openDeadline;
        uint32 fillDeadline;
        bytes32 orderDataType;
        bytes orderData;
    }

    /// @notice The resolved view of an order as returned by `resolve` / `resolveFor`. Describes
    ///         exact token flows (`maxSpent`, `minReceived`) and the per-leg instructions a
    ///         destination settler must consume via `fill`.
    /// @param user The order maker.
    /// @param originChainId Chain ID of the origin settler.
    /// @param openDeadline Unix timestamp after which the order can no longer be opened.
    /// @param fillDeadline Unix timestamp after which the order can no longer be filled.
    /// @param orderId Canonical order identifier. For Cork this is RFC 003 §A.7:
    ///        `keccak256(chainId, settler, user, nonce, originChainId, openDeadline, fillDeadline,
    ///        orderDataType, keccak256(orderData))`.
    /// @param maxSpent Outputs the filler is expected to spend on the destination chain.
    /// @param minReceived Outputs the user is guaranteed to receive on the origin chain.
    /// @param fillInstructions Per-leg destination-chain fill instructions.
    struct ResolvedCrossChainOrder {
        address user;
        uint256 originChainId;
        uint32 openDeadline;
        uint32 fillDeadline;
        bytes32 orderId;
        Output[] maxSpent;
        Output[] minReceived;
        FillInstruction[] fillInstructions;
    }

    /// @notice Generalized token transfer instruction. For Cork rollover orders this always
    ///         describes an ERC-20 movement (token / recipient addresses encoded as
    ///         `bytes32(uint256(uint160(addr)))` per RFC 003 §A.6).
    /// @param token Token identifier (padded address for ERC-20).
    /// @param amount Token amount (wei for ERC-20).
    /// @param recipient Recipient identifier (padded address for ERC-20).
    /// @param chainId Destination chain ID for this output.
    struct Output {
        bytes32 token;
        uint256 amount;
        bytes32 recipient;
        uint256 chainId;
    }

    /// @notice Per-leg instruction for a destination settler. One `FillInstruction` corresponds to
    ///         one `fill(orderId, originData, fillerData)` call against `destinationSettler`.
    /// @param destinationChainId Chain ID on which `destinationSettler` is deployed.
    /// @param destinationSettler The settler contract that will execute the fill.
    /// @param originData ABI-encoded origin-side data. For Cork this is `abi.encode(order)`
    ///        (RFC 003 §A.9).
    struct FillInstruction {
        uint256 destinationChainId;
        bytes32 destinationSettler;
        bytes originData;
    }

    /// @notice Emitted when an order is opened. `resolvedOrder` mirrors the value returned by
    ///         `resolve` / `resolveFor` at the time of the open — off-chain infrastructure reads
    ///         this event as the canonical ledger of open orders.
    /// @param orderId Canonical order identifier (see `ResolvedCrossChainOrder.orderId`).
    /// @param resolvedOrder The resolved view of the opened order.
    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    /// @notice Opens an order that the caller signed off-chain (gasless open).
    /// @dev The settler MUST recover the maker from `signature` over an EIP-712 hash of `order`
    ///      against the settler's domain and MUST enforce `order.originSettler == address(this)`,
    ///      `order.originChainId == block.chainid`, and `block.timestamp <= order.openDeadline`.
    ///      Cork implementations additionally consume `originFillerData` per RFC 003 §A.11.
    /// @param order The gasless order as signed by the maker.
    /// @param signature ECDSA or ERC-1271 signature over the EIP-712 hash of `order`.
    /// @param originFillerData Application-specific filler-provided data (Cork: `OriginFillerData`
    ///        per RFC 003 §A.11).
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external;

    /// @notice Opens an order submitted directly by the maker (on-chain, non-gasless).
    /// @dev The settler MUST treat `msg.sender` as the maker. `order.orderData` carries
    ///      application-specific binding fields.
    /// @param order The user-initiated order.
    function open(OnchainCrossChainOrder calldata order) external;

    /// @notice Resolves an on-chain order into its canonical `ResolvedCrossChainOrder` view.
    /// @param order The user-initiated order.
    /// @return resolvedOrder The resolved view (outputs, orderId, fill instructions).
    function resolve(OnchainCrossChainOrder calldata order)
        external
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder);

    /// @notice Resolves a gasless order into its canonical `ResolvedCrossChainOrder` view.
    /// @dev `originFillerData` parameterizes view-time resolution (e.g. Cork uses
    ///      `OriginFillerData.outputAmount` to bake the desired `Output.amount` into
    ///      `fillInstructions[i].originData` — see RFC 003 §A.11).
    /// @param order The gasless order.
    /// @param originFillerData Application-specific filler-provided data.
    /// @return resolvedOrder The resolved view.
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder);
}
