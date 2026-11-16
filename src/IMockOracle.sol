// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMockOracle {
    function verifyPrice(
        uint256 price,
        uint256 timestamp,
        bytes memory signature
    ) external view returns (bool);
}