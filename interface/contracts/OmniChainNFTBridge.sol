//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "https://github.com/wormhole-foundation/wormhole/blob/dev.v2/ethereum/contracts/interfaces/IWormhole.sol";import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract OmniChainNFTBridge is ERC721 {

    uint private mintCost;
    uint public tokenCount;
    uint public maxSupply;

    IWormhole immutable core_bridge;
    uint16 immutable chainId;
    uint16 nonce = 0;
    mapping(bytes32 => mapping(uint16 => bool)) public myTrustedContracts;
    mapping(bytes32 => bool) public processedMessages;

    constructor(string memory _name, string memory _symbol, uint16 _chainId, address wormhole_core_bridge_address) ERC721(_name, _symbol) {
        tokenCount = 0;
        maxSupply = 9000;
        chainId = _chainId;
        core_bridge = IWormhole(wormhole_core_bridge_address);
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireMinted(tokenId);
        return string(abi.encodePacked("https://api.coolcatsnft.com/cat/",Strings.toString(tokenId)));
    }

    function mintToken(address _msgSender) private {
        tokenCount = tokenCount + 1;
        require(tokenCount <= maxSupply, "Max Supply Is Reached!!");
        super._mint(_msgSender,  tokenCount);
    }

    function initiateMint() public payable {
        mintToken(msg.sender);
    }

    function _debitFrom(address _from, uint16, bytes memory, uint _tokenId) internal virtual override {
        require(_isApprovedOrOwner(_msgSender(), _tokenId), "ONFT721: send caller is not owner nor approved");
        require(ERC721.ownerOf(_tokenId) == _from, "ONFT721: send from incorrect owner");
        _transfer(_from, address(this), _tokenId);
    }

    function _sendMessageToRecipient(
        address recipient,
        uint16 _chainId,
        string memory message,
        uint32 _nonce
    ) private returns (uint64) {
        bytes memory payload = abi.encode(
            recipient,
            _chainId,
            msg.sender,
            message
        );

        // Nonce is passed though to the core bridge.
        // This allows other contracts to utilize it for batching or processing.

        // 1 is the consistency level, this message will be emitted after only 1 block
        uint64 sequence = core_bridge.publishMessage(_nonce, payload, 1);

        // The sequence is passed back to the caller, which can be useful relay information.
        // Relaying is not done here, because it would 'lock' others into the same relay mechanism.
        return sequence;
    }

    function sendMessage(
        string memory message,
        address destAddress,
        uint16 destChainId,
        uint _tokenId
    ) external payable {
        // Wormhole recommends that message-publishing functions should return their sequence value
        __debitFrom(msg.sender,"",_tokenId);
        _sendMessageToRecipient(destAddress, destChainId, message, nonce);
        nonce++;
    }

    function _creditTo(uint16, address _toAddress, uint _tokenId) internal virtual override {
        require(!_exists(_tokenId) || (_exists(_tokenId) && ERC721.ownerOf(_tokenId) == address(this)));
        if (!_exists(_tokenId)) {
            _safeMint(_toAddress, _tokenId);
        } else {
            _transfer(address(this), _toAddress, _tokenId);
        }
    }

    // TODO: A production app would add onlyOwner security, but this is for testing.
    function addTrustedAddress(bytes32 sender, uint16 _chainId) external {
        myTrustedContracts[sender][_chainId] = true;
    }

    function stringToUint(string s) returns (uint result) {
        bytes memory b = bytes(s);
        uint i;
        result = 0;
        for (i = 0; i < b.length; i++) {
            uint c = uint(b[i]);
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
    }

    // Verification accepts a single VAA, and is publicly callable.
    function processMyMessage(bytes memory VAA) public {
        // This call accepts single VAAs and headless VAAs
        (IWormhole.VM memory vm, bool valid, string memory reason) = core_bridge
            .parseAndVerifyVM(VAA);

        // Ensure core contract verifies the VAA
        require(valid, reason);

        // Ensure the emitterAddress of this VAA is a trusted address
        require(
            myTrustedContracts[vm.emitterAddress][vm.emitterChainId],
            "Invalid emitter address!"
        );

        // Check that the VAA hasn't already been processed (replay protection)
        require(!processedMessages[vm.hash], "Message already processed");

        // Parse intended data
        // You could attempt to parse the sender from the bytes32, but that's hard, hence why address was included in the payload
        (
            address intendedRecipient,
            uint16 _chainId,
            address sender,
            string memory message
        ) = abi.decode(vm.payload, (address, uint16, address, string));

        // Check that the contract which is processing this VAA is the intendedRecipient
        // If the two aren't equal, this VAA may have bypassed its intended entrypoint.
        // This exploit is referred to as 'scooping'.
        require(
            intendedRecipient == address(this),
            "Not the intended receipient!"
        );

        // Check that the contract that is processing this VAA is the intended chain.
        // By default, a message is accessible by all chains, so we have to define a destination chain & check for it.
        require(_chainId == chainId, "Not the intended chain!");

        // Add the VAA to processed messages so it can't be replayed
        processedMessages[vm.hash] = true;

        // The message content can now be trusted, slap into messages
        _creditTo(sender, stringToUint(message));
    }
}