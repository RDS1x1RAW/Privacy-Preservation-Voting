// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/**
 * @title NFTMarketplace
 * @dev A decentralized marketplace for trading NFTs with privacy-preserving voting mechanisms
 * @author Your Name
 */
contract NFTMarketplace is ReentrancyGuard, Ownable, ERC721Holder {
    
    // Marketplace fee (can be updated by owner)
    uint256 public marketplaceFee = 250; // 250 basis points = 2.5%
    uint256 public constant BASIS_POINTS = 10000;
    
    // Privacy-preserving voting constants
    uint256 public constant VOTING_DURATION = 7 days;
    uint256 public constant MIN_VOTES_REQUIRED = 10;
    
    struct Listing {
        uint256 tokenId;
        address nftContract;
        address seller;
        uint256 price;
        bool active;
        uint256 listedAt;
    }
    
    struct Vote {
        bytes32 commitHash; // Commit phase - hash of vote + salt
        bool revealed;      // Whether vote has been revealed
        bool support;       // True for support, false for against (only valid after reveal)
        uint256 timestamp;  // When the vote was committed
    }
    
    struct Proposal {
        string description;
        uint256 listingId;
        address proposer;
        uint256 createdAt;
        uint256 votingEnds;
        uint256 totalVotes;
        uint256 revealedVotes;
        uint256 supportVotes;
        bool executed;
        bool passed;
    }
    
    // Storage
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Proposal) public proposals;
    
    // Proposal voting storage
    mapping(uint256 => mapping(address => Vote)) public proposalVotes; // proposalId => voter => Vote
    
    uint256 public nextListingId = 1;
    uint256 public nextProposalId = 1;
    
    // Events
    event NFTListed(
        uint256 indexed listingId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        uint256 price
    );
    
    event NFTSold(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 price
    );
    
    event ListingCancelled(uint256 indexed listingId);
    
    event ProposalCreated(
        uint256 indexed proposalId,
        string description,
        uint256 indexed listingId,
        address indexed proposer
    );
    
    event VoteCommitted(
        uint256 indexed proposalId,
        address indexed voter,
        bytes32 commitHash
    );
    
    event VoteRevealed(
        uint256 indexed proposalId,
        address indexed voter,
        bool support
    );
    
    event ProposalExecuted(uint256 indexed proposalId, bool passed);
    
    event MarketplaceFeeUpdated(uint256 oldFee, uint256 newFee);
    
    constructor() Ownable(msg.sender) {}
    
    /**
     * @dev List an NFT for sale on the marketplace
     * @param _nftContract Address of the NFT contract
     * @param _tokenId Token ID of the NFT
     * @param _price Price in wei
     */
    function listNFT(
        address _nftContract,
        uint256 _tokenId,
        uint256 _price
    ) external nonReentrant {
        require(_price > 0, "Price must be greater than 0");
        require(
            IERC721(_nftContract).ownerOf(_tokenId) == msg.sender,
            "You don't own this NFT"
        );
        require(
            IERC721(_nftContract).isApprovedForAll(msg.sender, address(this)) ||
            IERC721(_nftContract).getApproved(_tokenId) == address(this),
            "Marketplace not approved to transfer NFT"
        );
        
        // Transfer NFT to marketplace for escrow
        IERC721(_nftContract).safeTransferFrom(msg.sender, address(this), _tokenId);
        
        // Create listing
        listings[nextListingId] = Listing({
            tokenId: _tokenId,
            nftContract: _nftContract,
            seller: msg.sender,
            price: _price,
            active: true,
            listedAt: block.timestamp
        });
        
        emit NFTListed(nextListingId, _nftContract, _tokenId, msg.sender, _price);
        nextListingId++;
    }
    
    /**
     * @dev Purchase an NFT from the marketplace
     * @param _listingId ID of the listing to purchase
     */
    function buyNFT(uint256 _listingId) external payable nonReentrant {
        Listing storage listing = listings[_listingId];
        
        require(listing.active, "Listing is not active");
        require(msg.value >= listing.price, "Insufficient payment");
        require(msg.sender != listing.seller, "Cannot buy your own NFT");
        
        // Calculate fees
        uint256 marketplaceFeeAmount = (listing.price * marketplaceFee) / BASIS_POINTS;
        uint256 sellerAmount = listing.price - marketplaceFeeAmount;
        
        // Mark as sold
        listing.active = false;
        
        // Transfer NFT to buyer
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            listing.tokenId
        );
        
        // Transfer payments
        payable(listing.seller).transfer(sellerAmount);
        payable(owner()).transfer(marketplaceFeeAmount);
        
        // Refund excess payment
        if (msg.value > listing.price) {
            payable(msg.sender).transfer(msg.value - listing.price);
        }
        
        emit NFTSold(_listingId, msg.sender, listing.seller, listing.price);
    }
    
    /**
     * @dev Cancel a listing and return NFT to seller
     * @param _listingId ID of the listing to cancel
     */
    function cancelListing(uint256 _listingId) external nonReentrant {
        Listing storage listing = listings[_listingId];
        
        require(listing.active, "Listing is not active");
        require(
            msg.sender == listing.seller || msg.sender == owner(),
            "Only seller or owner can cancel"
        );
        
        listing.active = false;
        
        // Return NFT to seller
        IERC721(listing.nftContract).safeTransferFrom(
            address(this),
            listing.seller,
            listing.tokenId
        );
        
        emit ListingCancelled(_listingId);
    }
    
    /**
     * @dev Create a governance proposal for marketplace decisions
     * @param _description Description of the proposal
     * @param _listingId Related listing ID (0 if not listing-specific)
     */
    function createProposal(
        string memory _description,
        uint256 _listingId
    ) external returns (uint256) {
        require(bytes(_description).length > 0, "Description cannot be empty");
        
        uint256 proposalId = nextProposalId;
        
        proposals[proposalId] = Proposal({
            description: _description,
            listingId: _listingId,
            proposer: msg.sender,
            createdAt: block.timestamp,
            votingEnds: block.timestamp + VOTING_DURATION,
            totalVotes: 0,
            revealedVotes: 0,
            supportVotes: 0,
            executed: false,
            passed: false
        });
        
        emit ProposalCreated(proposalId, _description, _listingId, msg.sender);
        
        nextProposalId++;
        return proposalId;
    }
    
    /**
     * @dev Commit a vote using commit-reveal scheme for privacy
     * @param _proposalId ID of the proposal
     * @param _commitHash Hash of (vote + salt + voter_address)
     */
    function commitVote(uint256 _proposalId, bytes32 _commitHash) external {
        Proposal storage proposal = proposals[_proposalId];
        
        require(block.timestamp < proposal.votingEnds, "Voting period ended");
        require(proposalVotes[_proposalId][msg.sender].timestamp == 0, "Already voted");
        require(_commitHash != bytes32(0), "Invalid commit hash");
        
        proposalVotes[_proposalId][msg.sender] = Vote({
            commitHash: _commitHash,
            revealed: false,
            support: false,
            timestamp: block.timestamp
        });
        
        proposal.totalVotes++;
        
        emit VoteCommitted(_proposalId, msg.sender, _commitHash);
    }
    
    /**
     * @dev Reveal a committed vote
     * @param _proposalId ID of the proposal
     * @param _support True for support, false for against
     * @param _salt Random salt used in commit phase
     */
    function revealVote(
        uint256 _proposalId,
        bool _support,
        uint256 _salt
    ) external {
        Proposal storage proposal = proposals[_proposalId];
        Vote storage vote = proposalVotes[_proposalId][msg.sender];
        
        require(block.timestamp >= proposal.votingEnds, "Voting still active");
        require(
            block.timestamp <= proposal.votingEnds + 2 days,
            "Reveal period ended"
        );
        require(vote.timestamp > 0, "No vote committed");
        require(!vote.revealed, "Vote already revealed");
        
        // Verify the reveal matches the commit
        bytes32 computedHash = keccak256(
            abi.encodePacked(_support, _salt, msg.sender)
        );
        require(computedHash == vote.commitHash, "Invalid reveal");
        
        vote.revealed = true;
        vote.support = _support;
        proposal.revealedVotes++;
        
        if (_support) {
            proposal.supportVotes++;
        }
        
        emit VoteRevealed(_proposalId, msg.sender, _support);
    }
    
    /**
     * @dev Execute a proposal after voting and reveal periods
     * @param _proposalId ID of the proposal to execute
     */
    function executeProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];
        
        require(
            block.timestamp > proposal.votingEnds + 2 days,
            "Reveal period not ended"
        );
        require(!proposal.executed, "Proposal already executed");
        require(
            proposal.revealedVotes >= MIN_VOTES_REQUIRED,
            "Insufficient revealed votes"
        );
        
        proposal.executed = true;
        
        // Simple majority required
        bool passed = proposal.supportVotes > (proposal.revealedVotes / 2);
        proposal.passed = passed;
        
        emit ProposalExecuted(_proposalId, passed);
        
        // Here you would implement the actual execution logic
        // For example, if it's a proposal to delist an NFT, remove it
        // This is placeholder for demonstration
    }
    
    // View functions
    function getListingDetails(uint256 _listingId)
        external
        view
        returns (
            uint256 tokenId,
            address nftContract,
            address seller,
            uint256 price,
            bool active,
            uint256 listedAt
        )
    {
        Listing storage listing = listings[_listingId];
        return (
            listing.tokenId,
            listing.nftContract,
            listing.seller,
            listing.price,
            listing.active,
            listing.listedAt
        );
    }
    
    function getProposalDetails(uint256 _proposalId)
        external
        view
        returns (
            string memory description,
            uint256 listingId,
            address proposer,
            uint256 createdAt,
            uint256 votingEnds,
            uint256 totalVotes,
            uint256 revealedVotes,
            uint256 supportVotes,
            bool executed,
            bool passed
        )
    {
        Proposal storage proposal = proposals[_proposalId];
        return (
            proposal.description,
            proposal.listingId,
            proposal.proposer,
            proposal.createdAt,
            proposal.votingEnds,
            proposal.totalVotes,
            proposal.revealedVotes,
            proposal.supportVotes,
            proposal.executed,
            proposal.passed
        );
    }
    
    function getVoteStatus(uint256 _proposalId, address _voter)
        external
        view
        returns (bool committed, bool revealed, bool support)
    {
        Vote storage vote = proposalVotes[_proposalId][_voter];
        return (
            vote.timestamp > 0,
            vote.revealed,
            vote.support
        );
    }
    
    // Emergency functions (only owner)
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    function updateMarketplaceFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee cannot exceed 10%"); // Max 10%
        require(_newFee >= 0, "Fee cannot be negative");
        
        uint256 oldFee = marketplaceFee;
        marketplaceFee = _newFee;
        
        emit MarketplaceFeeUpdated(oldFee, _newFee);
    }
}
