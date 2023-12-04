// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OrderBookDEX {
    IERC20 public hncToken;
    uint256 public tradingFee;
    address owner;
    mapping(address => uint256) public ethBalances;
    mapping(address => uint256) public hncBalances;
    mapping(address => uint256[]) public tradeHistory;

    enum OrderType { 
        Limit, 
        Market 
    }
    
    enum TradeType { 
        Buy, 
        Sell 
    }

    struct Order {
        OrderType orderType;
        TradeType tradeType;
        uint256 amount;
        uint256 price; // Price per HNC in ETH for limit orders
        address trader;
        bool isActive;
    }

    Order[] public orders;

    event OrderCreated(uint256 orderId, OrderType orderType, TradeType tradeType, uint256 amount, uint256 price, address trader);
    event TradeExecuted(address indexed buyer, address indexed seller, uint256 amount, uint256 price);
    event OrderCancelled(uint256 orderId);
    event Withdrawal(address indexed user, uint256 amount, string asset);

    constructor(address _hncTokenAddress) {
        hncToken = IERC20(_hncTokenAddress);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    function transferOwnership(address _owner) public onlyOwner {
        owner = _owner;
    }

    function setTradingFee(uint256 _fee) external onlyOwner {
        tradingFee = _fee;
    }

    function depositETH() external payable {
        require(msg.value != 0, "No value is given!");
        ethBalances[msg.sender] += msg.value;
    }

    function depositHNC(uint256 _amount) external {
        require(hncToken.transferFrom(msg.sender, address(this), _amount), "HNC transfer failed");
        hncBalances[msg.sender] += _amount;
    }

    function withdrawETH(uint256 _amountOfEther) external {
        require(ethBalances[msg.sender] >= _amountOfEther, "Insufficient balance");
        ethBalances[msg.sender] -= _amountOfEther;
        payable(msg.sender).transfer(_amountOfEther);

        emit Withdrawal(msg.sender, _amountOfEther, "ETH");
    }

    function withdrawHNC(uint256 _amount) external {
        require(hncBalances[msg.sender] >= _amount, "Insufficient balance");
        hncBalances[msg.sender] -= _amount;
        require(hncToken.transferFrom(address(this), msg.sender, _amount), "HNC transfer failed");

        emit Withdrawal(msg.sender, _amount, "HNC");
    }

    function handleLimitOrder(TradeType _tradeType, uint256 _amount, uint256 _price) private {
        if (_tradeType == TradeType.Buy) {
            require(ethBalances[msg.sender] >= _amount * _price, "Insufficient ETH balance");
            ethBalances[msg.sender] -= _amount * _price;
        } else {
            require(hncBalances[msg.sender] >= _amount, "Insufficient HNC balance");
            hncBalances[msg.sender] -= _amount;
        }

        Order memory newOrder = Order({
            orderType: OrderType.Limit,
            tradeType: _tradeType,
            amount: _amount,
            price: _price,
            trader: msg.sender,
            isActive: true
        });

        orders.push(newOrder);
        emit OrderCreated(orders.length - 1, OrderType.Limit, _tradeType, _amount, _price, msg.sender);
    }

    function handleMarketOrder(TradeType _tradeType, uint256 _amount) private {
        if (_tradeType == TradeType.Buy) {
            // Market Buy logic
            require(ethBalances[msg.sender] > 0, "Insufficient ETH balance");
            executeMarketBuy(_amount);
        } else {
            // Market Sell logic
            require(hncBalances[msg.sender] >= _amount, "Insufficient HNC balance");
            executeMarketSell(_amount);
        }
    }

    function executeMarketBuy(uint256 _amount) private {
        uint256 remainingAmount = _amount;
        uint256 totalCost = 0;

        for (uint256 i = 0; i < orders.length && remainingAmount > 0; i++) {
            Order storage order = orders[i];
            if (order.isActive && order.tradeType == TradeType.Sell) {
                uint256 tradeAmount = (remainingAmount > order.amount) ? order.amount : remainingAmount;
                uint256 tradeCost = tradeAmount * order.price;

                require(ethBalances[msg.sender] >= tradeCost, "Insufficient ETH for trade");
                ethBalances[msg.sender] -= tradeCost;
                ethBalances[order.trader] += tradeCost;

                order.amount -= tradeAmount;
                if (order.amount == 0) {
                    order.isActive = false;
                }

                hncBalances[msg.sender] += tradeAmount;
                remainingAmount -= tradeAmount;
                totalCost += tradeCost;
                emit TradeExecuted(msg.sender, order.trader, tradeAmount, order.price);
            }
        }

        require(remainingAmount == 0, "Not enough matching sell orders");
    }

    function executeMarketSell(uint256 _amount) private {
        uint256 remainingAmount = _amount;

        for (uint256 i = 0; i < orders.length && remainingAmount > 0; i++) {
            Order storage order = orders[i];
            if (order.isActive && order.tradeType == TradeType.Buy) {
                uint256 tradeAmount = (remainingAmount > order.amount) ? order.amount : remainingAmount;
                uint256 tradeCost = tradeAmount * order.price;

                require(ethBalances[order.trader] >= tradeCost, "Buyer has insufficient ETH");
                ethBalances[order.trader] -= tradeCost;
                ethBalances[msg.sender] += tradeCost;

                order.amount -= tradeAmount;
                if (order.amount == 0) {
                    order.isActive = false;
                }

                hncBalances[msg.sender] -= tradeAmount;
                remainingAmount -= tradeAmount;
                emit TradeExecuted(order.trader, msg.sender, tradeAmount, order.price);
            }
        }

        require(remainingAmount == 0, "Not enough matching buy orders");
    }

    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(order.trader == msg.sender, "Only the creator can cancel the order");
        require(order.isActive, "Order is already inactive");

        order.isActive = false;
        if (order.tradeType == TradeType.Buy) {
            ethBalances[msg.sender] += order.amount * order.price;
        } else {
            hncBalances[msg.sender] += order.amount;
        }

        emit OrderCancelled(orderId);
    }

    // Simplified trade execution logic
    function executeTrade(uint256 orderIndex, uint256 amount) external {
        require(orderIndex < orders.length, "Invalid order index");
        Order storage order = orders[orderIndex];
        require(order.isActive, "Order is inactive");
        require(amount > 0, "Amount must be greater than zero");

        if (order.tradeType == TradeType.Buy) {
            // Buyer (order creator) is buying HNC tokens, so the seller (msg.sender) must have enough HNC
            require(hncBalances[msg.sender] >= amount, "Seller has insufficient HNC tokens");
            uint256 cost = amount * order.price;

            // Check if the buyer (order creator) has enough ETH for the trade
            require(ethBalances[order.trader] >= cost, "Buyer has insufficient ETH");

            ethBalances[order.trader] -= cost;
            ethBalances[msg.sender] += cost;
            hncBalances[msg.sender] -= amount;
            hncBalances[order.trader] += amount;
        } else {
            // Seller (order creator) is selling HNC tokens, so the buyer (msg.sender) must have enough ETH
            uint256 cost = amount * order.price;
            require(ethBalances[msg.sender] >= cost, "Buyer has insufficient ETH");

            ethBalances[msg.sender] -= cost;
            ethBalances[order.trader] += cost;
            hncBalances[order.trader] -= amount;
            hncBalances[msg.sender] += amount;
        }

        order.amount -= amount;
        if (order.amount == 0) {
            order.isActive = false;
        }

        emit TradeExecuted(msg.sender, order.trader, amount, order.price);
    }
}