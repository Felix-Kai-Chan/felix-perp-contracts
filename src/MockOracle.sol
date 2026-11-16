// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./IMockOracle.sol";

contract MockOracle is IMockOracle {
    address public owner;
    address public signer;
    uint256 public maxPriceAge;

    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _signer, uint256 _maxPriceAge) {
        require(_signer != address(0), "signer zero");
        owner = msg.sender;
        signer = _signer;
        maxPriceAge = _maxPriceAge;
    }

    function setSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "signer zero");
        emit SignerUpdated(signer, _signer);
        signer = _signer;
    }

    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        emit MaxPriceAgeUpdated(maxPriceAge, _maxPriceAge);
        maxPriceAge = _maxPriceAge;
    }

    function hashPrice(uint256 price, uint256 timestamp) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(price, timestamp));
    }

    function getEthSignedHash(uint256 price, uint256 timestamp) public pure returns (bytes32) {
        bytes32 inner = hashPrice(price, timestamp);
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    function verifyPrice(
        uint256 price,
        uint256 timestamp,
        bytes memory signature
    ) external view override returns (bool) {
        if (price == 0) return false;
        if (timestamp > block.timestamp + 60) return false;
        if (maxPriceAge > 0 && block.timestamp > timestamp + maxPriceAge) return false;

        bytes32 ethHash = getEthSignedHash(price, timestamp);
        (address recovered, ECDSA.RecoverError err) = ECDSA.tryRecover(ethHash, signature);
        if (err != ECDSA.RecoverError.NoError) return false;
        return recovered == signer;
    }
}