// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IMembership {
    function join(address referrer) external;
}

contract ContractCaller {
    function forwardJoin(address target, address referrer) external {
        IMembership(target).join(referrer);
    }
}
