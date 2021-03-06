// SPDX-License-Identifier: MIT

pragma solidity >=0.7.6;
pragma abicoder v2;

import { Lib_OVMCodec } from "@eth-optimism/contracts/libraries/codec/Lib_OVMCodec.sol";
import { Lib_EIP155Tx } from "@eth-optimism/contracts/libraries/codec/Lib_EIP155Tx.sol";
import { Lib_BytesUtils } from "@eth-optimism/contracts/libraries/utils/Lib_BytesUtils.sol";
import { iOVM_CanonicalTransactionChain } from "@eth-optimism/contracts/iOVM/chain/iOVM_CanonicalTransactionChain.sol";
import { OVM_StateCommitmentChain } from "@eth-optimism/contracts/OVM/chain/OVM_StateCommitmentChain.sol";
import { L1ClaimableToken } from "./L1ClaimableToken.sol";

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract L1Oracle {
    using SafeMath for uint;

    event Claimed(uint256 indexed tokenId, uint256 indexed amount);

    iOVM_CanonicalTransactionChain public ctc;
    OVM_StateCommitmentChain public scc;
    L1ClaimableToken public claimableToken;

    uint256 public tokenId;
    bytes internal FASTWITHDRAW_SELECTOR = "0x7090fd90"; // fastWithdraw(address,address,address,address,uint256,uint256,uint32,bytes)

    mapping(uint256 => bool) public minted; // l2Txindex => minted

    constructor (address _ctc, address _scc, address _cToken) public {
        ctc = iOVM_CanonicalTransactionChain(_ctc);
        scc = OVM_StateCommitmentChain(_scc);
        claimableToken = L1ClaimableToken(_cToken);
    }

    function processFastWithdrawal (
        uint256 l2TxIndex,
        uint256 chainId,
        Lib_OVMCodec.Transaction memory _transaction,
        Lib_OVMCodec.TransactionChainElement memory _txChainElement,
        Lib_OVMCodec.ChainBatchHeader memory _batchHeader,
        Lib_OVMCodec.ChainInclusionProof memory _inclusionProof
    )
        external
    {
        uint256 prevTotalElements = _batchHeader.prevTotalElements; // 100
        uint256 index = _inclusionProof.index; // 10

        uint256 txIndex = prevTotalElements.add(index); // CompilerError: Stack too deep, try removing local variables.
        require(
            l2TxIndex == txIndex,
            "INVALID_INDEX"
        );
        require(
            !minted[txIndex],
            "ALREADY_MINTED"
        );

        require(
            ctc.verifyTransaction(
                _transaction,
                _txChainElement,
                _batchHeader,
                _inclusionProof
            ),
            "INVALID_PROOF"
        );

        bytes memory encodedTx = _transaction.data;
        Lib_EIP155Tx.EIP155Tx memory decodedTx = Lib_EIP155Tx.decode(
            encodedTx,
            chainId
        );

        bytes memory data = decodedTx.data;
        bytes memory selector = Lib_BytesUtils.slice(data, 0, 4);
        // require(
        //     keccak256(FASTWITHDRAW_SELECTOR) == keccak256(selector),
        //     "INVALID_SELECTOR"
        // );

        bytes memory args = Lib_BytesUtils.slice(data, 4);
        (address _origin, address _l1Token, address _l2Token, uint256 _amount, uint256 _fee) = getTokenInfo(args);

        claimableToken.mint(
            tokenId,
            txIndex,
            _origin,
            _l1Token,
            _l2Token,
            _amount,
            _fee
        );
        minted[txIndex] = true;

        tokenId++;
    }

    function claim (Lib_OVMCodec.ChainBatchHeader memory _batchHeader, uint256 _tokenId) public {
        require(
            Lib_OVMCodec.hashBatchHeader(_batchHeader) == scc.batches().get(_batchHeader.batchIndex),
            "INVALID_HEADER"
        );
        require(
            scc.insideFraudProofWindow(_batchHeader),
            "WITHIN_WINDOW"
        );

        (, uint256 _index, address origin, address l1Token, , uint256 _amount, uint256 _fee, bool _claimed) = claimableToken.tokenInfos(_tokenId);
        require(
            _claimed == false,
            "ALREADY_CLAIMED"
        );
        require(
            _batchHeader.prevTotalElements > _index,
            "OUT_OF_INDEX"
        );

        address receipient = claimableToken.ownerOf(_tokenId);
        if (receipient == address(this)) {
            receipient = origin;
        }
        uint256 amount = _amount.add(_fee);

        require(
            IERC20(l1Token).transfer(receipient, amount),
            "FAIL_TRANSFER"
        );

        claimableToken.claim(_tokenId);

        emit Claimed(_tokenId, amount);
    }

    function setApprovalForAll (address operator, bool approved) public {
        claimableToken.setApprovalForAll(operator, approved);
    }

    // CompilerError: Stack too deep, try removing local variables.
    function getTokenInfo(bytes memory args) internal returns (address, address, address, uint256, uint256) {
        (
          address _origin,
          address _l1Token,
          address _l2Token,
          address _to,
          uint256 _amount,
          uint256 _fee,
          uint32 _l1Gas,
          bytes memory _data
        ) = abi.decode(
            args,
            (address, address, address, address, uint256, uint256, uint32, bytes)
        );

        return (_origin, _l1Token, _l2Token, _amount, _fee);
    }
}
