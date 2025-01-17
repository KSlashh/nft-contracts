// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "./libs/ownership/Ownable.sol";
import "./libs/token/ERC20/SafeERC20.sol";
import "./libs/math/SafeMath.sol";
import "./libs/lifecycle/Pausable.sol";
import "./libs/common/ZeroCopySink.sol";
import "./libs/common/ZeroCopySource.sol";
import "./libs/token/ERC721/IERC721.sol";
import "./libs/token/ERC721/IERC721Enumerable.sol";
import "./libs/token/ERC721/IERC721Metadata.sol";
import "./libs/utils/ReentrancyGuard.sol";
import "./interface/IPolyNFTLockProxy.sol";

contract PolyNFTWrapperV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    uint public chainId;
    address public feeCollector;
    
    uint public maxLockProxyIndex = 0;
    mapping(uint => address) public lockProxyIndexMap;

    struct CallArgs {
        bytes toAddress;
        uint64 toChainId;
    }

    event PolyWrapperLock(address indexed fromAsset, address indexed sender, uint64 toChainId, address toAddress, uint256 tokenId, address feeToken, uint256 fee, uint id);
    event PolyWrapperSpeedUp(address indexed feeToken, bytes indexed txHash, address indexed sender, uint256 efee);

    constructor(address _owner, uint _chainId) public {
        require(_chainId != 0, "!legal");
        transferOwnership(_owner);
        chainId = _chainId;
    }
    
    function setFeeCollector(address collector) external onlyOwner {
        require(collector != address(0), "emtpy address");
        feeCollector = collector;
    }

    function resetLockProxy(uint index, address _lockProxy) external onlyOwner {
        require(_lockProxy != address(0));
        require(lockProxyIndexMap[index] != address(0), "no lockproxy exsist in given index");
        lockProxyIndexMap[index] = _lockProxy;
        require(IPolyNFTLockProxy(_lockProxy).managerProxyContract() != address(0), "not lockproxy");
    }

    function addLockProxy(address _lockProxy) external onlyOwner {
        require(_lockProxy != address(0));
        lockProxyIndexMap[maxLockProxyIndex++] = _lockProxy;
        require(IPolyNFTLockProxy(_lockProxy).managerProxyContract() != address(0), "not lockproxy");
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function extractFee(address token) external {
        require(msg.sender == feeCollector, "!feeCollector");
        if (token == address(0)) {
            payable(msg.sender).transfer(address(this).balance);
        } else {
            IERC20(token).safeTransfer(feeCollector, IERC20(token).balanceOf(address(this)));
        }
    }

    function lock(address fromAsset, uint64 toChainId, address toAddress, uint256 tokenId, address feeToken, uint256 fee, uint id) external payable nonReentrant whenNotPaused {    
        require(toChainId != chainId && toChainId != 0, "!toChainId");

        _pull(feeToken, fee);
        _push(fromAsset, toChainId, toAddress, tokenId, _getSupportLockProxy(fromAsset, toChainId));
        emit PolyWrapperLock(fromAsset, msg.sender, toChainId, toAddress, tokenId, feeToken, fee, id);
    }

    function specifiedLock(address fromAsset, uint64 toChainId, address toAddress, uint256 tokenId, address feeToken, uint256 fee, uint id, address lockProxy) external payable nonReentrant whenNotPaused {    
        require(toChainId != chainId && toChainId != 0, "!toChainId");

        _pull(feeToken, fee);
        _push(fromAsset, toChainId, toAddress, tokenId, lockProxy);
        emit PolyWrapperLock(fromAsset, msg.sender, toChainId, toAddress, tokenId, feeToken, fee, id);
    }

    function speedUp(address feeToken, bytes memory txHash, uint256 fee) external payable nonReentrant whenNotPaused {
        _pull(feeToken, fee);
        emit PolyWrapperSpeedUp(feeToken, txHash, msg.sender, fee);
    }

    function _pull(address feeToken, uint256 fee) internal {
        if (feeToken == address(0)) {
            require(msg.value == fee, "insufficient ether");
        } else {
            IERC20(feeToken).safeTransferFrom(msg.sender, address(this), fee);
        }
    }

    function _push(address fromAsset, uint64 toChainId, address toAddress, uint256 tokenId, address lockProxy) internal {
        CallArgs memory callArgs = CallArgs({
            toAddress: abi.encodePacked(toAddress),
            toChainId: toChainId
        });
        bytes memory callData = _serializeCallArgs(callArgs);
        IERC721(fromAsset).safeTransferFrom(msg.sender, lockProxy, tokenId, callData);
    }


    function isValidLockProxy(address lockProxy) public view returns(bool) {
        for (uint i=0;i<maxLockProxyIndex;i++) {
            if (lockProxy == lockProxyIndexMap[i]) {
                return true;
            }
        }
        return false;
    }

    function _getSupportLockProxy(address fromAsset, uint64 toChainId) internal view returns(address) {
        for (uint i=0;i<maxLockProxyIndex;i++) {
            address lockProxy = lockProxyIndexMap[i];
            if (IPolyNFTLockProxy(lockProxy).assetHashMap(fromAsset, toChainId).length != 0) {
                return lockProxy;
            }
        }
        revert("No LockProxy Support this cross txn");
    } 

    function _serializeCallArgs(CallArgs memory args) internal pure returns (bytes memory) {
        bytes memory buff;
        buff = abi.encodePacked(
            ZeroCopySink.WriteVarBytes(args.toAddress),
            ZeroCopySink.WriteUint64(args.toChainId)
            );
        return buff;
    }

    function _serializeProfile(bytes memory buff, uint tokenId, string memory url) internal pure returns (bytes memory) {
        buff = abi.encodePacked(
            buff,
            ZeroCopySink.WriteUint256(tokenId),
            ZeroCopySink.WriteVarBytes(bytes(url))
        );
        return buff;
    }

    function _calcEndIndex(uint start, uint length, uint total) internal pure returns (uint) {
        uint end = start + length - 1;
        if (end >= total) {
            end = total - 1;
        }
        return end;
    }
}