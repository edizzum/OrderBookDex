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
        tradingFee = _fee;
    }

    //////////////////// Deposit - Withdraw Functions ////////////////////

    function depositETH() external payable {
        require(msg.value != 0, "No value is given!");
        ethBalances[msg.sender] += msg.value;
    }

    function depositHNC(uint256 _amount) external {
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

    //////////////////// Limit Order Functions ////////////////////

    function createLimitOrder(TradeType _tradeType, uint256 _amount, uint256 _price) external {
        if (_tradeType == TradeType.Buy) {
            require(ethBalances[msg.sender] >= _amount * _price, "Insufficient ETH balance");
            uint256 tradeCost = _amount * _price;
            ethBalances[msg.sender] -= tradeCost;
        } else {
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
            if (existingOrder.tradeType != newOrder.tradeType && existingOrder.price == newOrder.price && existingOrder.amount >= newOrder.amount) {
                executeTrade(existingOrder, newOrder);
                return true;
            }
        }
        return false;
    }

    function executeTrade(Order storage matchedOrder, Order memory newOrder) internal {
        uint256 tradeAmount = newOrder.amount;
        if (matchedOrder.amount < newOrder.amount) {
            tradeAmount = matchedOrder.amount;
        }

        uint256 tradeCost = tradeAmount * newOrder.price;
        uint256 feeAmount = (tradeCost * tradingFee) / 10000;

        if (newOrder.tradeType == TradeType.Buy) {
            require(ethBalances[newOrder.trader] >= tradeCost, "Buyer has insufficient ETH");
            ethBalances[newOrder.trader] -= tradeCost;
            ethBalances[owner] += feeAmount;
            ethBalances[matchedOrder.trader] += tradeCost - feeAmount;
            hncBalances[matchedOrder.trader] -= tradeAmount;
            hncBalances[newOrder.trader] += tradeAmount;
        } else {
            require(ethBalances[matchedOrder.trader] >= tradeCost, "Buyer has insufficient ETH");
            ethBalances[matchedOrder.trader] -= tradeCost;
            ethBalances[owner] += feeAmount;
            ethBalances[newOrder.trader] += tradeCost - feeAmount;
            hncBalances[newOrder.trader] -= tradeAmount;
            hncBalances[matchedOrder.trader] += tradeAmount;
        }

        matchedOrder.amount -= tradeAmount;
        newOrder.amount -= tradeAmount;

        if (matchedOrder.amount == 0) {
            removeOrderFromArray(matchedOrder);
        } else {
            matchedOrder.isActive = true;
        }

        if (newOrder.amount == 0) {
            removeOrderFromArray(newOrder);
        }

        if (newOrder.tradeType == TradeType.Buy) {
            emit LimitTradeExecuted(newOrder.trader, matchedOrder.trader, tradeAmount, newOrder.price);
        } else {
            emit LimitTradeExecuted(matchedOrder.trader, newOrder.trader, tradeAmount, newOrder.price);
        }
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
            tradeCost = tradeAmount * closestOrder.price;

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
            tradeCost = tradeAmount * closestOrder.price;

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
            ethBalances[msg.sender] += activeOrder.amount * activeOrder.price;
        } else {
            hncBalances[msg.sender] += activeOrder.amount;
        }

        removeOrderFromArray(activeOrder);
        emit OrderCancelled(activeOrder);
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