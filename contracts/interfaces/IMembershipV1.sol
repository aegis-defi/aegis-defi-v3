// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IMembershipV1 {
    function members(address account) external view returns (uint256 level, address referrer);

    function referrerOf(address account) external view returns (address);

    function childrenCountOf(address account) external view returns (uint256);

    function childrenRange(address account, uint256 from, uint256 to)
        external
        view
        returns (address[] memory page);

    function rootReferrer() external view returns (address);
}
