// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import USDC interface
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract DePinVPN {
    IERC20 public usdcToken

    struct VPNNode {
        address owner;
        string ipAddress; // Or use IPFS hash for privacy
        uint256 bandwidthAvailable; // in GB
        uint256 pricePerGB; // in USDC (6 decimals)
        uint256 totalEarned;
        uint256 reputation;
        bool isActive;
    }
    
    struct VPNConnection {
        address client;
        uint256 nodeId;
        uint256 startTime;
        uint256 bandwidthUsed;
        bool isActive;
        uint256 amountPaid; // in USDC
    }
    
    // State variables
    mapping(uint256 => VPNNode) public nodes;
    mapping(uint256 => VPNConnection) public connections;
    mapping(address => uint256) public providerBalances; // USDC balances
    
    uint256 public nodeCounter;
    uint256 public connectionCounter;
    uint256 public platformFee = 500; // 5% in basis points (500/10000 = 5%)
        
    // USDC uses 6 decimals, so we need to handle that
    uint256 public constant USDC_DECIMALS = 6;
    
    constructor(address _usdcTokenAddress) {
        usdcToken = IERC20(_usdcTokenAddress);
    }
    
    // Events for transparency
    event NodeRegistered(uint256 nodeId, address owner, uint256 pricePerGB);
    event ConnectionStarted(uint256 connectionId, address client, uint256 nodeId);
    event ConnectionStopped(uint256 connectionId, uint256 bandwidthUsed, uint256 payment);
    event PaymentReleased(uint256 nodeId, address provider, uint256 amount);
    event Withdrawn(address provider, uint256 amount);
}



// Provider Registration
function registerNode(string memory _ip, uint256 _bandwidth, uint256 _pricePerGB) external {
    require(_pricePerGB > 0, "Price must be positive");
    
    nodeCounter++;
    nodes[nodeCounter] = VPNNode({
        owner: msg.sender,
        ipAddress: _ip,
        bandwidthAvailable: _bandwidth,
        pricePerGB: _pricePerGB,
        totalEarned: 0,
        reputation: 100, // Start with base reputation
        isActive: true
    });
    
    emit NodeRegistered(nodeCounter, msg.sender, _pricePerGB);
}

// Client Connection and Payment
function startConnection(uint256 _nodeId, uint256 _expectedBandwidth) external {
    VPNNode storage node = nodes[_nodeId];
    require(node.isActive, "Node not active");
    
    uint256 expectedCost = _expectedBandwidth * node.pricePerGB;

    // Transfer USDC from client to contract
    require(
        usdcToken.transferFrom(msg.sender, address(this), expectedCost),
        "USDC transfer failed"
    );

    connectionCounter++;
    connections[connectionCounter] = VPNConnection({
        client: msg.sender,
        nodeId: _nodeId,
        startTime: block.timestamp,
        bandwidthUsed: 0,
        isActive: true,
        amountPaid: expectedCost
    });
    
    emit ConnectionStarted(connectionCounter, msg.sender, _nodeId);
}

// Connection Termination & Payment
function stopConnection(uint256 _connectionId, uint256 _actualBandwidthUsed) external {
    VPNConnection storage connection = connections[_connectionId];
    VPNNode storage node = nodes[connection.nodeId];
    
    require(connection.isActive, "Connection not active");
    require(msg.sender == connection.client || msg.sender == node.owner, "Not authorized");
    
    connection.isActive = false;
    connection.bandwidthUsed = _actualBandwidthUsed;
    
    // Calculate actual cost in USDC
    uint256 actualCost = _actualBandwidthUsed * node.pricePerGB;
    uint256 providerShare = actualCost * (10000 - platformFee) / 10000;
    unit256 platformShare = actualCost - providerShare
    
    // Update provider earnings
    node.totalEarned += providerShare;
    providerBalances[node.owner] += providerShare;
    
    // Refund unused USDC
    uint256 refund = connection.amountPaid - actualCost;
    if (refund > 0) {
        require(
            usdcToken.transfer(connection.client, refund),
            "Refund transfer failed"
        );
    }
    
    emit ConnectionStopped(_connectionId, _actualBandwidthUsed, providerShare);
}


// Withdraw USDC earnings for Providers
function withdrawEarnings() external {
    uint256 amount = providerBalances[msg.sender];
    require(amount > 0, "No earnings to withdraw");
    
    providerBalances[msg.sender] = 0;
    
    require(
        usdcToken.transfer(msg.sender, amount),
        "Withdrawal failed"
    );
    
    emit Withdrawn(msg.sender, amount);
}