// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DePinVPN is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;


    IERC20 public usdcToken;


    struct VPNNode {
        address owner; 
        string ipAddress;       // IP stored on-chain. For future reference, consider encryption for privacy
        uint16 port;           
        uint256 pricePerMinute; // price expressed in USDC (smallest unit) per minute
        uint256 totalEarned;
        uint256 reputation;
        bool isActive;
        uint256 maxConcurrentUsers;
        uint256 currentUsers;
    }
    
    struct VPNConnection {
        address client;
        uint256 nodeId;
        uint256 startTime;
        uint256 endTime;
        uint256 minutesUsed; // Simple minute tracking
        bool isActive;
        uint256 amountPaid;
    }
    

    // State variables
    mapping(uint256 => VPNNode) public nodes;
    mapping(uint256 => VPNConnection) public connections;
    mapping(address => uint256) public providerBalances;
    mapping(address => uint256) public clientBalances;
    
    
    uint256 public nodeCounter;
    uint256 public connectionCounter;
    uint256 public platformFeeBp = 500; // 5% platform fee
    uint256 public constant MAX_PLATFORM_FEE_BP = 1000; // Max 10%

    uint256 public platformBalance;

    // Events
    event NodeRegistered(uint256 indexed nodeId, address indexed owner, string ipAddress, uint16 port, uint256 pricePerMinute);
    
    event NodePriceUpdated(uint256 indexed nodeId, uint256 newPricePerMinute);
    event NodeIPUpdated(uint256 indexed nodeId, string newIp);
    event NodePortUpdated(uint256 indexed nodeId, uint16 newPort);

    event NodeDeactivated(uint256 indexed nodeId);
    event NodeReactivated(uint256 indexed nodeId);
    
    event ConnectionStarted(uint256 indexed connectionId, address indexed client, uint256 indexed nodeId, uint256 amountPaid);
    event ConnectionStopped(uint256 indexed connectionId, uint256 minutesUsed, uint256 totalCost, uint256 refundAmount);
    
    event Withdrawn(address indexed to, uint256 amount);
    event PlatformFeeUpdated(uint256 newFeeBp);
    event PlatformFeesWithdrawn(address indexed to, uint256 amount);


    constructor(address _usdc) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        usdcToken = IERC20(_usdc);
    }
    

    // ========== NODE MANAGEMENT ==========

    function registerNode(
        string calldata _ipAddress,
        uint16 _port,
        uint256 _maxConcurrentUsers,
        uint256 _pricePerMinute
    ) external {
        require(_maxConcurrentUsers > 0, "Max users must be positive");
        require(_port > 0 && _port <= 65535, "Invalid port");
        require(bytes(_ipAddress).length > 0, "IP address required");
        require(_pricePerMinute > 0, "Price per minute must be positive");

        nodeCounter++;
        nodes[nodeCounter] = VPNNode({
            owner: msg.sender,
            ipAddress: _ipAddress,
            port: _port,
            pricePerMinute: _pricePerMinute,
            totalEarned: 0,
            reputation: 100,
            isActive: true,
            maxConcurrentUsers: _maxConcurrentUsers,
            currentUsers: 0
        });

        emit NodeRegistered(nodeCounter, msg.sender, _ipAddress, _port, _pricePerMinute);
    }

    function updateNodeIP(uint256 _nodeId, string calldata _newIP) external {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner == msg.sender, "Not node owner");
        require(bytes(_newIP).length > 0, "IP address required");
        node.ipAddress = _newIP;
        emit NodeIPUpdated(_nodeId, _newIP);
    }

    function updateNodePort(uint256 _nodeId, uint16 _newPort) external {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner == msg.sender, "Not node owner");
        require(_newPort > 0 && _newPort <= 65535, "Invalid port");
        require(node.currentUsers == 0, "Cannot change port with active connections");  
        node.port = _newPort;
        emit NodePortUpdated(_nodeId, _newPort);
    }

    function updateNodePrice(uint256 _nodeId, uint256 _newPricePerMinute) external {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner == msg.sender, "Not node owner");
        require(_newPricePerMinute > 0, "Price must be positive");
        node.pricePerMinute = _newPricePerMinute;
        emit NodePriceUpdated(_nodeId, _newPricePerMinute);
    }

    function deactivateNode(uint256 _nodeId) external {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner == msg.sender, "Not node owner");
        require(node.isActive, "Node already inactive");
        node.isActive = false;
        emit NodeDeactivated(_nodeId);
    }

    function reactivateNode(uint256 _nodeId) external {
        VPNNode storage node = nodes[_nodeId];
        require(node.owner == msg.sender, "Not node owner");
        require(!node.isActive, "Node already active");
        require(bytes(node.ipAddress).length > 0, "Node IP not set");
        node.isActive = true;
        emit NodeReactivated(_nodeId);
    }


    // ========== SIMPLE PAYMENT SYSTEM ==========

    function startConnection(uint256 _nodeId) external nonReentrant {
        VPNNode storage node = nodes[_nodeId];
        require(node.isActive, "Node not active");
        require(node.currentUsers < node.maxConcurrentUsers, "Node at capacity");
        require(bytes(node.ipAddress).length > 0, "Node IP not set");
        require(node.port > 0, "Node port not set");

        // Pay for 1 minute upfront (minimum charge)
        uint256 upfrontPayment = node.pricePerMinute;
        require(upfrontPayment > 0, "Node price not set");

        // Take payment for 1 minute
        usdcToken.safeTransferFrom(msg.sender, address(this), upfrontPayment);

        // Reserve connection slot
        node.currentUsers++;

        connectionCounter++;
        connections[connectionCounter] = VPNConnection({
            client: msg.sender,
            nodeId: _nodeId,
            startTime: block.timestamp,
            endTime: 0,
            minutesUsed: 0,
            isActive: true,
            amountPaid: upfrontPayment
        });
        
        emit ConnectionStarted(connectionCounter, msg.sender, _nodeId, upfrontPayment);
    }

    function stopConnection(uint256 _connectionId) external nonReentrant {
        VPNConnection storage conn = connections[_connectionId];
        require(conn.isActive, "Connection not active");
        require(msg.sender == conn.client, "Only client can stop connection"); 

        VPNNode storage node = nodes[conn.nodeId];
        require(node.owner != address(0), "Node not found");

        // Calculate minutes used (rounded up)
        uint256 endTime = block.timestamp;
        uint256 secondsUsed = endTime - conn.startTime;
        uint256 minutesUsed = (secondsUsed + 59) / 60; // Round up to nearest minute
        
        // Update connection
        conn.isActive = false;
        conn.endTime = endTime;
        conn.minutesUsed = minutesUsed;

        // Release connection slot
        node.currentUsers--;

        // Process payment based on actual minutes used
        _processSimplePayment(_connectionId, conn, node, minutesUsed);
    }

 function _processSimplePayment(
        uint256 _connectionId,
        VPNConnection storage conn,
        VPNNode storage node,
        uint256 _minutesUsed
    ) internal {
        uint256 totalCost = _minutesUsed * node.pricePerMinute;
        uint256 amountPaid = conn.amountPaid;

        // If used more minutes than paid for, take additional payment
        if (totalCost > amountPaid) {
            uint256 additionalPayment = totalCost - amountPaid;
            usdcToken.safeTransferFrom(conn.client, address(this), additionalPayment);
            amountPaid = totalCost;
        }

        uint256 refundAmount = 0;
        // If user overpaid, record refund to client balances
        if (amountPaid > totalCost) {
            refundAmount = amountPaid - totalCost;
            clientBalances[conn.client] += refundAmount;
            amountPaid = totalCost;
        }

        // Calculate distribution based on the actual cost
        uint256 providerShare = (totalCost * (10000 - platformFeeBp)) / 10000;
        uint256 platformShare = totalCost - providerShare;

        // Update balances
        node.totalEarned += providerShare;
        providerBalances[node.owner] += providerShare;
        platformBalance += platformShare;

        // Clear the paid amount on the connection (funds are allocated)
        conn.amountPaid = 0;

        emit ConnectionStopped(_connectionId, _minutesUsed, totalCost, refundAmount);
    }


 // ========== VIEW FUNCTIONS ==========

    function getAvailableNodes() external view returns (uint256[] memory) {
        uint256 availableCount = 0;
        
        for (uint256 i = 1; i <= nodeCounter; i++) {
            if (nodes[i].isActive && 
                nodes[i].currentUsers < nodes[i].maxConcurrentUsers &&
                bytes(nodes[i].ipAddress).length > 0 &&
                nodes[i].port > 0) {
                availableCount++;
            }
        }

        uint256[] memory availableNodes = new uint256[](availableCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= nodeCounter; i++) {
            if (nodes[i].isActive && 
                nodes[i].currentUsers < nodes[i].maxConcurrentUsers &&
                bytes(nodes[i].ipAddress).length > 0 &&
                nodes[i].port > 0) {
                availableNodes[index] = i;
                index++;
            }
        }
        return availableNodes;
    }

    function getNodeDetails(uint256 _nodeId) external view returns (
        address owner,
        string memory ipAddress,
        uint16 port,
        uint256 pricePerMinute,
        uint256 currentUsers,
        uint256 maxConcurrentUsers,
        bool isActive,
        uint256 totalEarned,
        uint256 reputation
    ) {
        VPNNode storage node = nodes[_nodeId];
        return (
            node.owner,
            node.ipAddress,
            node.port,
            node.pricePerMinute,
            node.currentUsers,
            node.maxConcurrentUsers,
            node.isActive,            
            node.totalEarned,
            node.reputation
        );
    }

    function getConnectionCost(uint256 _nodeId, uint256 _minutes) external view returns (uint256) {
        return nodes[_nodeId].pricePerMinute * _minutes;
    }

    function getConnectionUsage(uint256 _connectionId) external view returns (
        uint256 startTime,
        uint256 minutesUsed,
        uint256 amountPaid,
        bool isActive
    ) {
        VPNConnection storage conn = connections[_connectionId];
        uint256 currentMinutes = 0;
        if (conn.isActive) {
            currentMinutes = (block.timestamp - conn.startTime + 59) / 60;
        } else {
            currentMinutes = conn.minutesUsed;
        }
        
        return (
            conn.startTime,
            currentMinutes,
            conn.amountPaid,
            conn.isActive
        );
    }

    // ========== WITHDRAWAL FUNCTIONS ==========

    function withdrawEarnings() external nonReentrant {
        uint256 amount = providerBalances[msg.sender];
        require(amount > 0, "No earnings to withdraw");
        providerBalances[msg.sender] = 0;
        usdcToken.safeTransfer(msg.sender, amount);        
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawClientBalance() external nonReentrant {
        uint256 amount = clientBalances[msg.sender];
        require(amount > 0, "No balance to withdraw");
        clientBalances[msg.sender] = 0;
        usdcToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawPlatformFees(address _to) external onlyOwner nonReentrant {
        uint256 amount = platformBalance;
        require(amount > 0, "No platform balance");
        platformBalance = 0;
        usdcToken.safeTransfer(_to, amount);
        emit PlatformFeesWithdrawn(_to, amount);
    }

    // ========== ADMIN FUNCTIONS ==========
    
    function setPlatformFee(uint256 _feeBp) external onlyOwner {
        require(_feeBp <= MAX_PLATFORM_FEE_BP, "Fee too high"); // Max 10%
        platformFeeBp = _feeBp;
        emit PlatformFeeUpdated(_feeBp);
    }

    function adminDeactivateNode(uint256 _nodeId) external onlyOwner {
        VPNNode storage node = nodes[_nodeId];
        require(node.isActive, "Node already inactive");        
        node.isActive = false;
        emit NodeDeactivated(_nodeId);
    }