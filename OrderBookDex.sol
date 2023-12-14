// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract OrderBookDEX is ReentrancyGuard {

    IERC20 public hncToken; 
    uint256 public tradingFee;
    address public owner;
    uint256 nextOrderId = 1;
    mapping(address => uint256) public ethBalances;
    mapping(address => uint256) public hncBalances;

    enum OrderType { Limit, Market }
    enum TradeType { Buy, Sell }

    struct Order {
        OrderType orderType;
        TradeType tradeType;
        uint256 orderId;
        uint256 amount;
        uint256 price; // Price per HNC in ETH for limit orders
        address trader;
        bool isActive;
    }

    Order[] public activeOrders;

    event OrderCreated(uint256 orderId, OrderType orderType, TradeType tradeType, uint256 amount, uint256 price, address trader);
    event LimitTradeExecuted(address indexed buyer, address indexed seller, uint256 amount, uint256 price);
    event MarketTradeExecuted(address indexed buyer, address indexed seller, uint256 amount, uint256 price);
    event OrderCancelled(Order orderId);
    event Withdrawal(address indexed user, uint256 amount, string asset);

    constructor(address _hncTokenAddress) {
        hncToken = IERC20(_hncTokenAddress);
        owner = msg.sender;
    }

    //////////////////// Owner Functions ////////////////////

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    function transferOwnership(address _owner) public onlyOwner {
        owner = _owner;
    }

    function setTradingFee(uint256 _fee) external onlyOwner {
        tradingFee = _fee; // _fee = 100 => 100/10000 => %1
    }

    //////////////////// Deposit - Withdraw Functions ////////////////////

    function depositETH() external payable nonReentrant {
        require(msg.value != 0, "No value is given!");
        ethBalances[msg.sender] += msg.value;
    }

    function depositHNC(uint256 _amount) external nonReentrant {
        require(hncToken.transferFrom(msg.sender, address(this), _amount), "HNC transfer failed");
        hncBalances[msg.sender] += _amount;
    }

    function withdrawETH(uint256 _amountOfEther) external nonReentrant {
        require(ethBalances[msg.sender] >= _amountOfEther, "Insufficient balance");
        ethBalances[msg.sender] -= _amountOfEther;
        payable(msg.sender).transfer(_amountOfEther);
        emit Withdrawal(msg.sender, _amountOfEther, "ETH");
    }

    function withdrawHNC(uint256 _amount) external nonReentrant {
        require(hncBalances[msg.sender] >= _amount, "Insufficient balance");
        hncBalances[msg.sender] -= _amount;
        require(hncToken.transfer(msg.sender, _amount), "HNC transfer failed");
        emit Withdrawal(msg.sender, _amount, "HNC");
    }

    function withdrawETHForOwner(uint256 _amountOfEther) external onlyOwner nonReentrant {
        require(ethBalances[owner] >= _amountOfEther, "Insufficient balance");
        ethBalances[owner] -= _amountOfEther;
        payable(owner).transfer(_amountOfEther);
        emit Withdrawal(owner, _amountOfEther, "ETH");
    }

    //////////////////// Limit Order Functions ////////////////////1800

    function createLimitOrder(TradeType _tradeType, uint256 _amount, uint256 _price) external {
        if (_tradeType == TradeType.Buy) {
            require(_amount > 0, "Amount must be greater than 0");
            require(_price > 0, "ETH price must be greater than 0");
            require(ethBalances[msg.sender] >= (_amount * _price)/10**18, "Insufficient ETH balance");
            uint256 tradeCost = (_amount * _price)/10**18;
            ethBalances[msg.sender] -= tradeCost;
        } else {
            require(_amount > 0, "Amount must be greater than 0");
            require(_price > 0, "ETH price must be greater than 0");
            require(hncBalances[msg.sender] >= _amount, "Insufficient HNC balance");
            hncBalances[msg.sender] -= _amount;
        }

        uint256 newOrderId = nextOrderId;
        nextOrderId += 1;
        Order memory newOrder = Order({
            orderType: OrderType.Limit,
            tradeType: _tradeType,
            orderId: newOrderId,
            amount: _amount,
            price: _price,
            trader: msg.sender,
            isActive: true
        });

        if (!matchOrder(newOrder)) {
            activeOrders.push(newOrder);
            emit OrderCreated(newOrder.orderId, OrderType.Limit, _tradeType, _amount, _price, msg.sender);
        }
    }

    function matchOrder(Order memory newOrder) internal returns (bool) {
        for (uint256 i = 0; i < activeOrders.length; i++) {
            Order storage existingOrder = activeOrders[i];
            if (existingOrder.tradeType != newOrder.tradeType && existingOrder.price == newOrder.price) {
                executeTrade(existingOrder, newOrder);
                return true;
            }
        }
        return false;
    }

    function executeTrade(Order storage matchedOrder, Order memory newOrder) internal {
        uint256 tradeAmount = matchedOrder.amount < newOrder.amount ? matchedOrder.amount : newOrder.amount;
        uint256 tradeCost = (tradeAmount * newOrder.price)/10**18;
        uint256 feeAmount = (tradeCost * tradingFee) / 10000;

        if (newOrder.tradeType == TradeType.Buy) {
            ethBalances[owner] += feeAmount;
            ethBalances[matchedOrder.trader] += tradeCost - feeAmount;
            hncBalances[newOrder.trader] += tradeAmount;
        } else {
            ethBalances[owner] += feeAmount;
            ethBalances[newOrder.trader] += tradeCost - feeAmount;
            ethBalances[matchedOrder.trader] -= tradeCost;
            hncBalances[matchedOrder.trader] += tradeAmount;
        }

        matchedOrder.amount -= tradeAmount;
        newOrder.amount -= tradeAmount;

        // Remove or update the matched order
        if (matchedOrder.amount == 0) {
            removeOrderFromArray(matchedOrder);
        } else {
            matchedOrder.isActive = true;
        }

        // Remove or update the new order
        if (newOrder.amount == 0) {
            removeOrderFromArray(newOrder);
        } else {
            // Add the partially fulfilled new order to activeOrders
            newOrder.isActive = true;
            activeOrders.push(newOrder);
        }

        emit LimitTradeExecuted(newOrder.trader, matchedOrder.trader, tradeAmount, newOrder.price);
    }

    //////////////////// Market Order Functions ////////////////////

    function handleMarketOrder(TradeType _tradeType, uint256 _amount) external {
        if (_tradeType == TradeType.Buy) {
            require(ethBalances[msg.sender] > 0, "Insufficient ETH balance");
            executeMarketBuy(_amount);
        } else {
            require(hncBalances[msg.sender] >= _amount, "Insufficient HNC balance");
            executeMarketSell(_amount);
        }
    }

    function executeMarketBuy(uint256 _amount) private {
        uint256 remainingAmount = _amount;
        uint256 totalCost = 0;

        while (remainingAmount > 0) {
            uint256 closestPriceDifference = type(uint256).max;
            uint256 closestOrderIndex = type(uint256).max;
            uint256 tradeAmount;
            uint256 tradeCost;

            // Find the closest sell order in terms of price
            for (uint256 i = 0; i < activeOrders.length; i++) {
                Order storage order = activeOrders[i];
                if (order.tradeType == TradeType.Sell && order.amount > 0) {
                    uint256 priceDifference = order.price > ethBalances[msg.sender] ? order.price - ethBalances[msg.sender] : ethBalances[msg.sender] - order.price;
                    if (priceDifference < closestPriceDifference) {
                        closestPriceDifference = priceDifference;
                        closestOrderIndex = i;
                    }
                }
            }

            require(closestOrderIndex != type(uint256).max, "No matching sell orders found");

            Order storage closestOrder = activeOrders[closestOrderIndex];
            tradeAmount = (remainingAmount > closestOrder.amount) ? closestOrder.amount : remainingAmount;
            tradeCost = (tradeAmount * closestOrder.price)/10**18;

            require(ethBalances[msg.sender] >= tradeCost, "Insufficient ETH for trade");

            uint256 feeAmount = (tradeCost * tradingFee) / 10000;
            ethBalances[msg.sender] -= tradeCost;
            ethBalances[closestOrder.trader] += tradeCost - feeAmount;
            ethBalances[owner] += feeAmount;

            closestOrder.amount -= tradeAmount;
            hncBalances[msg.sender] += tradeAmount;
            remainingAmount -= tradeAmount;
            totalCost += tradeCost;

            emit MarketTradeExecuted(msg.sender, closestOrder.trader, tradeAmount, closestOrder.price);

            if (closestOrder.amount == 0) {
                removeOrderFromArray(closestOrder);
            }
        }
    }

    function executeMarketSell(uint256 _amount) private {
        uint256 remainingAmount = _amount;

        while (remainingAmount > 0) {
            uint256 closestPriceDifference = type(uint256).max;
            uint256 closestOrderIndex = type(uint256).max;
            uint256 tradeAmount;
            uint256 tradeCost;

            // Find the closest buy order in terms of price
            for (uint256 i = 0; i < activeOrders.length; i++) {
                Order storage order = activeOrders[i];
                if (order.tradeType == TradeType.Buy && order.amount > 0) {
                    uint256 priceDifference = order.price > ethBalances[order.trader] ? order.price - ethBalances[order.trader] : ethBalances[order.trader] - order.price;
                    if (priceDifference < closestPriceDifference) {
                        closestPriceDifference = priceDifference;
                        closestOrderIndex = i;
                    }
                }
            }

            require(closestOrderIndex != type(uint256).max, "No matching buy orders found");

            Order storage closestOrder = activeOrders[closestOrderIndex];
            tradeAmount = (remainingAmount > closestOrder.amount) ? closestOrder.amount : remainingAmount;
            tradeCost = (tradeAmount * closestOrder.price)/10**18;

            require(ethBalances[closestOrder.trader] >= tradeCost, "Buyer has insufficient ETH");

            uint256 feeAmount = (tradeCost * tradingFee) / 10000;
            ethBalances[closestOrder.trader] -= tradeCost;
            ethBalances[msg.sender] += tradeCost - feeAmount;
            ethBalances[owner] += feeAmount;

            closestOrder.amount -= tradeAmount;
            hncBalances[msg.sender] -= tradeAmount;
            remainingAmount -= tradeAmount;

            emit MarketTradeExecuted(closestOrder.trader, msg.sender, tradeAmount, closestOrder.price);

            if (closestOrder.amount == 0) {
                removeOrderFromArray(closestOrder);
            }
        }
    }

    //////////////////// Limit - Market Order Functions ////////////////////

    function cancelOrder(uint256 orderId) external {
        require(orderId < activeOrders.length && activeOrders[orderId].trader == msg.sender, "Invalid order or unauthorized");

        Order memory activeOrder = activeOrders[orderId];
        if (activeOrder.tradeType == TradeType.Buy) {
            ethBalances[msg.sender] += (activeOrder.amount * activeOrder.price)/10**18;
        } else {
            hncBalances[msg.sender] += activeOrder.amount;
        }

        removeOrderFromArray(activeOrder);
        emit OrderCancelled(activeOrder);
    }

    function getOrders() external view returns (Order[] memory) {
        return activeOrders;
    }

    function getActiveOrdersByUser(address user) external view returns (Order[] memory) {
        uint256 orderCount = 0;
        // First, count the number of orders for the user
        for (uint256 i = 0; i < activeOrders.length; i++) {
            if (activeOrders[i].trader == user) {
                orderCount++;
            }
        }

        // Create an array to hold the orders
        Order[] memory ordersForUser = new Order[](orderCount);

        // Populate the array with the user's orders
        uint256 counter = 0;
        for (uint256 i = 0; i < activeOrders.length; i++) {
            if (activeOrders[i].trader == user) {
                ordersForUser[counter] = activeOrders[i];
                counter++;
            }
        }

        return ordersForUser;
    }

    function removeOrderFromArray(Order memory aboutToRemoveOrder) internal {
        for (uint256 i = 0; i < activeOrders.length; i++) {
            if (activeOrders[i].orderId == aboutToRemoveOrder.orderId) {
                activeOrders[i] = activeOrders[activeOrders.length - 1];
                activeOrders.pop();
                break;
            }
        }
    }
}