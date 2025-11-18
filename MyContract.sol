// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DePinVPN is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public usdcToken;
    uint256 public platformBalance; // accumulated platform fees (USDC smallest unit)
    uint256 public platformFeeBp = 500; // platform fee in basis points (default 500 = 5%)
    uint256 public constant MAX_PLATFORM_FEE_BP = 1000; // max 10%
    uint256 public constant USDC_DECIMALS = 6; // USDC has 6 decimals

    struct VPNNode {
        address owner; // provider address
        string ipAddress; // string (privacy note: plain IP stored on-chain. Consider encryption for privacy)
        uint256 bandwidthAvailable; // available bandwith (units in GB  or other units)
        uint256 pricePerGB; // price expressed in USDC, smallest unit (6 decimals)
        uint256 totalEarned;
        uint256 reputation;
        bool isActive;
    }
    
    struct VPNConnection {
        address client; // client address
        uint256 nodeId;
        uint256 startTime;
        uint256 endTime;
        uint256 expectedBandwidth;
        uint256 actualBandwidthUsed;
        bool isActive;
        bool finalized;
        uint256 amountPaid;
    }
    
    mapping(uint256 => VPNNode) public nodes;
    mapping(uint256 => VPNConnection) public connections;
    mapping(address => uint256) public providerBalances;
    
    uint256 public nodeCounter;
    uint256 public connectionCounter;

    // Events
    event NodeRegistered(uint256 indexed nodeId, address indexed owner, uint256 pricePerGB);
    event NodeUpdated(uint256 indexed nodeId, address indexed owner);
    event NodeDeactivated(uint256 indexed nodeId, address indexed owner);
    event ConnectionStarted(uint256 indexed connectionId, address indexed client, uint256 indexed nodeId, uint256 expectedBandwidth, uint256 amountPaid);
    event ConnectionStopped(uint256 indexed connectionId, uint256 actualBandwidthUsed, uint256 providerShare, uint256 platformShare);
    event ConnectionResolved(uint256 indexed connectionId, uint256 actualBandwidthUsed, address indexed resolver);
    event Withdrawn(address indexed provider, uint256 amount);
    event PlatformWithdrawn(address indexed to, uint256 amount);
    event PlatformFeeUpdated(uint256 newFeeBp);

    constructor(address _usdc) {
        require(_usdc != address(0), "Invalid USDC address");
        usdcToken = IERC20(_usdc);
    }

    // ----- Node management -----

    // Providers register their VPN nodes
    function registerNode(string calldata _ip, uint256 _bandwidth, uint256 _pricePerGB) external {
        require(_pricePerGB > 0, "Price must be positive");
        require(_bandwidth > 0, "Bandwidth must be positive");

        nodeCounter++;
        nodes[nodeCounter] = VPNNode({
            owner: msg.sender,
            ipAddress: _ip,
            bandwidthAvailable: _bandwidth,
            pricePerGB: _pricePerGB,
            totalEarned: 0,
            reputation: 100,
            isActive: true
        });
        
        emit NodeRegistered(nodeCounter, msg.sender, _pricePerGB);
    }

    // Providers can update their node details
    function updateNodePrice(uint256 _nodeId, uint256 _newPricePerGB) external {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner != address(0), "Node not found");
        require(msg.sender == node.owner, "Not node owner");
        require(_newPricePerGB > 0, "Price must be > 0");
        node.pricePerGB = _newPricePerGB;
        emit NodeUpdated(_nodeId, msg.sender);
    }

    // Providers can activate/deactivate their nodes
    function setNodeActive(uint256 _nodeId, bool _active) external {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner != address(0), "Node not found");
        require(msg.sender == node.owner, "Not node owner");
        node.isActive = _active;
        if (_active) {
            emit NodeUpdated(_nodeId, msg.sender);
        } else {
            emit NodeDeactivated(_nodeId, msg.sender);
        }
    }

    // ----- Connection lifecycle -----

    // Client pays estimated cost up-front; bandwidth is reserved at start
    function startConnection(uint256 _nodeId, uint256 _expectedBandwidth) external nonReentrant {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner != address(0), "Node not found");
        require(node.isActive, "Node not active");
        require(_expectedBandwidth > 0, "Expected bandwidth must be positive");
        require(node.bandwidthAvailable >= _expectedBandwidth, "Insufficient bandwidth");
        
        uint256 expectedCost = _expectedBandwidth * node.pricePerGB;
        require(expectedCost > 0, "Expected cost must be positive");

        // Transfer USDC from client to contract (uses SafeERC20)
        usdcToken.safeTransferFrom(msg.sender, address(this), expectedCost);

        // Reserve bandwidth immediately (checks-effects-interactions)
        node.bandwidthAvailable -= _expectedBandwidth;

        connectionCounter++;
        connections[connectionCounter] = VPNConnection({
            client: msg.sender,
            nodeId: _nodeId,
            startTime: block.timestamp,
            endTime: 0,
            expectedBandwidth: _expectedBandwidth,
            actualBandwidthUsed: 0,
            isActive: true,
            finalized: false,
            amountPaid: expectedCost
        });
        
        emit ConnectionStarted(connectionCounter, msg.sender, _nodeId, _expectedBandwidth, expectedCost);
    }

    // Stop connection and report actual usage. Either client or node owner can call.
    // This function finalizes the connection, calculates shares, refunds unused, and credits provider balance.
    function stopConnection(uint256 _connectionId, uint256 _actualBandwidthUsed) external nonReentrant {
        VPNConnection storage conn = connections[_connectionId];
        require(conn.isActive, "Connection not active");
        require(!conn.finalized, "Already finalized");

        VPNNode storage node = nodes[conn.nodeId];
        require(node.owner != address(0), "Node not found");
        require(msg.sender == conn.client || msg.sender == node.owner, "Not authorized");

        // actual used should not exceed reserved expected bandwidth by design
        require(_actualBandwidthUsed <= conn.expectedBandwidth, "Actual bandwidth exceeds paid amount");
        
        // Effects
        conn.isActive = false;
        conn.endTime = block.timestamp;
        conn.actualBandwidthUsed = _actualBandwidthUsed;
        conn.finalized = true;

        // Calculate actual cost (in USDC)
        uint256 actualCost = _actualBandwidthUsed * node.pricePerGB;
        if (actualCost > conn.amountPaid) {
            actualCost = conn.amountPaid; // Cap to amount paid
        }

        uint256 providerShare = (actualCost * (10000 - platformFeeBp)) / 10000;
        uint256 platformShare = actualCost - providerShare;

        // Update balances
        node.totalEarned += providerShare;
        providerBalances[node.owner] += providerShare;
        platformBalance += platformShare;

        // If reserved bandwidth > actual used, release the remainder back to node availability
        uint256 released = 0;
        if (conn.expectedBandwidth >= _actualBandwidthUsed) {
            released = conn.expectedBandwidth - _actualBandwidthUsed;
            node.bandwidthAvailable += released;
        }

        // Refund unused paid amount to client (checks-effects-interactions done)
        uint256 refund = 0;
        if (conn.amountPaid > actualCost) {
            refund = conn.amountPaid - actualCost;
            if (refund > 0) {
                usdcToken.safeTransfer(conn.client, refund);
            }
        }
        
        emit ConnectionStopped(_connectionId, _actualBandwidthUsed, providerShare, platformShare);
    }

    // Owner (admin) can resolve disputes by setting actual usage and finalizing a connection.
    function resolveConnection(uint256 _connectionId, uint256 _actualBandwidthUsed) external onlyOwner nonReentrant {
        VPNConnection storage conn = connections[_connectionId];
        require(conn.isActive, "Connection not active");
        require(!conn.finalized, "Already finalized");

        VPNNode storage node = nodes[conn.nodeId];
        require(node.owner != address(0), "Node not found");
        require(_actualBandwidthUsed <= conn.expectedBandwidth, "Actual > expected");

        conn.isActive = false;
        conn.endTime = block.timestamp;
        conn.actualBandwidthUsed = _actualBandwidthUsed;
        conn.finalized = true;

        uint256 actualCost = _actualBandwidthUsed * node.pricePerGB;
        if (actualCost > conn.amountPaid) actualCost = conn.amountPaid;

        uint256 providerShare = (actualCost * (10000 - platformFeeBp)) / 10000;
        uint256 platformShare = actualCost - providerShare;

        node.totalEarned += providerShare;
        providerBalances[node.owner] += providerShare;
        platformBalance += platformShare;

        if (conn.expectedBandwidth > _actualBandwidthUsed) {
            uint256 released = conn.expectedBandwidth - _actualBandwidthUsed;
            node.bandwidthAvailable += released;
        }

        if (conn.amountPaid > actualCost) {
            uint256 refund = conn.amountPaid - actualCost;
            if (refund > 0) {
                usdcToken.safeTransfer(conn.client, refund);
            }
        }

        emit ConnectionResolved(_connectionId, _actualBandwidthUsed, msg.sender);
        emit ConnectionStopped(_connectionId, _actualBandwidthUsed, providerShare, platformShare);
    }

    // ----- Withdrawals -----

    function withdrawEarnings() external nonReentrant {
        uint256 amount = providerBalances[msg.sender];
        require(amount > 0, "No earnings to withdraw");
        providerBalances[msg.sender] = 0;
        usdcToken.safeTransfer(msg.sender, amount);        
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawPlatformFees(address _to) external onlyOwner nonReentrant {
        require(_to != address(0), "Invalid address");
        uint256 amount = platformBalance;
        require(amount > 0, "No platform balance");
        platformBalance = 0;
        usdcToken.safeTransfer(_to, amount);
        emit PlatformWithdrawn(_to, amount);
    }

    // ----- Admin Functions -----
    
    function setPlatformFee(uint256 _feeBp) external onlyOwner {
        require(_feeBp <= MAX_PLATFORM_FEE_BP, "Fee too high");
        platformFeeBp = _feeBp;
        emit PlatformFeeUpdated(_feeBp);
    }

    // ----- Views / Helpers -----

    function getNode(uint256 _nodeId) external view returns (VPNNode memory) {
        return nodes[_nodeId];
    }

    function getConnection(uint256 _connectionId) external view returns (VPNConnection memory) {
        return connections[_connectionId];
    }

}

