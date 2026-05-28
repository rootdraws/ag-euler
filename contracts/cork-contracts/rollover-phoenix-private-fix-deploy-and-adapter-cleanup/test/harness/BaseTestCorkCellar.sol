// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

// Forked per plan Task 10; original license preserved. Only used in tests — not shipped as part of
// the deployed contracts.
/// @dev Forked from cellar-private@b8c8b9c/test/BaseTestCorkCellar.sol. Re-sync on lib/cellar
///      bumps that classify as rollover-affecting (see plan/implementation-plan.md → Mid-plan
///      submodule bump procedure).

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "test/harness/PhoenixBaseTest.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {CorkCellar} from "cellar/CorkCellar.sol";
import {CorkCellarFactory} from "cellar/CorkCellarFactory.sol";
import {Call, CellarIntent, ICorkCellar, ICorkCellarFactory} from "cellar/ICorkCellar.sol";
import {LibAuthenticatedHooks} from "cellar/LibAuthenticatedHooks.sol";
import {LibAuthenticatedHooksCalldataProxy} from "test/harness/LibAuthenticatedHooksCalldataProxy.sol";

// Modules
import {ApproveAllModule} from "cellar/modules/ApproveAllModule.sol";
import {ERC4626DepositAllModule} from "cellar/modules/ERC4626DepositAllModule.sol";
import {ERC4626WithdrawAllModule} from "cellar/modules/ERC4626WithdrawAllModule.sol";
import {RolloverModule} from "test/harness/RolloverModule.sol";
import {SplitModule} from "cellar/modules/SplitModule.sol";
import {TransferAllModule} from "cellar/modules/TransferAllModule.sol";

// Registry
import {MockResolver} from "registry-test/mocks/MockResolver.sol";
import {AttestationRequest, ModuleType, ResolverUID, SchemaUID} from "registry/DataTypes.sol";
import {Registry} from "registry/Registry.sol";
import {IExternalResolver} from "registry/external/IExternalResolver.sol";
import {IExternalSchemaValidator} from "registry/external/IExternalSchemaValidator.sol";
import {IERC7484} from "registry/interfaces/IERC7484.sol";

// ERC4626 vault for testing
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DummyERC20} from "test/harness/mocks/DummyERC20.sol";

/// @dev Simple single owner smart wallet account that will verify signatures against
///      pre-approved and stored signatures for given hashes.
contract SmartWallet {
    error OnlyOwner();

    address public immutable owner;
    mapping(bytes32 => bytes) signatures;

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert OnlyOwner();
        }
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function sign(bytes32 hash, bytes calldata signature) external onlyOwner {
        signatures[hash] = signature;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return (keccak256(signature) == keccak256(signatures[hash]) && signatures[hash].length > 0)
            ? LibAuthenticatedHooks.MAGIC_VALUE_1271
            : bytes4(0);
    }
}

contract BaseTestCorkCellar is BaseTest {
    // --- Registry ---
    Registry registry;
    SchemaUID defaultSchemaUID;
    ResolverUID defaultResolverUID;

    // --- Core ---
    CorkCellar cellarImpl;
    CorkCellarFactory factory;
    LibAuthenticatedHooksCalldataProxy cproxy;

    // --- Modules ---
    TransferAllModule transferAllModule;
    ApproveAllModule approveAllModule;
    ERC4626WithdrawAllModule erc4626WithdrawAllModule;
    ERC4626DepositAllModule erc4626DepositAllModule;
    SplitModule splitModule;
    RolloverModule rolloverModule;

    // --- User cellar (EOA) ---
    Vm.Wallet user;
    address userCellarAddr;
    CorkCellar userCellar;

    // --- Smart wallet cellar ---
    SmartWallet smartWallet;
    address smartWalletAddr;
    address smartWalletCellarAddr;
    CorkCellar smartWalletCellar;

    // --- ERC4626 test vault ---
    DummyERC20 vaultUnderlying;
    ERC4626Mock testVault;

    function setUp() public virtual override {
        super.setUp();
        vm.stopPrank(); // Phoenix BaseTest leaves bravo prank active

        _deployRegistry();
        _deployModules();
        _registerModules();

        cproxy = new LibAuthenticatedHooksCalldataProxy();

        // Deploy ERC4626 test vault
        vaultUnderlying = new DummyERC20("VaultToken", "VTK", 18);
        testVault = new ERC4626Mock(address(vaultUnderlying));

        // Deploy CorkCellar implementation + factory with correct cross-references.
        // Use nonce prediction so cellarImpl gets the real factory address as immutable.
        uint64 currentNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), currentNonce + 1);
        cellarImpl = new CorkCellar(IERC7484(address(registry)), ICorkCellarFactory(predictedFactory));
        factory = new CorkCellarFactory(address(cellarImpl), IERC7484(address(registry)), bravo);
        require(address(factory) == predictedFactory, "factory address prediction failed");

        // Deploy user cellars (address computation only -- actual deployment
        // requires factory.deployCellar() which is stubbed NOT_IMPLEMENTED)
        _deployUserCellar();
        _deploySmartWalletCellar();
    }

    // ----------------------------------------------------------------
    //  Registry setup
    // ----------------------------------------------------------------

    function _deployRegistry() internal {
        registry = new Registry();
        MockResolver mockResolver = new MockResolver(true);
        defaultResolverUID = registry.registerResolver(IExternalResolver(address(mockResolver)));
        defaultSchemaUID = registry.registerSchema("CorkCellar", IExternalSchemaValidator(address(0)));
    }

    // ----------------------------------------------------------------
    //  Module deployment
    // ----------------------------------------------------------------

    function _deployModules() internal {
        transferAllModule = new TransferAllModule();
        approveAllModule = new ApproveAllModule();
        erc4626WithdrawAllModule = new ERC4626WithdrawAllModule();
        erc4626DepositAllModule = new ERC4626DepositAllModule();
        splitModule = new SplitModule();
        rolloverModule = new RolloverModule(address(1));
    }

    // ----------------------------------------------------------------
    //  Module registration + attestation
    // ----------------------------------------------------------------

    function _registerModules() internal {
        address[6] memory modules = [
            address(transferAllModule),
            address(approveAllModule),
            address(erc4626WithdrawAllModule),
            address(erc4626DepositAllModule),
            address(splitModule),
            address(rolloverModule)
        ];

        ModuleType[] memory moduleTypes = new ModuleType[](1);
        moduleTypes[0] = ModuleType.wrap(2); // executor type

        for (uint256 i = 0; i < modules.length; i++) {
            // Register the module on the registry
            registry.registerModule(defaultResolverUID, modules[i], "", "");

            // Attest the module
            AttestationRequest memory req = AttestationRequest({
                moduleAddress: modules[i],
                expirationTime: 0, // no expiry
                data: "",
                moduleTypes: moduleTypes
            });
            registry.attest(defaultSchemaUID, req);
        }
    }

    // ----------------------------------------------------------------
    //  Cellar deployment (ERC-1167 clones via LibClone)
    // ----------------------------------------------------------------

    function _deployUserCellar() internal {
        user = vm.createWallet("user");
        userCellarAddr = factory.cellarOf(user.addr);
        _etchCloneWithImmutableArgs(userCellarAddr, factory.cellarImplementation(), user.addr);

        userCellar = CorkCellar(payable(userCellarAddr));
        address[] memory attesters = new address[](1);
        attesters[0] = address(this); // test contract is the attester
        userCellar.initialize(1, attesters);
    }

    function _deploySmartWalletCellar() internal {
        smartWallet = new SmartWallet(user.addr);
        smartWalletAddr = address(smartWallet);
        smartWalletCellarAddr = factory.cellarOf(smartWalletAddr);
        _etchCloneWithImmutableArgs(smartWalletCellarAddr, factory.cellarImplementation(), smartWalletAddr);

        smartWalletCellar = CorkCellar(payable(smartWalletCellarAddr));
        address[] memory attesters = new address[](1);
        attesters[0] = address(this);
        smartWalletCellar.initialize(1, attesters);
    }

    /// @dev Place ERC-1167 clone bytecode with immutable args (owner address) at the given address.
    function _etchCloneWithImmutableArgs(address proxy, address implementation, address owner_) internal {
        bytes memory code = LibClone.initCode(implementation, abi.encodePacked(owner_));
        address temp;
        assembly {
            temp := create(0, add(code, 0x20), mload(code))
        }
        vm.etch(proxy, temp.code);
    }

    // ================================================================
    //  Signing helpers — legacy (ExecuteHooks)
    // ================================================================

    function _signForCellar(Call[] memory calls, bytes32 nonce, uint256 deadline, Vm.Wallet memory _wallet)
        internal
        view
        returns (bytes memory)
    {
        address cellar = factory.cellarOf(_wallet.addr);
        bytes32 domainSep = _cellarDomainSeparator(cellar);
        bytes32 digest = cproxy.hashToSign(calls, nonce, deadline, domainSep);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_wallet.privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signWithSmartWalletForCellar(
        Call[] memory calls,
        bytes32 nonce,
        uint256 deadline,
        address _smartWallet,
        address cellar
    ) internal returns (bytes memory) {
        bytes32 domainSep = _cellarDomainSeparator(cellar);
        bytes32 digest = cproxy.hashToSign(calls, nonce, deadline, domainSep);
        bytes memory sig = abi.encode(digest);
        vm.prank(SmartWallet(_smartWallet).owner());
        SmartWallet(_smartWallet).sign(digest, sig);
        return sig;
    }

    // ================================================================
    //  Signing helpers — intent-based (CellarIntent)
    // ================================================================

    function _signCellarIntent(CellarIntent memory intent, Vm.Wallet memory _wallet, address cellar)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSep = _cellarDomainSeparator(cellar);
        bytes32 structHash = _cellarIntentStructHash(intent);
        bytes32 digest = _eip712Digest(domainSep, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_wallet.privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCellarIntentWithSmartWallet(CellarIntent memory intent, address _smartWallet, address cellar)
        internal
        returns (bytes memory)
    {
        bytes32 domainSep = _cellarDomainSeparator(cellar);
        bytes32 structHash = _cellarIntentStructHash(intent);
        bytes32 digest = _eip712Digest(domainSep, structHash);
        bytes memory sig = abi.encode(digest);
        vm.prank(SmartWallet(_smartWallet).owner());
        SmartWallet(_smartWallet).sign(digest, sig);
        return sig;
    }

    // ================================================================
    //  EIP-712 helpers
    // ================================================================

    function _cellarDomainSeparator(address cellar) internal view returns (bytes32 domainSeparator) {
        if (cellar.code.length > 0) {
            domainSeparator = CorkCellar(payable(cellar)).domainSeparator();
        } else {
            domainSeparator = _computeDomainSeparatorForCellar(cellar);
        }
    }

    function _computeDomainSeparatorForCellar(address cellar) internal view returns (bytes32) {
        bytes32 domainTypeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingAddress)");
        string memory name = "CorkCellar";
        string memory version = "2.1.0"; // match CorkCellar.VERSION
        return
            keccak256(
                abi.encode(domainTypeHash, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, cellar)
            );
    }

    /// @dev Compute the struct hash for a CellarIntent in memory.
    ///      LibAuthenticatedHooks uses calldata, so we replicate the logic here.
    function _cellarIntentStructHash(CellarIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LibAuthenticatedHooks.CELLAR_INTENT_TYPE_HASH,
                intent.orderDigest,
                intent.expectedCaller,
                intent.settler,
                intent.deadline,
                intent.orderSize,
                intent.allowPartialFills,
                intent.allowUnderfill,
                _computeCallsHash(intent.rolloverHooks),
                _computeCallsHash(intent.premiumHooks)
            )
        );
    }

    /// @dev Memory-compatible version of LibAuthenticatedHooks.callsHash.
    function _computeCallsHash(Call[] memory calls) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    LibAuthenticatedHooks.CALL_TYPE_HASH,
                    calls[i].target,
                    calls[i].value,
                    keccak256(calls[i].callData),
                    calls[i].allowFailure,
                    calls[i].isDelegateCall
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev Standard EIP-712 digest: keccak256("\x19\x01" || domainSeparator || structHash)
    function _eip712Digest(bytes32 domainSep, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }
}
