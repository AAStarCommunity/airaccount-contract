// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {AAStarAirAccountV7} from "../src/core/AAStarAirAccountV7.sol";
import {AAStarAirAccountBase} from "../src/core/AAStarAirAccountBase.sol";
import {AAStarGlobalGuard} from "../src/core/AAStarGlobalGuard.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {IERC8004ReputationRegistry} from "../src/interfaces/IERC8004ReputationRegistry.sol";
import {ERC8004Addresses} from "../src/config/ERC8004Addresses.sol";

// ─── Mock ERC-8004 IdentityRegistry ────────────────────────────────────────

contract MockERC8004Identity is IERC8004IdentityRegistry {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _wallets;
    mapping(uint256 => string)  private _uris;
    uint256 private _next;

    // IERC165 / IERC721 stubs
    function supportsInterface(bytes4) external pure returns (bool) { return false; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function ownerOf(uint256 id) external view virtual returns (address o) {
        o = _owners[id]; require(o != address(0), "not minted");
    }
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure { revert("soulbound"); }
    function safeTransferFrom(address, address, uint256) external pure { revert("soulbound"); }
    function transferFrom(address, address, uint256) external pure { revert("soulbound"); }
    function approve(address, uint256) external pure { revert("soulbound"); }
    function setApprovalForAll(address, bool) external pure { revert("soulbound"); }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }

    function register() external returns (uint256 id) {
        id = _next++; _owners[id] = msg.sender; _wallets[id] = msg.sender;
    }
    function register(string calldata uri) external virtual returns (uint256 id) {
        id = _next++; _owners[id] = msg.sender; _wallets[id] = msg.sender; _uris[id] = uri;
    }
    function register(string calldata uri, IERC8004IdentityRegistry.MetadataEntry[] calldata)
        external returns (uint256 id) {
        id = _next++; _owners[id] = msg.sender; _wallets[id] = msg.sender; _uris[id] = uri;
    }
    function setAgentURI(uint256 id, string calldata uri) external { _uris[id] = uri; }
    function getMetadata(uint256, string memory) external pure returns (bytes memory) { return ""; }
    function setMetadata(uint256, string memory, bytes memory) external {}
    function setAgentWallet(uint256 id, address w, uint256, bytes calldata) external { _wallets[id] = w; }
    function getAgentWallet(uint256 id) external view returns (address) { return _wallets[id]; }
    function unsetAgentWallet(uint256 id) external { delete _wallets[id]; }
    function isAuthorizedOrOwner(address s, uint256 id) external view returns (bool) { return _owners[id] == s; }
    function getVersion() external pure returns (string memory) { return "2.0.0"; }

    function tokenURI(uint256 id) external view returns (string memory) { return _uris[id]; }
}

// ─── Mock ERC-8004 ReputationRegistry ─────────────────────────────────────

contract MockERC8004Reputation is IERC8004ReputationRegistry {
    struct Feedback { int128 v; uint8 dec; string t1; string t2; address client; }
    mapping(uint256 => Feedback[]) private _fb;

    function initialize(address) external {}
    function getIdentityRegistry() external pure returns (address) { return address(0); }

    function giveFeedback(
        uint256 agentId, int128 value, uint8 dec,
        string calldata t1, string calldata t2,
        string calldata, string calldata, bytes32
    ) external {
        _fb[agentId].push(Feedback(value, dec, t1, t2, msg.sender));
    }
    function revokeFeedback(uint256, uint64) external {}
    function appendResponse(uint256, address, uint64, string calldata, bytes32) external {}

    function readFeedback(uint256 id, address, uint64 idx)
        external view returns (int128 v, uint8 dec, string memory t1, string memory t2, bool) {
        Feedback storage f = _fb[id][idx];
        return (f.v, f.dec, f.t1, f.t2, false);
    }
    function readAllFeedback(uint256, address[] calldata, string calldata, string calldata, bool)
        external pure returns (address[] memory, uint64[] memory, int128[] memory, uint8[] memory, string[] memory, string[] memory, bool[] memory) {
        revert("not implemented in mock");
    }
    function getSummary(uint256 agentId, address[] calldata, string calldata, string calldata)
        external view returns (uint64 count, int128 sum, uint8 dec) {
        count = uint64(_fb[agentId].length);
        for (uint256 i; i < count; i++) sum += _fb[agentId][i].v;
        dec = count > 0 ? _fb[agentId][0].dec : 2;
    }
    function getResponseCount(uint256, address, uint64, address[] calldata) external pure returns (uint64) { return 0; }
    function getClients(uint256) external pure returns (address[] memory) { return new address[](0); }
    function getLastIndex(uint256, address) external pure returns (uint64) { return 0; }
}

// ─── Safe-minting mock — simulates official ERC-8004 _safeMint behaviour ──────
// Official IdentityRegistryUpgradeable calls _safeMint, which invokes onERC721Received
// on contract recipients.  This mock replicates that check so the test suite catches
// any regression where AirAccount stops implementing IERC721Receiver.

contract SafeMintMockRegistry is MockERC8004Identity {
    mapping(uint256 => address) private _smOwners;
    uint256 private _smNext;

    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    function register(string calldata uri) external override returns (uint256 id) {
        id = _smNext++;
        _smOwners[id] = msg.sender;
        // simulate _safeMint: call onERC721Received if recipient is a contract
        if (msg.sender.code.length > 0) {
            bytes4 retval = IERC721ReceiverMini(msg.sender).onERC721Received(
                address(this), address(0), id, ""
            );
            require(retval == _ERC721_RECEIVED, "ERC721: transfer to non ERC721Receiver");
        }
    }

    function ownerOf(uint256 id) external view override returns (address o) {
        o = _smOwners[id];
        require(o != address(0), "not minted");
    }
}

interface IERC721ReceiverMini {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

// ─── Test suite ────────────────────────────────────────────────────────────

contract ERC8004IntegrationTest is Test {
    MockERC8004Identity   public idReg;
    SafeMintMockRegistry  public safeMintReg;
    MockERC8004Reputation public repReg;
    AAStarAirAccountV7    public account;

    Vm.Wallet ownerWallet;
    address   agent;

    // Official ERC-8004 Sepolia addresses — the account pins registry calls to these.
    address constant OFFICIAL_IDENTITY   = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address constant OFFICIAL_REPUTATION = 0x8004B663056A597Dffe9eCcC1965A193B7388713;

    function setUp() public {
        // Run on Sepolia so ERC8004Addresses resolves to the official testnet deployment.
        vm.chainId(11155111);
        agent  = makeAddr("agent");

        // Place mock bytecode at the official addresses the contract validates against.
        // Storage at the etched address starts fresh, which is what the mocks expect.
        vm.etch(OFFICIAL_IDENTITY, address(new MockERC8004Identity()).code);
        idReg = MockERC8004Identity(OFFICIAL_IDENTITY);

        vm.etch(OFFICIAL_REPUTATION, address(new MockERC8004Reputation()).code);
        repReg = MockERC8004Reputation(OFFICIAL_REPUTATION);

        // safeMintReg shares the single official identity slot; tests that need it etch it in-place.
        safeMintReg = new SafeMintMockRegistry();

        ownerWallet = vm.createWallet("owner");
        account     = new AAStarAirAccountV7();

        uint8[] memory algs = new uint8[](0);
        address[] memory noGuardians;
        noGuardians = new address[](3);
        noGuardians[0] = makeAddr("g0");
        noGuardians[1] = makeAddr("g1");
        noGuardians[2] = makeAddr("g2");

        account.initialize(makeAddr("ep"), ownerWallet.addr, AAStarAirAccountBase.InitConfig({
            guardians: [noGuardians[0], noGuardians[1], noGuardians[2]],
            dailyLimit: 0,
            approvedAlgIds: algs,
            minDailyLimit: 0,
            initialTokens: new address[](0),
            initialTokenConfigs: new AAStarGlobalGuard.TokenConfig[](0)
        }));
    }

    // ─── ERC8004Addresses library ─────────────────────────────────────────────

    function test_addresses_sepolia_identity() public pure {
        assertEq(
            ERC8004Addresses.identityRegistry(11155111),
            0x8004A818BFB912233c491871b3d84c89A494BD9e,
            "Sepolia identity"
        );
    }
    function test_addresses_sepolia_reputation() public pure {
        assertEq(
            ERC8004Addresses.reputationRegistry(11155111),
            0x8004B663056A597Dffe9eCcC1965A193B7388713,
            "Sepolia reputation"
        );
    }
    function test_addresses_sepolia_validation() public pure {
        assertEq(
            ERC8004Addresses.validationRegistry(11155111),
            0x8004Cb1BF31DAf7788923b405b754f57acEB4272,
            "Sepolia validation"
        );
    }
    function test_addresses_opSepolia_sameAsEthSepolia() public pure {
        assertEq(
            ERC8004Addresses.identityRegistry(11155420),
            ERC8004Addresses.identityRegistry(11155111),
            "OP Sepolia == Eth Sepolia"
        );
    }
    function test_addresses_mainnet_identity() public pure {
        assertEq(
            ERC8004Addresses.identityRegistry(1),
            0x8004A169FB4a3325136EB29fA0ceB6D2e539a432,
            "ETH mainnet identity"
        );
    }
    function test_addresses_mainnet_reputation() public pure {
        assertEq(
            ERC8004Addresses.reputationRegistry(1),
            0x8004BAa17C55a88189AE136b182e5fdA19dE9b63,
            "ETH mainnet reputation"
        );
    }
    function test_addresses_mainnet_validation() public pure {
        assertEq(
            ERC8004Addresses.validationRegistry(1),
            0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58,
            "ETH mainnet validation"
        );
    }
    function test_addresses_opMainnet_sameAsEthMainnet() public pure {
        assertEq(ERC8004Addresses.identityRegistry(10),  ERC8004Addresses.identityRegistry(1), "OP Mainnet identity == Eth");
        assertEq(ERC8004Addresses.reputationRegistry(10), ERC8004Addresses.reputationRegistry(1), "OP Mainnet reputation == Eth");
        assertEq(ERC8004Addresses.validationRegistry(10), ERC8004Addresses.validationRegistry(1), "OP Mainnet validation == Eth");
    }

    // ─── mintAgentIdentity ────────────────────────────────────────────────────

    function test_mintAgentIdentity_mintsNFTToAccount() public {
        vm.prank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://QmAgent1");
        assertEq(idReg.ownerOf(id), address(account));
    }

    function test_mintAgentIdentity_storesURI() public {
        vm.prank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://QmAgent1");
        assertEq(idReg.tokenURI(id), "ipfs://QmAgent1");
    }

    function test_mintAgentIdentity_emitsEvent() public {
        vm.prank(ownerWallet.addr);
        vm.expectEmit(true, true, false, true);
        emit AAStarAirAccountBase.AgentIdentityMinted(0, address(idReg), "ipfs://QmAgent1");
        account.mintAgentIdentity(address(idReg), "ipfs://QmAgent1");
    }

    function test_mintAgentIdentity_returnsIncrementingIds() public {
        vm.startPrank(ownerWallet.addr);
        uint256 id0 = account.mintAgentIdentity(address(idReg), "ipfs://Qm0");
        uint256 id1 = account.mintAgentIdentity(address(idReg), "ipfs://Qm1");
        vm.stopPrank();
        assertEq(id0, 0);
        assertEq(id1, 1);
    }

    function test_mintAgentIdentity_notOwner_reverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        account.mintAgentIdentity(address(idReg), "ipfs://Qm");
    }

    function test_mintAgentIdentity_zeroRegistry_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.UnauthorizedRegistry.selector);
        account.mintAgentIdentity(address(0), "ipfs://Qm");
    }

    function test_mintAgentIdentity_nonOfficialRegistry_reverts() public {
        // Any address other than the official ERC-8004 registry for this chain is rejected.
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.UnauthorizedRegistry.selector);
        account.mintAgentIdentity(makeAddr("rogueRegistry"), "ipfs://Qm");
    }

    // ─── bindERC8004AgentWallet ───────────────────────────────────────────────

    function test_bind_linksWallet() public {
        vm.startPrank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://QmBind");
        account.bindERC8004AgentWallet(address(idReg), id, agent, block.timestamp + 60, "");
        vm.stopPrank();
        assertEq(idReg.getAgentWallet(id), agent);
    }

    function test_bind_emitsEvent() public {
        vm.startPrank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://QmBind");
        vm.expectEmit(true, true, true, false);
        emit AAStarAirAccountBase.ERC8004WalletBound(id, agent, address(idReg));
        account.bindERC8004AgentWallet(address(idReg), id, agent, block.timestamp + 60, "");
        vm.stopPrank();
    }

    function test_bind_notOwner_reverts() public {
        vm.prank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://Qm");
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        account.bindERC8004AgentWallet(address(idReg), id, agent, block.timestamp + 60, "");
    }

    function test_bind_zeroWallet_reverts() public {
        vm.startPrank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://Qm");
        vm.expectRevert(AAStarAirAccountBase.IdentityRegistrationFailed.selector);
        account.bindERC8004AgentWallet(address(idReg), id, address(0), block.timestamp + 60, "");
        vm.stopPrank();
    }

    // ─── submitAgentReputation ────────────────────────────────────────────────

    function test_reputation_recordsFeedback() public {
        vm.startPrank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://Qm");
        account.submitAgentReputation(
            address(repReg), id, 95, 2, "quality", "task:swap",
            "https://agent.example.com", "ipfs://QmFb", bytes32(0)
        );
        vm.stopPrank();

        address[] memory empty = new address[](0);
        (uint64 count, int128 val,) = account.queryAgentReputation(
            address(repReg), id, empty, "quality", "task:swap"
        );
        assertEq(count, 1);
        assertEq(val, 95);
    }

    function test_reputation_emitsEvent() public {
        vm.startPrank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(address(idReg), "ipfs://Qm");
        vm.expectEmit(true, true, false, true);
        emit AAStarAirAccountBase.AgentReputationSubmitted(id, address(repReg), 95, "quality");
        account.submitAgentReputation(
            address(repReg), id, 95, 2, "quality", "", "", "ipfs://Qm", bytes32(0)
        );
        vm.stopPrank();
    }

    function test_reputation_notOwner_reverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        account.submitAgentReputation(
            address(repReg), 0, 95, 2, "quality", "", "", "", bytes32(0)
        );
    }

    function test_reputation_zeroRegistry_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.UnauthorizedRegistry.selector);
        account.submitAgentReputation(address(0), 0, 95, 2, "quality", "", "", "", bytes32(0));
    }

    function test_reputation_nonOfficialRegistry_reverts() public {
        vm.prank(ownerWallet.addr);
        vm.expectRevert(AAStarAirAccountBase.UnauthorizedRegistry.selector);
        account.submitAgentReputation(makeAddr("rogueRep"), 0, 95, 2, "quality", "", "", "", bytes32(0));
    }

    // ─── Full ERC-8004 flow ───────────────────────────────────────────────────

    function test_fullERC8004Flow() public {
        vm.startPrank(ownerWallet.addr);

        // 1. Register agent identity on official registry
        uint256 agentId = account.mintAgentIdentity(address(idReg), "ipfs://QmFullFlow");
        assertEq(idReg.ownerOf(agentId), address(account));

        // 2. Bind session key as execution wallet
        account.bindERC8004AgentWallet(address(idReg), agentId, agent, block.timestamp + 60, "");
        assertEq(idReg.getAgentWallet(agentId), agent);

        // 3. After agent interaction: submit reputation
        account.submitAgentReputation(
            address(repReg), agentId,
            90, 2,
            "reliability", "task:swap",
            "agent.example.com",
            "ipfs://QmRep",
            keccak256("feedback payload")
        );

        // 4. Verify reputation is recorded
        address[] memory clients = new address[](0);
        (uint64 count, int128 val, uint8 dec) = account.queryAgentReputation(
            address(repReg), agentId, clients, "reliability", "task:swap"
        );
        assertEq(count, 1);
        assertEq(val, 90);
        assertEq(dec, 2);
        vm.stopPrank();
    }

    // ─── C-2: onERC721Received / IERC721Receiver ─────────────────────────────

    /// Official ERC-8004 IdentityRegistry uses _safeMint. Verify AirAccount accepts the NFT.
    function test_safeMint_accountReceivesNFT() public {
        // Place the _safeMint-simulating mock at the official identity address for this test.
        vm.etch(OFFICIAL_IDENTITY, address(safeMintReg).code);
        SafeMintMockRegistry reg = SafeMintMockRegistry(OFFICIAL_IDENTITY);
        vm.prank(ownerWallet.addr);
        uint256 id = account.mintAgentIdentity(OFFICIAL_IDENTITY, "ipfs://QmSafeMint");
        assertEq(reg.ownerOf(id), address(account));
    }

    /// onERC721Received must return the ERC-721 magic value.
    function test_onERC721Received_returnsMagicValue() public view {
        bytes4 ret = account.onERC721Received(address(0), address(0), 0, "");
        assertEq(ret, bytes4(0x150b7a02));
    }

    /// supportsInterface must advertise IERC721Receiver support.
    function test_supportsInterface_erc721Receiver() public view {
        assertTrue(account.supportsInterface(0x150b7a02));
    }

    /// supportsInterface still returns true for ERC-165 and ERC-1271.
    function test_supportsInterface_erc165AndERC1271() public view {
        assertTrue(account.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(account.supportsInterface(0x1626ba7e)); // ERC-1271
    }
}
