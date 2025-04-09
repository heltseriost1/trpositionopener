# TR - Position Opener for meta trader 5
Trade Runner Position Opener 
Testing and logical building: Fazakas Szabolcs
Scripting: AI (deepseek)
Design: AI (gpt-4o)

Calculate proper position size based on risk parameters
Check margin requirements
Place stop order at the entry level
Set stop loss and take profit according to Fibonacci levels
Risk Management Features
Fibonacci-based trade setup: Create LONG/SHORT positions with CTRL+N and CTRL+V


Risk management:
Fixed risk capital or percentage-based risk
Daily loss limits and profit targets
Forbidden trading zone restrictions

How to Use
Attach the script to any chart
Use the following keyboard shortcuts:
CTRL+N: Create LONG Fibonacci setup
CTRL+V: Create SHORT Fibonacci setup
CTRL+S: Place pending order based on current setup
SHIFT+T: Delete all objects and trades (with confirmation)

Fibonacci Setup
Move your cursor to select a candle (mouse movement is tracked)
Press:
CTRL+N for LONG setup (entry at 62% retracement)
CTRL+V for SHORT setup (entry at 62% retracement)
The Fibonacci tool will be drawn with:
Entry level (62% by default)
Stop loss (0% level)
Take profit (180% extension)

Order Placement
After creating Fibonacci setup:
Press CTRL+S to place pending order

The script will
Calculate proper position size based on risk parameters
Check margin requirements
Place stop order at the entry level
Set stop loss and take profit according to Fibonacci levels
Risk Management Features

Daily Limits:
Script tracks daily P/L
Stops trading when daily loss limit or profit target is hit

Forbidden Zone:
Can define time window when trading is blocked
Automatically closes positions when entering forbidden zone
Stop Management:
Moves stop loss based on price reaching certain Fibonacci levels
Also moves stop after specified number of candles

Configuration
Input parameters can be adjusted in the script properties:
// Input parameters
input double RiskCapital = 350.0;    // Fixed risk capital amount
input double RiskPercent = 8.0;      // Risk percentage (8%)
input double FiboEntry = 0.62;       // Entry level
input double FiboSL = 0.0;           // Stop loss level
input double FiboTP = 1.8;           // Take profit level (180%)
// Stop Management
input double StopMoveTriggerLevel = 1.62;  // Move stop from this level
input double StopMoveToLevel = 0.30;       // Move stop to this level
input int CandlesToMoveStop = 20;          // Move stop after this many candles
input double StopMoveAfterCandles = 0.20;  // Move stop to this level after candles
// Daily Limits
input double DailyLossLimit = 100.0;       // Daily loss limit in account currency
input double DailyProfitTarget = 200.0;    // Daily profit target in account currency
input bool EnableDailyLimits = true;       // Enable daily loss/profit limits
// Forbidden Zone
input bool EnableForbiddenZone = true;     // Enable forbidden zone
input int ForbiddenZoneStartHour = 22;     // Forbidden zone start hour (server time)
input int ForbiddenZoneEndHour = 1;        // Forbidden zone end hour (server time)
input int ForbiddenZoneStartMinute = 0;    // Forbidden zone start minute
input int ForbiddenZoneEndMinute = 0;      // Forbidden zone end minute

Notes
The script includes extensive error checking and logging
All actions are confirmed with on-chart comments and Print() statements
The script maintains proper SL/TP levels even if manually modified
Visual indicators show daily P/L status and forbidden zone status

Version History
1.21 - Initial release with complete feature set including:
Fibonacci-based trading
Advanced risk management
Stop management
Daily limits
Forbidden zone
