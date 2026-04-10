// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

interface IEVC {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }
    
    function batch(BatchItem[] calldata items) external;
    function enableController(address account, address vault) external;
    function enableCollateral(address account, address vault) external;
    function disableCollateral(address account, address vault) external;
}
