// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IEVC {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }
    function batch(BatchItem[] calldata items) external payable;
    function enableCollateral(address account, address vault) external;
    function enableController(address account, address vault) external;
}

interface ISwapper {
    struct SwapParams {
        bytes32 handler;
        uint256 mode;
        address account;
        address tokenIn;
        address tokenOut;
        address vaultIn;
        address accountIn;
        address receiver;
        uint256 amountOut;
        bytes data;
    }
    function swap(SwapParams calldata params) external;
    function deposit(address token, address vault, uint256 amountMin, address account) external;
    function multicall(bytes[] calldata data) external;
}

interface ISwapVerifier {
    function transferFromSender(address token, uint256 amount, address to) external;
    function verifyAmountMinAndSkim(address vault, address account, uint256 amountMin, uint256 deadline) external;
}

interface IVault {
    function borrow(uint256 amount, address receiver) external returns (uint256);
}

contract TestLoopZap is Script {
    address constant USER         = 0x701a27330d13728a60bBe37DECde9D5a6c7402E5;
    address constant SUB_ACCOUNT  = 0x701A27330D13728a60BBE37decdE9d5A6c7402E7; // index 2

    address constant EVC           = 0x7a9324E8f270413fa2E458f5831226d99C7477CD;
    address constant SWAPPER       = 0xB6D7194fD09F27890279caB08d565A6424fb525D;
    address constant SWAP_VERIFIER = 0x65bF068c88e0f006f76b871396B4DB1150dd9EAD;
    address constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant AUSD             = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant BPT_POOL1        = 0x2DAA146dfB7EAef0038F9F15B2EC1e4DE003f72b;
    address constant COLLATERAL_VAULT = 0x5795130BFb9232C7500C6E57A96Fdd18bFA60436;
    address constant BORROW_VAULT     = 0x438cedcE647491B1d93a73d491eC19A50194c222;
    address constant ADAPTER          = 0xC904aAB60824FC8225F6c8843897fFba14c8Bf98;

    bytes32 constant HANDLER_GENERIC = 0x47656e6572696300000000000000000000000000000000000000000000000000;

    uint256 constant INPUT_AMOUNT = 1_000_000;  // 1 AUSD (6 decimals)
    uint256 constant DEBT_AMOUNT  = 1_000_000;  // 1 AUSD (2x leverage)

    function run() external {
        console.log("=== Loop Zap Test: Pool 1 (AUSD adapter), 1 AUSD, 2x ===");
        console.log("User:", USER);
        console.log("Sub-account:", SUB_ACCOUNT);
        console.log("AUSD balance:", IERC20(AUSD).balanceOf(USER));

        vm.startPrank(USER);

        // Set up Permit2 allowance: AUSD -> SwapVerifier
        IPermit2(PERMIT2).approve(AUSD, SWAP_VERIFIER, type(uint160).max, type(uint48).max);
        console.log("Permit2 allowance set: AUSD -> SwapVerifier");

        // Also approve AUSD from Swapper to the adapter (Swapper needs allowance for GenericHandler)
        // Actually the Swapper handles this internally, but let's also set Permit2 allowance for Swapper
        IPermit2(PERMIT2).approve(AUSD, SWAPPER, type(uint160).max, type(uint48).max);
        console.log("Permit2 allowance set: AUSD -> Swapper");

        // STEP 1: Test just enableCollateral + enableController
        console.log("\n--- Step 1: enableCollateral + enableController ---");
        {
            IEVC.BatchItem[] memory calls = new IEVC.BatchItem[](2);
            calls[0] = IEVC.BatchItem({
                targetContract: EVC,
                onBehalfOfAccount: address(0),
                value: 0,
                data: abi.encodeCall(IEVC.enableCollateral, (SUB_ACCOUNT, COLLATERAL_VAULT))
            });
            calls[1] = IEVC.BatchItem({
                targetContract: EVC,
                onBehalfOfAccount: address(0),
                value: 0,
                data: abi.encodeCall(IEVC.enableController, (SUB_ACCOUNT, BORROW_VAULT))
            });
            IEVC(EVC).batch(calls);
            console.log("Step 1 OK");
        }

        // STEP 2: Test transferFromSender alone
        console.log("\n--- Step 2: transferFromSender ---");
        {
            IEVC.BatchItem[] memory calls = new IEVC.BatchItem[](1);
            calls[0] = IEVC.BatchItem({
                targetContract: SWAP_VERIFIER,
                onBehalfOfAccount: USER,
                value: 0,
                data: abi.encodeCall(ISwapVerifier.transferFromSender, (AUSD, INPUT_AMOUNT, SWAPPER))
            });
            IEVC(EVC).batch(calls);
            console.log("Step 2 OK - AUSD transferred to Swapper");
            console.log("Swapper AUSD balance:", IERC20(AUSD).balanceOf(SWAPPER));
        }

        // STEP 3: Test first swapper multicall
        console.log("\n--- Step 3: Swapper multicall (zap) ---");
        {
            IEVC.BatchItem[] memory calls = new IEVC.BatchItem[](1);
            calls[0] = _buildSwapperMulticall(INPUT_AMOUNT, SUB_ACCOUNT);
            IEVC(EVC).batch(calls);
            console.log("Step 3 OK - Swap completed");
        }

        // STEP 4: Verify + skim
        console.log("\n--- Step 4: verifyAmountMinAndSkim ---");
        uint256 deadline = block.timestamp + 1800;
        {
            IEVC.BatchItem[] memory calls = new IEVC.BatchItem[](1);
            calls[0] = IEVC.BatchItem({
                targetContract: SWAP_VERIFIER,
                onBehalfOfAccount: SUB_ACCOUNT,
                value: 0,
                data: abi.encodeCall(ISwapVerifier.verifyAmountMinAndSkim, (COLLATERAL_VAULT, SUB_ACCOUNT, 0, deadline))
            });
            IEVC(EVC).batch(calls);
            console.log("Step 4 OK - Verified and skimmed");
        }

        // STEP 5: Borrow
        console.log("\n--- Step 5: Borrow ---");
        {
            IEVC.BatchItem[] memory calls = new IEVC.BatchItem[](1);
            calls[0] = IEVC.BatchItem({
                targetContract: BORROW_VAULT,
                onBehalfOfAccount: SUB_ACCOUNT,
                value: 0,
                data: abi.encodeCall(IVault.borrow, (DEBT_AMOUNT, SWAPPER))
            });
            IEVC(EVC).batch(calls);
            console.log("Step 5 OK - Borrowed to Swapper");
            console.log("Swapper AUSD balance:", IERC20(AUSD).balanceOf(SWAPPER));
        }

        // STEP 6: Second swapper multicall (multiply)
        console.log("\n--- Step 6: Swapper multicall (multiply) ---");
        {
            IEVC.BatchItem[] memory calls = new IEVC.BatchItem[](1);
            calls[0] = _buildSwapperMulticall(DEBT_AMOUNT, SUB_ACCOUNT);
            IEVC(EVC).batch(calls);
            console.log("Step 6 OK - Multiply swap completed");
        }

        // STEP 7: Final verify
        console.log("\n--- Step 7: Final verifyAmountMinAndSkim ---");
        {
            IEVC.BatchItem[] memory calls = new IEVC.BatchItem[](1);
            calls[0] = IEVC.BatchItem({
                targetContract: SWAP_VERIFIER,
                onBehalfOfAccount: SUB_ACCOUNT,
                value: 0,
                data: abi.encodeCall(ISwapVerifier.verifyAmountMinAndSkim, (COLLATERAL_VAULT, SUB_ACCOUNT, 0, deadline))
            });
            IEVC(EVC).batch(calls);
            console.log("Step 7 OK - Final verify done");
        }

        console.log("\n=== ALL STEPS PASSED ===");
        vm.stopPrank();
    }

    function _buildSwapperMulticall(uint256 amount, address account) internal pure returns (IEVC.BatchItem memory) {
        // GenericHandler data: abi.encode(target, payload)
        bytes memory zapInCalldata = abi.encodeWithSignature(
            "zapIn(uint256,uint256,uint256)",
            uint256(1),     // tokenIndex
            amount,         // amount
            uint256(0)      // minBptOut (0 for testing)
        );
        bytes memory handlerData = abi.encode(ADAPTER, zapInCalldata);

        // Build swap calldata
        bytes memory swapCalldata = abi.encodeCall(ISwapper.swap, (
            ISwapper.SwapParams({
                handler: HANDLER_GENERIC,
                mode: 0,
                account: account,
                tokenIn: AUSD,
                tokenOut: BPT_POOL1,
                vaultIn: BORROW_VAULT,
                accountIn: account,
                receiver: SWAPPER,
                amountOut: 0,
                data: handlerData
            })
        ));

        // Build deposit calldata
        bytes memory depositCalldata = abi.encodeCall(ISwapper.deposit, (
            BPT_POOL1,
            COLLATERAL_VAULT,
            0,
            account
        ));

        // Build multicall
        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = swapCalldata;
        multicallData[1] = depositCalldata;

        return IEVC.BatchItem({
            targetContract: SWAPPER,
            onBehalfOfAccount: account,
            value: 0,
            data: abi.encodeCall(ISwapper.multicall, (multicallData))
        });
    }
}
