pragma solidity ^0.8.0;
import "../src/WebAuthnValidator.sol";
import {MockCallee, KernelTestBase} from "kernel/sdk/KernelTestBase.sol";
import {PackedUserOperation} from "kernel/interfaces/PackedUserOperation.sol";
import {ValidatorLib} from "kernel/utils/ValidationTypeLib.sol";
import {ExecLib} from "kernel/utils/ExecLib.sol";
import {IHook} from "kernel/interfaces/IERC7579Modules.sol";
import {ValidatorLib, ValidationId, ValidationMode, ValidationType} from "kernel/utils/ValidationTypeLib.sol";
import {VALIDATION_MODE_ENABLE, VALIDATION_TYPE_VALIDATOR} from "kernel/types/Constants.sol";

import {P256Verifier} from "../src/P256Verifier.sol";
import {P256} from "../src/P256.sol";
import {FCL_ecdsa_utils} from "FreshCryptoLib/FCL_ecdsa_utils.sol";
import "forge-std/console.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";

contract WebAuthnValidatorTest is KernelTestBase {
    P256Verifier p256Verifier;
    WebAuthnValidator webAuthnValidator;
    // Curve order (number of points)
    uint256 constant n = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    uint256 x;
    uint256 y;

    uint256 challengeLocation = 23;
    uint256 responseTypeLocation = 1;
    uint256 counter = 144444;

    address owner;
    uint256 ownerKey;
    function _setRootValidationConfig() internal override {
        vm.etch(0xc2b78104907F722DABAc4C69f826a522B2754De4, hex"60e06040523461001a57610012366100c7565b602081519101f35b600080fd5b6040810190811067ffffffffffffffff82111761003b57604052565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b60e0810190811067ffffffffffffffff82111761003b57604052565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff82111761003b57604052565b60a08103610193578060201161001a57600060409180831161018f578060601161018f578060801161018f5760a01161018c57815182810181811067ffffffffffffffff82111761015f579061013291845260603581526080356020820152833560203584356101ab565b15610156575060ff6001915b5191166020820152602081526101538161001f565b90565b60ff909161013e565b6024837f4e487b710000000000000000000000000000000000000000000000000000000081526041600452fd5b80fd5b5080fd5b5060405160006020820152602081526101538161001f565b909283158015610393575b801561038b575b8015610361575b6103585780519060206101dc818301938451906103bd565b1561034d57604051948186019082825282604088015282606088015260808701527fffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc63254f60a08701527fffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551958660c082015260c081526102588161006a565b600080928192519060055afa903d15610345573d9167ffffffffffffffff831161031857604051926102b1857fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f8401160185610086565b83523d828585013e5b156102eb57828280518101031261018c5750015190516102e693929185908181890994099151906104eb565b061490565b807f4e487b7100000000000000000000000000000000000000000000000000000000602492526001600452fd5b6024827f4e487b710000000000000000000000000000000000000000000000000000000081526041600452fd5b6060916102ba565b505050505050600090565b50505050600090565b507fffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc6325518310156101c4565b5082156101bd565b507fffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc6325518410156101b6565b7fffffffff00000001000000000000000000000000ffffffffffffffffffffffff90818110801590610466575b8015610455575b61044d577f5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b8282818080957fffffffff00000001000000000000000000000000fffffffffffffffffffffffc0991818180090908089180091490565b505050600090565b50801580156103f1575082156103f1565b50818310156103ea565b7f800000000000000000000000000000000000000000000000000000000000000081146104bc577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b909192608052600091600160a05260a05193600092811580610718575b61034d57610516838261073d565b95909460ff60c05260005b600060c05112156106ef575b60a05181036106a1575050507f4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5957f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2969594939291965b600060c05112156105c7575050505050507fffffffff00000001000000000000000000000000ffffffffffffffffffffffff91506105c260a051610ca2565b900990565b956105d9929394959660a05191610a98565b9097929181928960a0528192819a6105f66080518960c051610722565b61060160c051610470565b60c0528061061b5750505050505b96959493929196610583565b969b5061067b96939550919350916001810361068857507f4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5937f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c29693610952565b979297919060a05261060f565b6002036106985786938a93610952565b88938893610952565b600281036106ba57505050829581959493929196610583565b9197917ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd0161060f575095508495849661060f565b506106ff6080518560c051610722565b8061070b60c051610470565b60c052156105215761052d565b5060805115610508565b91906002600192841c831b16921c1681018091116104bc5790565b8015806107ab575b6107635761075f91610756916107b3565b92919091610c42565b9091565b50507f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296907f4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f590565b508115610745565b919082158061094a575b1561080f57507f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c29691507f4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5906001908190565b7fb01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a917fffffffff00000001000000000000000000000000ffffffffffffffffffffffff808481600186090894817f94e82e0c1ed3bdb90743191a9c5bbf0d88fc827fd214cc5f0b5ec6ba27673d6981600184090893841561091b575050808084800993840994818460010994828088600109957f6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c29609918784038481116104bc5784908180867fffffffff00000001000000000000000000000000fffffffffffffffffffffffd0991818580090808978885038581116104bc578580949281930994080908935b93929190565b9350935050921560001461093b5761093291610b6d565b91939092610915565b50506000806000926000610915565b5080156107bd565b91949592939095811580610a90575b15610991575050831580610989575b61097a5793929190565b50600093508392508291508190565b508215610970565b85919294951580610a88575b610a78577fffffffff00000001000000000000000000000000ffffffffffffffffffffffff968703918783116104bc5787838189850908938689038981116104bc5789908184840908928315610a5d575050818880959493928180848196099b8c9485099b8c920999099609918784038481116104bc5784908180867fffffffff00000001000000000000000000000000fffffffffffffffffffffffd0991818580090808978885038581116104bc578580949281930994080908929190565b965096505050509093501560001461093b5761093291610b6d565b9550509150915091906001908190565b50851561099d565b508015610961565b939092821580610b65575b61097a577fffffffff00000001000000000000000000000000ffffffffffffffffffffffff908185600209948280878009809709948380888a0998818080808680097fffffffff00000001000000000000000000000000fffffffffffffffffffffffc099280096003090884808a7fffffffff00000001000000000000000000000000fffffffffffffffffffffffd09818380090898898603918683116104bc57888703908782116104bc578780969481809681950994089009089609930990565b508015610aa3565b919091801580610c3a575b610c2d577fffffffff00000001000000000000000000000000ffffffffffffffffffffffff90818460020991808084800980940991817fffffffff00000001000000000000000000000000fffffffffffffffffffffffc81808088860994800960030908958280837fffffffff00000001000000000000000000000000fffffffffffffffffffffffd09818980090896878403918483116104bc57858503928584116104bc5785809492819309940890090892565b5060009150819081908190565b508215610b78565b909392821580610c9a575b610c8d57610c5a90610ca2565b9182917fffffffff00000001000000000000000000000000ffffffffffffffffffffffff80809581940980099009930990565b5050509050600090600090565b508015610c4d565b604051906020918281019183835283604083015283606083015260808201527fffffffff00000001000000000000000000000000fffffffffffffffffffffffd60a08201527fffffffff00000001000000000000000000000000ffffffffffffffffffffffff60c082015260c08152610d1a8161006a565b600080928192519060055afa903d15610d93573d9167ffffffffffffffff83116103185760405192610d73857fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f8401160185610086565b83523d828585013e5b156102eb57828280518101031261018c5750015190565b606091610d7c56fea2646970667358221220fa55558b04ced380e93d0a46be01bb895ff30f015c50c516e898c341cd0a230264736f6c63430008150033");
        (owner, ownerKey) = makeAddrAndKey("Owner");
        webAuthnValidator = new WebAuthnValidator();
        (x, y) = generatePublicKey(ownerKey);
        rootValidation = ValidatorLib.validatorToIdentifier(webAuthnValidator);
        bool usePrecompiled = generateUsePrecompiled(false);
        rootValidationConfig =
            RootValidationConfig({hook: IHook(address(0)), hookData: hex"", validatorData: abi.encode(x, y, "")});
    }

    function _rootSignDigest(bytes32 digest, bool success) internal view override returns (bytes memory data) {
        bytes memory authenticatorData = createAuthenticatorData(true, true, counter);
        unchecked {
            if (!success) {
                digest = bytes32(uint256(digest) - 1);
            }
        }
        string memory clientDataJSON = createClientDataJSON(digest);
        bytes32 webAuthnHash = generateWebAuthnHash(authenticatorData, clientDataJSON);
        (uint256 r, uint256 s) = generateSignature(ownerKey, webAuthnHash);
        bytes memory sig = abi.encode(authenticatorData, clientDataJSON, responseTypeLocation, r, s, false);
        return sig;
    }

    function findChallengeLocation(string memory clientDataJSON) public pure returns (uint256) {
        bytes memory data = bytes(clientDataJSON);
        for (uint256 i = 0; i < data.length - 9; i++) {
            // "challenge" is 9 characters long
            if (
                data[i] == '"' // Check for quote
                    && data[i + 1] == "c" && data[i + 2] == "h" && data[i + 3] == "a" && data[i + 4] == "l"
                    && data[i + 5] == "l" && data[i + 6] == "e" && data[i + 7] == "n" && data[i + 8] == "g"
                    && data[i + 9] == "e"
            ) {
                return i; // Return the index of the quote
            }
        }
        revert("Challenge not found");
    }

    function generatePublicKey(uint256 privateKey) internal view returns (uint256, uint256) {
        return FCL_ecdsa_utils.ecdsa_derivKpub(privateKey);
    }

    function generateSignature(uint256 privateKey, bytes32 hash) internal view returns (uint256 r, uint256 s) {
        // Securely generate a random k value for each signature
        uint256 k = uint256(keccak256(abi.encodePacked(hash, block.timestamp, block.prevrandao, privateKey))) % n;
        while (k == 0) {
            k = uint256(keccak256(abi.encodePacked(k))) % n;
        }

        // Generate the signature using the k value and the private key
        (r, s) = FCL_ecdsa_utils.ecdsa_sign(hash, k, privateKey);

        // Ensure that s is in the lower half of the range [1, n-1]
        if (r == 0 || s == 0 || s > P256.P256_N_DIV_2) {
            s = n - s; // If s is in the upper half, use n - s instead
        }

        return (r, s);
    }

    function generateWebAuthnHash(bytes memory authenticatorData, string memory clientDataJSON)
        internal
        pure
        returns (bytes32)
    {
        bytes32 clientDataJSONHash = sha256(bytes(clientDataJSON));
        return sha256(abi.encodePacked(authenticatorData, clientDataJSONHash));
    }

    function createClientDataJSON(bytes32 challenge) internal view returns (string memory) {
        // string memory challengeString = LibString.toHexString(
        //     uint256(challenge),
        //     32
        // );
        string memory encodedChallenge = Base64.encode(abi.encodePacked(challenge), true, true);
        return string(
            abi.encodePacked(
                '{"type":"webauthn.get","challenge":"',
                encodedChallenge,
                '","origin":"https://funny-froyo-3f9b75.netlify.app","crossOrigin":false}'
            )
        );
    }

    function createAuthenticatorData(bool userPresent, bool userVerified, uint256 counter)
        internal
        pure
        returns (bytes memory)
    {
        // Flags (bit 0 is the least significant bit):
        // - Bit 0: User Present (UP) result.
        // - Bit 2: User Verified (UV) result.
        // Other bits and flags can be set as needed per the WebAuthn specification.
        bytes1 flags = bytes1(uint8(userPresent ? 0x01 : 0x00) | uint8(userVerified ? 0x04 : 0x00));

        // Counter is a 32-bit unsigned big-endian integer.
        bytes memory counterBytes = abi.encodePacked(uint32(counter));

        // Combine the flags and counter into the authenticatorData.
        bytes32 rpIdHash = keccak256("example.com"); // Replace "example.com" with the actual RP ID.
        return abi.encodePacked(rpIdHash, flags, counterBytes);
    }

    function _rootSignUserOp(PackedUserOperation memory op, bool success)
        internal
        view
        override
        returns (bytes memory)
    {
        bytes32 hash = entrypoint.getUserOpHash(op);
        return _rootSignDigest(hash, success);
    }

    function generateUsePrecompiled(bool usePrecompiled) internal pure returns (bool) {
        return usePrecompiled;
    }
}
