// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract TestMinimal {
    uint256 public number = 42;

    function setNumber(uint256 _num) public {
        number = _num;
    }
}
