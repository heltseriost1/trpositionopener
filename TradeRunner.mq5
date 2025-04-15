//+------------------------------------------------------------------+
//|                                           TRPositionOpener.mq5   |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "1.21"
#property description "Trade Runner Position Opener"
#property script_show_inputs

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>

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

// Global variables
CTrade trade;
CPositionInfo positionInfo;
CAccountInfo accountInfo;
CDealInfo dealInfo;
bool ctrlPressed = false;
bool shiftPressed = false;
string fiboName = "FiboTradeLines";
bool isLongFibo = true;
datetime lastStopMoveTime = 0;
datetime cursorTime = 0;
double cursorPrice = 0;
bool showConfirmationDialog = false;
double kezdetistop = 0;
double kezdetitp = 0;
double risk = 0.0;
double expectedTP = 0.0;
datetime lastDailyCheck = 0;
double dailyProfit = 0.0;
double dailyLoss = 0.0;
bool tradingAllowed = true;
bool inForbiddenZone = false;
bool nyitvavan = false;
string logFileName = "TradeRunnerLog.csv";
datetime lastLogUpdate = 0;
int logUpdateInterval = 300; // 5 minutes in seconds

// Line identifiers
string entryLineName = "EntryLine";
string riskLabelName = "RiskLabel";
string confirmationObjName = "ConfirmationDialog";
string dailyLimitLabelName = "DailyLimitLabel";
string forbiddenZoneLabelName = "ForbiddenZoneLabel";

string FormatAccountStatusHeader()
{
   return "Balance,Revenue,Next Risk Size,Total Trades,Average RR,Payoff %,Expectancy,Avg Minutes In Trade,Max Consec Loss,Total Commission";
}
string FormatTradesHeader()
{
   return "Account ID,Ticker,Date,Direction,Minutes In Trade,Risk Size,Closed PnL,Commission";
}
string FormatAccountStatus()
{
   // Get account statistics
   double balance = accountInfo.Balance();
   double revenue = GetTotalClosedPNL();
   double nextRiskSize = CalculateRiskAmount();
   
   // Get trade statistics
   int totalTrades = 0;
   double totalRR = 0;
   int winningTrades = 0;
   double totalProfit = 0;
   double totalLoss = 0;
   double totalMinutes = 0;
   int maxConsecutiveLosses = 0;
   int currentConsecutiveLosses = 0;
   double totalCommission = 0;
   
   // Historical trades data
   if(HistorySelect(0, TimeCurrent()))
   {
      datetime previousDealTime = 0;
      string previousPosition = "";
      double dealEntryPrice = 0;
      double dealSL = 0;
      
      // Deals are sorted from oldest to newest
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket <= 0) continue;
         
         // Filter by symbol
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
         
         ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         double dealCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         totalCommission += dealCommission;
         
         ulong positionID = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         string currentPosition = IntegerToString(positionID);
         
         // Track entry price and SL for RR calculation
         if(dealEntry == DEAL_ENTRY_IN)
         {
            dealEntryPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            // Try to extract SL from comment
            string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
            // Simplified SL extraction - in real implementation this might need more complex logic
            int slPos = StringFind(comment, "sl: ");
            if(slPos >= 0)
            {
               slPos += 4; // Skip "sl: "
               string slStr = StringSubstr(comment, slPos);
               dealSL = StringToDouble(slStr);
            }
            
            previousDealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         }
         else if(dealEntry == DEAL_ENTRY_OUT)
         {
            // If this is a position close
            if(currentPosition == previousPosition)
            {
               totalTrades++;
               
               // Calculate minutes in trade
               datetime closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
               double minutesInTrade = (closeTime - previousDealTime) / 60.0;
               totalMinutes += minutesInTrade;
               
               // Calculate RR if we have SL
               if(dealSL != 0 && dealEntryPrice != 0)
               {
                  double riskPoints = MathAbs(dealEntryPrice - dealSL);
                  double rewardPoints = MathAbs(HistoryDealGetDouble(dealTicket, DEAL_PRICE) - dealEntryPrice);
                  double rr = riskPoints > 0 ? rewardPoints / riskPoints : 0;
                  totalRR += rr;
               }
               
               // Track winning/losing trades
               if(dealProfit > 0)
               {
                  winningTrades++;
                  totalProfit += dealProfit;
                  currentConsecutiveLosses = 0;
               }
               else
               {
                  totalLoss += MathAbs(dealProfit);
                  currentConsecutiveLosses++;
                  if(currentConsecutiveLosses > maxConsecutiveLosses)
                     maxConsecutiveLosses = currentConsecutiveLosses;
               }
            }
            
            previousPosition = "";
         }
         else
         {
            // Keep track of the current position
            previousPosition = currentPosition;
         }
      }
   }
   
   // Calculate statistics
   double averageRR = totalTrades > 0 ? totalRR / totalTrades : 0;
   double payoffPercent = totalTrades > 0 ? (double)winningTrades / totalTrades * 100 : 0;
   double avgMinutes = totalTrades > 0 ? totalMinutes / totalTrades : 0;
   
   // Calculate expectancy: (Win% * Avg Win) - (Loss% * Avg Loss)
   double expectancy = 0;
   if(totalTrades > 0)
   {
      double winPercent = (double)winningTrades / totalTrades;
      double lossPercent = 1.0 - winPercent;
      double avgWin = winningTrades > 0 ? totalProfit / winningTrades : 0;
      double avgLoss = (totalTrades - winningTrades) > 0 ? totalLoss / (totalTrades - winningTrades) : 0;
      
      expectancy = (winPercent * avgWin) - (lossPercent * avgLoss);
   }
   
   // Format the output string
   string result = StringFormat("%.2f,%.2f,%.2f,%d,%.2f,%.2f,%.2f,%.2f,%d,%.2f",
                             balance,
                             revenue,
                             nextRiskSize,
                             totalTrades,
                             averageRR,
                             payoffPercent,
                             expectancy,
                             avgMinutes,
                             maxConsecutiveLosses,
                             totalCommission);
   
   return result;
}

//+------------------------------------------------------------------+
//| Format individual trade data for CSV                             |
//+------------------------------------------------------------------+
string FormatHistoricalTrades()
{
   string result = "";
   
   if(HistorySelect(0, TimeCurrent()))
   {
      // Container for tracking open positions
      struct PositionData
      {
         ulong positionID;
         datetime openTime;
         double openPrice;
         double closePrice;
         ENUM_POSITION_TYPE direction;
         double volume;
         string symbol;
      };
      
      // Map to store position data keyed by position ID
      PositionData positions[];
      int positionsCount = 0;
      
      // First pass: collect all position data
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket <= 0) continue;
         
         // Filter by symbol
         string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
         if(dealSymbol != _Symbol) continue;
         
         ulong positionID = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         
         // For position entry
         if(dealEntry == DEAL_ENTRY_IN)
         {
            // Check if we already have this position
            bool found = false;
            for(int j = 0; j < positionsCount; j++)
            {
               if(positions[j].positionID == positionID)
               {
                  found = true;
                  break;
               }
            }
            
            if(!found)
            {
               // Add new position
               ArrayResize(positions, positionsCount + 1);
               positions[positionsCount].positionID = positionID;
               positions[positionsCount].openTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
               positions[positionsCount].openPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
               positions[positionsCount].direction = dealType == DEAL_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
               positions[positionsCount].volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
               positions[positionsCount].symbol = dealSymbol;
               positionsCount++;
            }
         }
         // For position exit
         else if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
         {
            for(int j = 0; j < positionsCount; j++)
            {
               if(positions[j].positionID == positionID)
               {
                  positions[j].closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
                  break;
               }
            }
         }
      }
      
      // Second pass: format each closed position as a CSV line
      for(int i = 0; i < positionsCount; i++)
      {
         // Skip positions without close price (still open)
         if(positions[i].closePrice == 0) continue;
         
         // Calculate profit/loss
         double closedPnL = 0;
         double commission = 0;
         double riskSize = 0; // This would need to be calculated or retrieved from order comments
         
         // Find the actual P/L and commission in the history
         for(int j = 0; j < totalDeals; j++)
         {
            ulong dealTicket = HistoryDealGetTicket(j);
            if(dealTicket <= 0) continue;
            
            if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == positions[i].positionID)
            {
               closedPnL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
               commission += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
               
               // Try to extract risk size from comment
               string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
               int riskPos = StringFind(comment, "risk: ");
               if(riskPos >= 0)
               {
                  riskPos += 6; // Skip "risk: "
                  string riskStr = StringSubstr(comment, riskPos);
                  riskSize = StringToDouble(riskStr);
               }
            }
         }
         
         // Calculate minutes in trade
         datetime closeTime = 0;
         for(int j = totalDeals - 1; j >= 0; j--)
         {
            ulong dealTicket = HistoryDealGetTicket(j);
            if(dealTicket <= 0) continue;
            
            if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == positions[i].positionID &&
               (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            {
               closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
               break;
            }
         }
         
         double minutesInTrade = closeTime > 0 ? (closeTime - positions[i].openTime) / 60.0 : 0;
         
         // Format the CSV line
         string line = StringFormat("%d,%s,%s,%s,%.2f,%.2f,%.2f,%.2f",
                                 accountInfo.Login(),
                                 positions[i].symbol,
                                 TimeToString(positions[i].openTime, TIME_DATE|TIME_MINUTES),
                                 positions[i].direction == POSITION_TYPE_BUY ? "BUY" : "SELL",
                                 minutesInTrade,
                                 riskSize,
                                 closedPnL,
                                 commission);
         
         if(result != "") result += "\n";
         result += line;
      }
   }
   
   return result;
}
void SaveLogToCSV()
{
   string accountStatus = FormatAccountStatus();
   string tradesData = FormatHistoricalTrades();
   
   int fileHandle;
   
   // Check if file exists
   if(FileIsExist(logFileName))
   {
      // Open existing file for writing
      fileHandle = FileOpen(logFileName, FILE_WRITE|FILE_CSV);
   }
   else
   {
      // Create new file and write headers
      fileHandle = FileOpen(logFileName, FILE_WRITE|FILE_CSV);
      if(fileHandle != INVALID_HANDLE)
      {
         FileWrite(fileHandle, "ACCOUNT STATUS");
         FileWrite(fileHandle, FormatAccountStatusHeader());
      }
   }
   
   if(fileHandle != INVALID_HANDLE)
   {
      // Write account status
      FileWrite(fileHandle, accountStatus);
      FileWrite(fileHandle, ""); // Empty line
      FileWrite(fileHandle, "TRADE HISTORY");
      FileWrite(fileHandle, FormatTradesHeader());
      
      // Write trades data (may contain multiple lines)
      string trades[];
      StringSplit(tradesData, '\n', trades);
      for(int i = 0; i < ArraySize(trades); i++)
      {
         if(trades[i] != "")
            FileWrite(fileHandle, trades[i]);
      }
      
      FileClose(fileHandle);
      Print("Log updated: ", logFileName);
   }
   else
   {
      Print("Failed to open log file: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Check if it's time to update the log                             |
//+------------------------------------------------------------------+
void CheckLogUpdate()
{
   if(TimeCurrent() - lastLogUpdate >= logUpdateInterval)
   {
      SaveLogToCSV();
      lastLogUpdate = TimeCurrent();
   }
}
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Clear any existing chart objects
   ObjectsDeleteAll(0, -1, -1);
   
   // Correct way to set chart event handling in MQL5
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, 1);         // Enable mouse move events
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, 1);      // Enable object creation events
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, 1);      // Enable object deletion events
   
   // For general properties
   ChartSetInteger(0, CHART_KEYBOARD_CONTROL, 1);         // Enable keyboard control
   ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, 0);        // Hide object descriptions
   
   // Initialize Fibonacci tools if they exist
   if(ObjectFind(0, fiboName) >= 0)
   {
      CreateHiddenEntryLine();
   }
   else
   {
      Comment("Use CTRL+N for LONG Fibonacci\nCTRL+V for SHORT Fibonacci");
   }
   
   // Initialize daily limits and forbidden zone
   UpdateDailyProfitLoss();
   CheckForbiddenZone();
   CreateDailyLimitLabel();
   CreateForbiddenZoneLabel();
   EventSetTimer(5);
   
   Print("EA initialized. Use CTRL+N (LONG), CTRL+V (SHORT), Ctrl+S to place order, Shift+T to delete all");
   lastLogUpdate = 0;  // Force update on start
   CheckLogUpdate();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, entryLineName);
   ObjectDelete(0, riskLabelName);
   ObjectDelete(0, dailyLimitLabelName);
   ObjectDelete(0, forbiddenZoneLabelName);
   HideConfirmationDialog();
   Comment("");
}

//+------------------------------------------------------------------+
//| Create daily limit label                                         |
//+------------------------------------------------------------------+
void CreateDailyLimitLabel()
{
   ObjectCreate(0, dailyLimitLabelName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_BACK, false);
   UpdateDailyLimitLabel();
}

//+------------------------------------------------------------------+
//| Create forbidden zone label                                      |
//+------------------------------------------------------------------+
void CreateForbiddenZoneLabel()
{
   ObjectCreate(0, forbiddenZoneLabelName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_YDISTANCE, 60);
   ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_BACK, false);
   UpdateForbiddenZoneLabel();
}

//+------------------------------------------------------------------+
//| Update daily limit label                                         |
//+------------------------------------------------------------------+
void UpdateDailyLimitLabel()
{
   string text = StringFormat("Daily P/L: %.2f %s\nLoss Limit: %.2f / Target: %.2f\nTrading: %s",
                             dailyProfit - dailyLoss, accountInfo.Currency(),
                             DailyLossLimit, DailyProfitTarget,
                             tradingAllowed ? "ALLOWED" : "BLOCKED");
   
   if(!tradingAllowed)
   {
      text += "\nDaily limit reached!";
   }
   
   ObjectSetString(0, dailyLimitLabelName, OBJPROP_TEXT, text);
   
   // Change color based on status
   if(!tradingAllowed)
   {
      ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_COLOR, clrRed);
   }
   else if((dailyProfit - dailyLoss) >= DailyProfitTarget * 0.8)
   {
      ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_COLOR, clrLime);
   }
   else if((dailyLoss - dailyProfit) >= DailyLossLimit * 0.8)
   {
      ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetInteger(0, dailyLimitLabelName, OBJPROP_COLOR, clrWhite);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update forbidden zone label                                      |
//+------------------------------------------------------------------+
void UpdateForbiddenZoneLabel()
{
   string text = StringFormat("Forbidden Zone: %s\n%02d:%02d - %02d:%02d",
                             inForbiddenZone ? "ACTIVE" : "INACTIVE",
                             ForbiddenZoneStartHour, ForbiddenZoneStartMinute,
                             ForbiddenZoneEndHour, ForbiddenZoneEndMinute);
   
   ObjectSetString(0, forbiddenZoneLabelName, OBJPROP_TEXT, text);
   
   // Change color based on status
   if(inForbiddenZone)
   {
      ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_COLOR, clrRed);
      ObjectSetString(0, forbiddenZoneLabelName, OBJPROP_TEXT, text + "\nTRADING BLOCKED");
   }
   else
   {
      ObjectSetInteger(0, forbiddenZoneLabelName, OBJPROP_COLOR, clrWhite);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Check if current time is in forbidden zone                       |
//+------------------------------------------------------------------+
void CheckForbiddenZone()
{
   if(!EnableForbiddenZone) 
   {
      inForbiddenZone = false;
      return;
   }
   
   MqlDateTime currentTime;
   TimeCurrent(currentTime);
   
   // Convert to minutes since midnight for easier comparison
   int currentMinutes = currentTime.hour * 60 + currentTime.min;
   int startMinutes = ForbiddenZoneStartHour * 60 + ForbiddenZoneStartMinute;
   int endMinutes = ForbiddenZoneEndHour * 60 + ForbiddenZoneEndMinute;
   
   // Handle overnight forbidden zone (e.g., 22:00 to 01:00)
   if(startMinutes > endMinutes)
   {
      inForbiddenZone = (currentMinutes >= startMinutes) || (currentMinutes < endMinutes);
   }
   else
   {
      inForbiddenZone = (currentMinutes >= startMinutes) && (currentMinutes < endMinutes);
   }
   
   // If we entered forbidden zone, close all positions
   if(inForbiddenZone)
   {
      CloseAllPositions();
   }
   
   UpdateForbiddenZoneLabel();
}

//+------------------------------------------------------------------+
//| Close all positions                                             |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         trade.PositionClose(ticket);
         Print("Closed position with ticket: ", ticket, " due to forbidden zone");
      }
   }
}

//+------------------------------------------------------------------+
//| Update daily profit/loss                                         |
//+------------------------------------------------------------------+
void UpdateDailyProfitLoss()
{
   if(!EnableDailyLimits) return;
   
   // Check if we need to update (not more than once per minute)
   if(TimeCurrent() - lastDailyCheck < 60) return;
   
   lastDailyCheck = TimeCurrent();
   
   MqlDateTime today;
   TimeToStruct(TimeCurrent(), today);
   today.hour = 0;
   today.min = 0;
   today.sec = 0;
   datetime startOfDay = StructToTime(today);
   
   dailyProfit = 0.0;
   dailyLoss = 0.0;
   
   if(HistorySelect(startOfDay, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket > 0)
         {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            if(profit > 0)
            {
               dailyProfit += profit;
            }
            else
            {
               dailyLoss += -profit;
            }
         }
      }
   }
   
   // Check if limits are reached
   if(EnableDailyLimits)
   {
      if(dailyLoss >= DailyLossLimit || (dailyProfit - dailyLoss) >= DailyProfitTarget)
      {
         tradingAllowed = false;
         Comment("Daily limit reached!\n",
                "Daily Profit: ", DoubleToString(dailyProfit, 2), "\n",
                "Daily Loss: ", DoubleToString(dailyLoss, 2), "\n",
                "Net: ", DoubleToString(dailyProfit - dailyLoss, 2), "\n",
                "Trading is blocked until tomorrow");
      }
      else
      {
         tradingAllowed = true;
      }
   }
   
   UpdateDailyLimitLabel();
}

//+------------------------------------------------------------------+
//| Get total closed PNL from all time                               |
//+------------------------------------------------------------------+
double GetTotalClosedPNL()
{
   double totalPNL = 0;
   if(HistorySelect(0, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket > 0 && HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
         {
            totalPNL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         }
      }
   }
   return totalPNL;
}

//+------------------------------------------------------------------+
//| Calculate risk amount                                            |
//+------------------------------------------------------------------+
double CalculateRiskAmount()
{
   if(!tradingAllowed || inForbiddenZone) return 0;
   
   double closedPNL = GetTotalClosedPNL();
   double adjustedCapital = RiskCapital + closedPNL;
   if(adjustedCapital < 0) adjustedCapital = 0;
   return adjustedCapital * (RiskPercent / 100.0);
}

//+------------------------------------------------------------------+
//| Create Fibonacci object                                          |
//+------------------------------------------------------------------+
void CreateFibonacciObject(bool isLong)
{
   if(inForbiddenZone)
   {
      Comment("Cannot create Fibonacci during forbidden zone!");
      return;
   }
   
   ObjectDelete(0, fiboName);
   ObjectDelete(0, riskLabelName);
   
   if(cursorTime == 0)
   {
      Comment("Please move cursor to select candle first");
      return;
   }
   
   // Find candle index for cursor time
   int cursorIndex = iBarShift(_Symbol, PERIOD_CURRENT, cursorTime);
   int prevIndex = cursorIndex + 1; // Previous candle
   
   if(prevIndex < 0) 
   {
      Comment("Not enough history for selected candle");
      return;
   }
   
   double currentHigh = iHigh(_Symbol, PERIOD_CURRENT, cursorIndex);
   double currentLow = iLow(_Symbol, PERIOD_CURRENT, cursorIndex);
   double previousHigh = iHigh(_Symbol, PERIOD_CURRENT, prevIndex);
   double previousLow = iLow(_Symbol, PERIOD_CURRENT, prevIndex);
   datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, cursorIndex);
   datetime previousTime = iTime(_Symbol, PERIOD_CURRENT, prevIndex);
   
   // Extend the Fibonacci retracement horizontally by adding 100 bars to the right
   datetime endTime = currentTime + PeriodSeconds(PERIOD_CURRENT) * 15;
   
   ObjectCreate(0, fiboName, OBJ_FIBO, 0, 0, 0, 0, 0);
   
   if(isLong)
   {
      // LONG: 100% at current candle high, 0% at previous candle low
      ObjectSetInteger(0, fiboName, OBJPROP_TIME, 0, previousTime);
      ObjectSetInteger(0, fiboName, OBJPROP_TIME, 1, endTime); // Extended horizontally
      ObjectSetDouble(0, fiboName, OBJPROP_PRICE, 0, previousLow);  // 0% (SL)
      ObjectSetDouble(0, fiboName, OBJPROP_PRICE, 1, currentHigh);  // 100%
     
   }
   else
   {
      // SHORT: 100% at current candle low, 0% at previous candle high
      ObjectSetInteger(0, fiboName, OBJPROP_TIME, 0, previousTime);
      ObjectSetInteger(0, fiboName, OBJPROP_TIME, 1, endTime); // Extended horizontally
      ObjectSetDouble(0, fiboName, OBJPROP_PRICE, 0, previousHigh); // 0% (SL)
      ObjectSetDouble(0, fiboName, OBJPROP_PRICE, 1, currentLow);   // 100%
   }
   
   // Set up Fibonacci properties with custom levels
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELS, 4);
   ObjectSetDouble(0, fiboName, OBJPROP_LEVELVALUE, 0, 0.0);    // 0% level (SL)
   ObjectSetDouble(0, fiboName, OBJPROP_LEVELVALUE, 1, 1.0);    // 100% level
   ObjectSetDouble(0, fiboName, OBJPROP_LEVELVALUE, 2, -0.8);
   ObjectSetDouble(0, fiboName, OBJPROP_LEVELVALUE, 3, 0.35);
   
   // Hide level descriptions by setting empty strings
   ObjectSetString(0, fiboName, OBJPROP_LEVELTEXT, 0, "");
   ObjectSetString(0, fiboName, OBJPROP_LEVELTEXT, 1, "");
   ObjectSetString(0, fiboName, OBJPROP_LEVELTEXT, 2, "");
   ObjectSetString(0, fiboName, OBJPROP_LEVELTEXT, 3, "");
   
   // Set colors for the levels (purple)
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELCOLOR, 0, clrPurple);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELCOLOR, 1, clrPurple);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELCOLOR, 2, clrPurple);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELCOLOR, 3, clrPurple);
   
   ObjectSetInteger(0, fiboName, OBJPROP_COLOR, clrPurple);
   ObjectSetInteger(0, fiboName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, fiboName, OBJPROP_BACK, false);
   ObjectSetInteger(0, fiboName, OBJPROP_SELECTABLE, true);
   
   // Hide Fibonacci level values
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELSTYLE, 0, STYLE_SOLID);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELSTYLE, 1, STYLE_SOLID);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELSTYLE, 2, STYLE_SOLID);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELSTYLE, 3, STYLE_SOLID);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELWIDTH, 0, 1);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELWIDTH, 1, 1);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELWIDTH, 2, 1);
   ObjectSetInteger(0, fiboName, OBJPROP_LEVELWIDTH, 3, 1);
   
   isLongFibo = isLong;
   ChartRedraw();
   CreateHiddenEntryLine();
   
   Comment("Fibonacci ", (isLong ? "LONG" : "SHORT"), " created\nPress Ctrl+S to place order");
}

//+------------------------------------------------------------------+
//| Create completely hidden entry line                              |
//+------------------------------------------------------------------+
void CreateHiddenEntryLine()
{
   if(ObjectGetInteger(0, fiboName, OBJPROP_TYPE) != OBJ_FIBO) return;
   
   double price0 = ObjectGetDouble(0, fiboName, OBJPROP_PRICE, 0);
   double price1 = ObjectGetDouble(0, fiboName, OBJPROP_PRICE, 1);
   double fiboRange = MathAbs(price1 - price0);
   
   double entryPrice = isLongFibo ? 
                      price0 + (FiboEntry * fiboRange) : 
                      price0 - (FiboEntry * fiboRange);
   
   ObjectCreate(0, entryLineName, OBJ_HLINE, 0, 0, entryPrice);
   ObjectSetInteger(0, entryLineName, OBJPROP_COLOR, clrNONE);
   ObjectSetInteger(0, entryLineName, OBJPROP_WIDTH, 0);
   ObjectSetInteger(0, entryLineName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, entryLineName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, entryLineName, OBJPROP_ZORDER, 0);
}

//+------------------------------------------------------------------+
//| Stop Management function                                         |
//+------------------------------------------------------------------+
void CheckStopManagement()
{
   if(PositionsTotal() == 0 || ObjectFind(0, fiboName) < 0 || inForbiddenZone) return;
   
   ulong ticket = PositionGetTicket(0);
   if(ticket <= 0) return;
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentPrice = posType == POSITION_TYPE_BUY ? 
                        SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = PositionGetDouble(POSITION_SL);
   datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);
   
   double price0 = ObjectGetDouble(0, fiboName, OBJPROP_PRICE, 0);
   double price1 = ObjectGetDouble(0, fiboName, OBJPROP_PRICE, 1);
   double fiboRange = MathAbs(price1 - price0);
   
   // Calculate levels
   double triggerPrice, moveToPrice, afterCandlesPrice;
   
   if(posType == POSITION_TYPE_BUY)
   {
      triggerPrice = price0 + (StopMoveTriggerLevel * fiboRange);
      moveToPrice = price0 + (StopMoveToLevel * fiboRange);
      afterCandlesPrice = price0 + (StopMoveAfterCandles * fiboRange);
   }
   else
   {
      triggerPrice = price0 - (StopMoveTriggerLevel * fiboRange);
      moveToPrice = price0 - (StopMoveToLevel * fiboRange);
      afterCandlesPrice = price0 - (StopMoveAfterCandles * fiboRange);
   }
   
   // Move stop if price reaches trigger level
   if((posType == POSITION_TYPE_BUY && currentPrice >= triggerPrice) || 
      (posType == POSITION_TYPE_SELL && currentPrice <= triggerPrice))
   {
      if(MathAbs(sl - moveToPrice) > _Point)
      {
         trade.PositionModify(ticket, moveToPrice, PositionGetDouble(POSITION_TP));
         Print("Stop moved to: ", moveToPrice);
      }
   }
   
   // Move stop after specified candles
   int barsPassed = Bars(_Symbol, PERIOD_CURRENT, positionTime, TimeCurrent());
   if(barsPassed >= CandlesToMoveStop && MathAbs(sl - afterCandlesPrice) > _Point)
   {
      trade.PositionModify(ticket, afterCandlesPrice, PositionGetDouble(POSITION_TP));
      Print("Stop moved after ", barsPassed, " candles to: ", afterCandlesPrice);
   }
}

//+------------------------------------------------------------------+
//| Delete all objects, pending orders and positions                 |
//+------------------------------------------------------------------+
void DeleteAllObjectsAndTrades()
{
   // Delete all pending orders first
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         trade.OrderDelete(ticket);
         Print("Deleted pending order with ticket: ", ticket);
      }
   }
   
   // Close all open positions
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         trade.PositionClose(ticket);
         Print("Closed position with ticket: ", ticket);
      }
   }
   
   // Delete all chart objects
   ObjectsDeleteAll(0, -1, -1);
   
   Comment("All objects, orders and positions deleted");
   Print("Deleted all objects and trades");
   nyitvavan = false;
}

//+------------------------------------------------------------------+
//| Show confirmation dialog for deletion                            |
//+------------------------------------------------------------------+
void ShowConfirmationDialog()
{
   // Create simple text label with buttons
   ObjectCreate(0, confirmationObjName, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, confirmationObjName, OBJPROP_TEXT, "Delete ALL objects and trades?");
   ObjectSetInteger(0, confirmationObjName, OBJPROP_XDISTANCE, 100);
   ObjectSetInteger(0, confirmationObjName, OBJPROP_YDISTANCE, 100);
   ObjectSetInteger(0, confirmationObjName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, confirmationObjName, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, confirmationObjName, OBJPROP_FONTSIZE, 12);
   ObjectSetInteger(0, confirmationObjName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, confirmationObjName, OBJPROP_ZORDER, 1000);
   
   // Create Yes button
   ObjectCreate(0, confirmationObjName+"Yes", OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, confirmationObjName+"Yes", OBJPROP_TEXT, "Yes");
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_XDISTANCE, 100);
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_YDISTANCE, 120);
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_XSIZE, 50);
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_YSIZE, 20);
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_BGCOLOR, clrGreen);
   ObjectSetInteger(0, confirmationObjName+"Yes", OBJPROP_SELECTABLE, true);
   
   // Create No button
   ObjectCreate(0, confirmationObjName+"No", OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, confirmationObjName+"No", OBJPROP_TEXT, "No");
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_XDISTANCE, 160);
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_YDISTANCE, 120);
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_XSIZE, 50);
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_YSIZE, 20);
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_BGCOLOR, clrRed);
   ObjectSetInteger(0, confirmationObjName+"No", OBJPROP_SELECTABLE, true);
   
   showConfirmationDialog = true;
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Hide simplified confirmation dialog                              |
//+------------------------------------------------------------------+
void HideConfirmationDialog()
{
   ObjectDelete(0, confirmationObjName);
   ObjectDelete(0, confirmationObjName+"Yes");
   ObjectDelete(0, confirmationObjName+"No");
   showConfirmationDialog = false;
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Handle confirmation dialog click                                 |
//+------------------------------------------------------------------+
void HandleConfirmationClick(string sparam)
{
   if(sparam == confirmationObjName+"Yes")
   {
      DeleteAllObjectsAndTrades();
      HideConfirmationDialog();
   }
   else if(sparam == confirmationObjName+"No")
   {
      HideConfirmationDialog();
      Comment("Deletion canceled");
   }
}

//+------------------------------------------------------------------+
//| ChartEvent function                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   // Process mouse move event - get cursor position
   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      // Get candle under cursor
      int x = (int)lparam;
      int y = (int)dparam;
      datetime time = 0;
      double price = 0;
      int window = 0;
      
      // Get time and price at cursor position
      if(ChartXYToTimePrice(0, x, y, window, time, price))
      {
         cursorTime = time;
         cursorPrice = price;
      }
   }
   
   // Process keyboard events
   if(id == CHARTEVENT_KEYDOWN)
   {
      // Detect CTRL key
      if(lparam == 17 || lparam == 65507 || lparam == 65508) ctrlPressed = true;
      // Detect SHIFT key
      if(lparam == 16 || lparam == 65505 || lparam == 65506) shiftPressed = true;
      
      if(lparam == 78 && ctrlPressed) // CTRL+N
      {
         if(!inForbiddenZone)
            CreateFibonacciObject(true);
         else
            Comment("Cannot create Fibonacci during forbidden zone!");
         return;
      }
      
      if(lparam == 86 && ctrlPressed) // CTRL+V
      {
         if(!inForbiddenZone)
            CreateFibonacciObject(false);
         else
            Comment("Cannot create Fibonacci during forbidden zone!");
         return;
      }
      
      if(lparam == 83 && ctrlPressed) // CTRL+S
      {
         if(inForbiddenZone)
         {
            Comment("Cannot place orders during forbidden zone!");
            return;
         }
         
         if(ObjectFind(0, fiboName) >= 0)
            PlacePendingOrder();
         else
            Comment("Create Fibonacci first!");
         return;
      }
      
      // Handle Shift+T for complete cleanup
      if(lparam == 84 && shiftPressed) // T key with Shift
      {
         if(!showConfirmationDialog)
         {
            ShowConfirmationDialog();
         }
         return;
      }
   }
   
   // Process key release events
   if(id == CHARTEVENT_KEYUP)
   {
      // Detect key releases
      if(lparam == 17 || lparam == 65507 || lparam == 65508) ctrlPressed = false;
      if(lparam == 16 || lparam == 65505 || lparam == 65506) shiftPressed = false;
   }
   
   // Process object drag event
   if(id == CHARTEVENT_OBJECT_DRAG && sparam == fiboName)
   {
      CreateHiddenEntryLine();
   }
   
   // Process object click event
   if(id == CHARTEVENT_OBJECT_CLICK && showConfirmationDialog)
   {
      HandleConfirmationClick(sparam);
   }
}

//+------------------------------------------------------------------+
//| Check margin requirements and log details                        |
//+------------------------------------------------------------------+
bool CheckMarginRequirements(double lotSize, ENUM_ORDER_TYPE orderType, double entryPrice)
{
   double marginRequired;
   double priceForMarginCheck = orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_LIMIT ? 
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                              SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   marginRequired = accountInfo.MarginCheck(_Symbol, orderType < 2 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lotSize, priceForMarginCheck);
   double freeMargin = accountInfo.FreeMargin();
   double marginLevel = accountInfo.MarginLevel();
   
   Print("Margin Check Details:");
   Print("Lot Size: ", lotSize);
   Print("Entry Price: ", entryPrice);
   Print("Margin Required: ", marginRequired);
   Print("Free Margin: ", freeMargin);
   Print("Margin Level: ", marginLevel, "%");
   
   if(marginRequired > freeMargin)
   {
      double maxPossibleLot = freeMargin / (marginRequired / lotSize);
      maxPossibleLot = NormalizeDouble(maxPossibleLot, 2);
      
      Print("Not enough margin! Required: ", marginRequired, " Free: ", freeMargin);
      Print("Maximum possible lot size with current margin: ", maxPossibleLot);
      
      Comment("Error: Not enough margin!\n",
              "Required: ", DoubleToString(marginRequired, 2), "\n",
              "Free: ", DoubleToString(freeMargin, 2), "\n",
              "Max possible lot: ", maxPossibleLot);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Place pending order with detailed logging                        |
//+------------------------------------------------------------------+
void PlacePendingOrder()
{
   UpdateDailyProfitLoss();
   CheckForbiddenZone();
   
   if(!tradingAllowed)
   {
      string errorMsg = "Trading blocked - daily limit reached!";
      Comment(errorMsg);
      Print(errorMsg);
      return;
   }
   if(nyitvavan == true)
   {
      string errorMsg = "Pending order already taken, close first!";
      Comment(errorMsg);
      Print(errorMsg);
      return;
   }
   if(inForbiddenZone)
   {
      string errorMsg = "Trading blocked - currently in forbidden zone!";
      Comment(errorMsg);
      Print(errorMsg);
      return;
   }
   
   if(!accountInfo.TradeAllowed())
   {
      string errorMsg = "Trading is not allowed! Check account permissions.";
      Comment(errorMsg);
      Print(errorMsg);
      return;
   }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   double entryPrice = ObjectGetDouble(0, entryLineName, OBJPROP_PRICE, 0);
   double price0 = ObjectGetDouble(0, fiboName, OBJPROP_PRICE, 0);
   double price1 = ObjectGetDouble(0, fiboName, OBJPROP_PRICE, 1);
   double fiboRange = MathAbs(price1 - price0);
   
   double slPrice, tpPrice;
   if(isLongFibo)
   {
      // LONG: SL at previous candle low (0%), TP at 180% beyond current candle high
      slPrice = (FiboSL > 0) ? price0 + (FiboSL * fiboRange) : price0;  // 0% level is SL
      tpPrice = price0 + (FiboTP * fiboRange);  // 180% level is TP (1.8 RR)
   }
   else
   {
      // SHORT: SL at previous candle high (0%), TP at 180% beyond current candle low
      slPrice = (FiboSL > 0) ? price0 - (FiboSL * fiboRange) : price0;  // 0% level is SL
      tpPrice = price0 - (FiboTP * fiboRange);  // 180% level is TP (1.8 RR)
   }
   
   double currentPrice = isLongFibo ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate risk amount
   double riskAmount = CalculateRiskAmount();
   
   ENUM_ORDER_TYPE orderType;
   double stopLossPoints;
   
   if(isLongFibo)
   {
      stopLossPoints = MathAbs(entryPrice - slPrice) / _Point;
      orderType = (currentPrice < entryPrice) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_BUY_LIMIT;
      expectedTP = tpPrice;
   }
   else
   {
      stopLossPoints = MathAbs(slPrice - entryPrice) / _Point;
      orderType = (currentPrice > entryPrice) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_SELL_LIMIT;
      expectedTP = tpPrice;
   }
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointCost = tickValue * (_Point / tickSize);
   double lotSize = NormalizeDouble(riskAmount / (stopLossPoints * pointCost), 2);
   
   // Check minimum and maximum lot size
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(lotSize < minLot)
   {
      string errorMsg = StringFormat("Error: Calculated lot size (%.2f) is below minimum (%.2f)", lotSize, minLot);
      Comment(errorMsg);
      Print(errorMsg);
      return;
   }
   
   if(lotSize > maxLot)
   {
      string errorMsg = StringFormat("Error: Calculated lot size (%.2f) is above maximum (%.2f)", lotSize, maxLot);
      Comment(errorMsg);
      Print(errorMsg);
      return;
   }
   
   // Adjust lot size to step
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   // Check margin requirements
   if(!CheckMarginRequirements(lotSize, orderType, entryPrice))
      return;
   
   // Prepare request
   request.action = TRADE_ACTION_PENDING;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.price = entryPrice;
   request.sl = slPrice;
   request.tp = tpPrice;
   request.deviation = 10;
   request.type = orderType;
   request.type_filling = ORDER_FILLING_FOK;
   request.expiration = TimeCurrent() + 3*24*60*60;
   kezdetistop = slPrice;
   kezdetitp = tpPrice;
   
   // Send order
   bool res = OrderSend(request, result);
   
   if(res)
   {
      string successMsg = StringFormat("Order placed successfully!\nType: %s\nLot: %.2f\nEntry: %.5f\nSL: %.5f\nTP: %.5f",
                                    EnumToString(orderType), lotSize, entryPrice, slPrice, tpPrice);
      Comment(successMsg);
      Print(successMsg);
      nyitvavan = true;
      string comment = StringFormat("risk: %.2f, entry: %.5f, sl: %.5f, tp: %.5f", 
                             riskAmount, entryPrice, slPrice, tpPrice);
      
      SaveLogToCSV();
   }
   else
   {
      string errorDesc = GetTradeErrorDescription(result.retcode);
      string errorMsg = StringFormat("Order failed!\nError: %s (%d)\nLot: %.2f\nPrice: %.5f",
                                   errorDesc, result.retcode, lotSize, entryPrice);
      Comment(errorMsg);
      Print(errorMsg);
   }
}

//+------------------------------------------------------------------+
//| Get trade error description                                      |
//+------------------------------------------------------------------+
string GetTradeErrorDescription(int errorCode)
{
   switch(errorCode)
   {
      case 10004: return "Requote";
      case 10006: return "Request rejected";
      case 10007: return "Request canceled by trader";
      case 10008: return "Order placed";
      case 10009: return "Request completed";
      case 10010: return "Only part of the request was completed";
      case 10011: return "Request processing error";
      case 10012: return "Request canceled by timeout";
      case 10013: return "Invalid request";
      case 10014: return "Invalid volume in the request";
      case 10015: return "Invalid price in the request";
      case 10016: return "Invalid stops in the request";
      case 10017: return "Trade is disabled";
      case 10018: return "Market is closed";
      case 10019: return "Not enough money";
      case 10020: return "Prices changed";
      case 10021: return "There are no quotes to process the request";
      case 10022: return "Invalid order expiration date in the request";
      case 10023: return "Order state changed";
      case 10024: return "Too frequent requests";
      case 10025: return "No changes in request";
      case 10026: return "Autotrading disabled by server";
      case 10027: return "Autotrading disabled by client terminal";
      case 10028: return "Request locked for processing";
      case 10029: return "Order or position frozen";
      case 10030: return "Invalid order filling type";
      default: return "Unknown error (" + IntegerToString(errorCode) + ")";
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyProfitLoss();
   CheckForbiddenZone();
   CheckStopManagement();
   CheckLogUpdate();
}

void OnTimer()
{
   EnforceTPandSL();
   CheckLogUpdate();
}

void EnforceTPandSL() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionSelectByTicket(ticket)) {
            string symbol = PositionGetString(POSITION_SYMBOL);
            if (symbol != _Symbol) continue;

            double currentTP = PositionGetDouble(POSITION_TP);
            double currentSL = PositionGetDouble(POSITION_SL);
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            long type = PositionGetInteger(POSITION_TYPE);

            bool modifyNeeded = false;
            double newTP = currentTP;
            double newSL = currentSL;

            // TP check
            if (NormalizeDouble(currentTP, _Digits) != NormalizeDouble(expectedTP, _Digits)) {
                newTP = expectedTP;
                modifyNeeded = true;
            }

            // SL check
            if (type == POSITION_TYPE_BUY) {
                if (NormalizeDouble(currentSL, _Digits) < NormalizeDouble(kezdetistop, _Digits)) {
                    newSL = kezdetistop;
                    modifyNeeded = true;
                }
            } else if (type == POSITION_TYPE_SELL) {
                if (NormalizeDouble(currentSL, _Digits) > NormalizeDouble(kezdetistop, _Digits)) {
                    newSL = kezdetistop;
                    modifyNeeded = true;
                }
            }

            // Modify only if needed
            if (modifyNeeded) {
                trade.PositionModify(symbol, newSL, newTP);
            }
        }
    }
}
