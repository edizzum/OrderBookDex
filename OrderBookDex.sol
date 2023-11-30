// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OrderBookDEX {
    IERC20 public hncToken;
    mapping(address => uint256) public ethBalances;
    mapping(address => uint256) public hncBalances;

    enum OrderType { Limit, Market }
    enum TradeType { Buy, Sell }

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
    event TradeExecuted(uint256 orderId, uint256 amount, uint256 price, address trader);
    event OrderCancelled(uint256 orderId);
    event Withdrawal(address indexed user, uint256 amount, string asset);

    constructor(address _hncTokenAddress) {
        hncToken = IERC20(_hncTokenAddress);
    }

    function depositETH() external payable {
        require(msg.value != 0, "No value is given!");
        ethBalances[msg.sender] += msg.value;
    }

    function depositHNC(uint256 amount) external {
        require(hncToken.transferFrom(msg.sender, address(this), amount), "HNC transfer failed");
        hncBalances[msg.sender] += amount;
    }

    function createOrder(OrderType orderType, TradeType tradeType, uint256 amount, uint256 price) external {
        if (tradeType == TradeType.Buy) {
            require(ethBalances[msg.sender] >= amount * price, "Insufficient ETH balance");
            ethBalances[msg.sender] -= amount * price;
        } else {
            require(hncBalances[msg.sender] >= amount, "Insufficient HNC balance");
            hncBalances[msg.sender] -= amount;
        }

        Order memory newOrder = Order({
            orderType: orderType,
            tradeType: tradeType,
            amount: amount,
            price: price,
            trader: msg.sender,
            isActive: true
        });

        orders.push(newOrder);
        emit OrderCreated(orders.length - 1, orderType, tradeType, amount, price, msg.sender);
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

    function withdrawETH(uint256 amount) external {
        require(ethBalances[msg.sender] >= amount, "Insufficient balance");
        ethBalances[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);

        emit Withdrawal(msg.sender, amount, "ETH");
    }

    function withdrawHNC(uint256 amount) external {
        require(hncBalances[msg.sender] >= amount, "Insufficient balance");
        hncBalances[msg.sender] -= amount;
        require(hncToken.transfer(msg.sender, amount), "HNC transfer failed");

        emit Withdrawal(msg.sender, amount, "HNC");
    }

    // Simplified trade execution logic
    function executeTrade(uint256 orderId) external {
        // Add logic for executing trades
        // This should include matching orders, handling prices, etc.
        // For now, we'll just emit an event
        Order storage order = orders[orderId];
        emit TradeExecuted(orderId, order.amount, order.price, order.trader);
    }

    // Add order matching logic
    // This function should match buy and sell orders based on