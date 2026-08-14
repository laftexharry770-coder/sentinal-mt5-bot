//+------------------------------------------------------------------+
//|                                                     Sentinal.mq5 |
//|                     Trend-adaptive Expert Advisor for MetaTrader 5 |
//+------------------------------------------------------------------+
#property copyright "Sentinal"
#property version   "2.08"
#property strict
#property description "Safer Martingale Scalper"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum EStrategy
  {
   STRAT_EMA_CROSS,      // EMA cross (fast crosses slow)
   STRAT_RSI_REVERSION,  // RSI reversion (leaves oversold/overbought)
   STRAT_BREAKOUT        // Breakout of N-bar high/low
  };

enum ESignal { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

//+------------------------------------------------------------------+
//| How stop loss / take profit are derived                          |
//+------------------------------------------------------------------+
enum EStopMode
  {
   STOP_DOLLAR,     // Fixed $ stop & target (AXIOM-style)
   STOP_ATR         // ATR-based stop & target (adaptive)
  };

enum EDirection
  {
   DIR_BOTH,        // Long and short
   DIR_LONG_ONLY,   // Long only
   DIR_SHORT_ONLY   // Short only
  };

//+------------------------------------------------------------------+
//| Every reason a bar can fail to produce a trade. Tallied and      |
//| printed at the end of a run, so "it isn't trading" always has a  |
//| specific, counted answer instead of a guess.                     |
//+------------------------------------------------------------------+
enum EBlock
  {
   BLK_ENTER = 0,
   BLK_AUTOTRADE_OFF,
   BLK_TARGET_HALT,
   BLK_HOURS,
   BLK_DAILY_LOSS,
   BLK_SPREAD,
   BLK_POSLIMIT,
   BLK_TOTALRISK,
   BLK_NOSIGNAL,
   BLK_TREND_FLAT,
   BLK_TREND_OPPOSED,
   BLK_DIRECTION,
   BLK_SESSION,
   BLK_MAXLOSS,
   BLK_MOMENTUM,
   BLK_COUNT
  };

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string BlockName(const int b)
  {
   switch(b)
     {
      case BLK_ENTER:
         return("entered");
      case BLK_AUTOTRADE_OFF:
         return("auto-trade OFF");
      case BLK_TARGET_HALT:
         return("halted at profit target");
      case BLK_HOURS:
         return("outside trading hours");
      case BLK_DAILY_LOSS:
         return("daily loss limit");
      case BLK_SPREAD:
         return("spread too wide");
      case BLK_POSLIMIT:
         return("position limit reached");
      case BLK_TOTALRISK:
         return("combined open risk at cap");
      case BLK_NOSIGNAL:
         return("no entry signal");
      case BLK_TREND_FLAT:
         return("trend flat / ADX below minimum");
      case BLK_TREND_OPPOSED:
         return("signal against higher-TF trend");
      case BLK_DIRECTION:
         return("direction disabled (long/short filter)");
      case BLK_MOMENTUM:
         return("MACD momentum disagrees");
      case BLK_SESSION:
         return("outside New York session");
      case BLK_MAXLOSS:
         return("max total loss reached");
     }
   return("unknown");
  }

//+------------------------------------------------------------------+
//| Inputs                                                           |
//|                                                                  |
//| All distances are in POINTS, never "pips". A point is the        |
//| smallest quote increment for the symbol, so the same number      |
//| means the same thing on XAUUSD, EURUSD and indices alike.        |
//| On 2-digit gold, 1 point = 0.01, so 100 points = $1.00 of price. |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Visible inputs — the AXIOM-style dialog plus the strategy,       |
//| execution, time, recovery and adaptive-ATR groups. The on/off    |
//| switch is MT5's own "Allow Algo Trading" checkbox on the Common  |
//| tab, the same as the reference EA.                               |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double InpInitialLot       = 0.01;   // Initial lot size (MINIMUM)
input double InpStopLossUSD      = 2.0;    // Stop loss per trade ($)
input double InpTakeProfitUSD    = 1.0;    // Take profit per trade ($)
input double InpLossTriggerUSD   = 0.5;    // Loss to trigger recovery ($)
input bool   InpCloseAllOnProfit = true;   // Close ALL trades when total floating P/L is positive
input double InpCloseAllMinUSD   = 1.0;    // Min floating profit ($) to close all; 0 = any profit

input group "=== Martingale Settings ==="
input double InpMartingaleMult   = 2.0;    // Martingale multiplier
input int    InpMaxRecovery      = 3;      // Maximum recovery attempts
input bool   InpUseTrailingStop  = true;   // Use trailing stop

input group "=== Zero-Loss Recovery ==="
input bool   InpZeroLossRecovery = true;   // Postpone losses until profits repay them
input double InpRecoveryCover    = 1.2;    // Profit margin to fully clear the loss ledger

input group "=== Session ==="
input bool   InpNewYorkOnly      = true;   // Trade the New York session only

input group "=== Time Filter ==="
input bool   InpUseTimeFilter    = false;  // Restrict to custom hours (off = all day)
input int    InpStartHour        = 0;      // Start hour (server time)
input int    InpEndHour          = 24;     // End hour (server time)

input group "=== Strategy ==="
input EStrategy  InpStrategy     = STRAT_EMA_CROSS; // Entry strategy: EMA cross, RSI reversion or breakout
input int        InpFastEMA      = 5;               // Fast EMA period (EMA cross)
input int        InpSlowEMA      = 13;              // Slow EMA period (EMA cross)
input int        InpRSIPeriod    = 14;              // RSI period (RSI reversion)
input int        InpRSIOversold  = 30;              // RSI oversold threshold (RSI reversion)
input int        InpRSIOverbought= 70;              // RSI overbought threshold (RSI reversion)
input int        InpBreakoutBars = 20;              // Breakout lookback bars (breakout)

input group "=== Execution ==="
input bool       InpIntrabarSignals = false;   // Intrabar: act on the forming candle (off = bar-close / interbar)
input EStopMode  InpStopMode        = STOP_ATR; // Stop/target mode: ATR-based (adaptive) or fixed $
input int        InpMaxPositions    = 5;        // Maximum simultaneous positions

input group "=== Adaptive ATR ==="
input bool       InpUseAdaptiveATR = true;      // Scale ATR by its own volatility regime
input int        InpATRAdaptBars   = 50;        // Baseline lookback for the regime (bars)
input double     InpATRScaleMin    = 0.5;       // Calm-market floor (x current ATR)
input double     InpATRScaleMax    = 2.0;       // Storm-market ceiling (x current ATR)

input group "=== Trend Filter ==="
input bool       InpUseTrendFilter = false;     // Only trade with the higher-TF trend
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H4; // Trend timeframe
input int        InpTrendEMA       = 200;       // Trend EMA period
input bool       InpUseADX         = false;     // Require ADX trend strength
input double     InpADXMin         = 20.0;      // Minimum ADX reading
input bool       InpCloseOnReverse = true;      // Exit open trades when the trend reverses

input group "=== Trend-Adaptive SL ==="
input bool       InpAdaptiveTrendSL = true;     // Widen the stop when trading WITH the higher-TF trend
input double     InpTrendSLWiden    = 1.5;      // Stop multiplier with the trend (room to breathe)
input double     InpTrendSLTighten  = 0.8;      // Stop multiplier against the trend (tighter)

input group "=== Momentum (MACD) ==="
input bool       InpUseMACD        = true;      // Require MACD histogram to agree with the signal
input int        InpMACDFast       = 12;        // MACD fast EMA
input int        InpMACDSlow       = 26;        // MACD slow EMA
input int        InpMACDSignal     = 9;         // MACD signal period

input group "=== Infinite RR ==="
input bool       InpUseInfiniteRR  = true;      // Breakeven then trail, no fixed target
input double     InpBreakevenAtR   = 2.0;       // Move stop to entry at this multiple of risk
input double     InpBEBufferR      = 0.1;       // Buffer past entry, in R
input int        InpTrailBars      = 1;         // Trail behind the low/high of the last N closed bars

input group "=== Journal ==="
input bool       InpWriteJournal   = true;      // Append every closed trade to Sentinal_journal.csv

input group "=== Spread Filter ==="
input int        InpMaxSpreadPoints = 1000;      // Absolute spread cap (points); 0 = off
input double     InpMaxSpreadATR    = 0.0;       // Spread cap as fraction of ATR; 0 = off

input group "=== Market Break ==="
input bool       InpUseMarketBreak  = true;      // Daily market break counts as closed
input int        InpBreakStartHour  = 23;        // Break starts (local time) - 11:50 PM
input int        InpBreakStartMin   = 50;
input int        InpBreakEndHour    = 1;         // Break ends (local time) - 1:10 AM
input int        InpBreakEndMin     = 10;

//+------------------------------------------------------------------+
//| Fixed configuration — identical functionality, no longer shown   |
//| in the Inputs dialog. Names unchanged so every code path below   |
//| compiles exactly as before.                                      |
//+------------------------------------------------------------------+
const bool   InpAutoTrade        = true;    // gate is the Algo Trading checkbox now
const long   InpMagicNumber      = 770001;

const int    InpADXPeriod        = 14;

const EDirection InpDirection    = DIR_BOTH;
// strategy, execution, time, recovery and trend-filter settings moved
// to the visible input groups above.

const bool   InpScaleToBalance   = true;    // dollar settings scale to live balance
const double InpRefBalance       = 1000.0;  // ...written for a $1000 account

// Stop mode is the visible InpStopMode input (STOP_DOLLAR / STOP_ATR);
// ATR stops use the adaptive ATR (see AdaptiveATR()).
const bool   InpUseMartingale    = true;
const double InpTrailStartUSD    = 0.5;
const double InpTrailDistUSD     = 0.5;

// The New York session is defined in GMT, not server time, so it stays
// correct on any broker. 13:00-22:00 GMT is the NY trading day, which is
// 16:00-01:00 in Nairobi (EAT, GMT+3).
const int    InpNYStartHour      = 13;      // GMT
const int    InpNYEndHour        = 22;      // GMT

const double InpDailyProfitUSD   = 100.0;
const double InpMaxLossPctBal    = 50.0;
const bool   InpUseRiskPercent   = true;
const double InpRiskPercent      = 1.0;
const double InpMaxRiskPercent   = 5.0;
const double InpMaxTotalRiskPct  = 6.0;
const double InpMaxDailyLossPct  = 5.0;
const double InpFixedLots        = 0.01;

const int    InpATRPeriod        = 14;
const double InpATRStopMult      = 2.0;
const double InpATRTargetMult    = 3.0;
const int    InpStopLossPoints   = 3000;
const int    InpTakeProfitPoints = 6000;
const double InpATRTrailMult     = 2.0;

// Spread caps moved to the visible "Spread Filter" group above.
// InpMaxSpreadATR = 0.0 default: normal spreads never block entries.
const double InpTargetProfitPct  = 0.0;

const bool   InpVerboseLog       = true;
const bool   InpShowPanel        = true;
const color  InpPanelColor       = clrWhite;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  position;

double   g_startBalance    = 0.0;
bool     g_halted          = false;
datetime g_lastBar         = 0;
datetime g_lastEntryBar   = 0;      // the bar the last entry happened on

int      g_hMACD           = INVALID_HANDLE;

// Per-position state for the Infinite RR ladder. Max positions is small,
// so a flat array with a linear scan is cheaper than anything cleverer.
#define  RR_SLOTS 64
ulong    g_rrTicket[RR_SLOTS];
double   g_rrRisk[RR_SLOTS];        // initial entry-to-stop distance, in price
bool     g_rrBE[RR_SLOTS];          // breakeven already taken
datetime g_lastEntryTime   = 0;      // exact time of the last entry deal

double   g_dayStartBalance = 0.0;   // balance at the start of the current day
datetime g_dayStamp        = 0;     // which day that was
bool     g_dayHalted       = false; // daily loss limit tripped

int      g_recoveryStep    = 0;     // consecutive martingale escalations
datetime g_lastDealTime    = 0;     // newest closed deal already accounted for
double   g_recoveryDebt    = 0.0;   // postponed losses (zero-loss ledger)
double   g_recoveryTotal   = 0.0;   // lifetime amount repaid by winners

bool     g_algoWasOn       = false; // last known Algo Trading state
bool     g_armed           = true;  // allow an immediate first evaluation

long     g_blockTally[BLK_COUNT];   // why each evaluated bar did not trade
long     g_barsSeen        = 0;
long     g_ordersPlaced    = 0;
long     g_sizingSkips     = 0;     // signal passed every gate, sizing refused

int g_hFast  = INVALID_HANDLE;
int g_hSlow  = INVALID_HANDLE;
int g_hRSI   = INVALID_HANDLE;
int g_hATR   = INVALID_HANDLE;
int g_hTrend = INVALID_HANDLE;
int g_hADX   = INVALID_HANDLE;

const string PANEL_PREFIX = "SENT_";

//+------------------------------------------------------------------+
//| Initialisation                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(30);

   g_startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_halted       = false;
   UpdateDailyTracking();

// Seed the bar stamp now, so attaching mid-bar does not immediately
// count as "a new bar". The armed flag still lets the first tick
// evaluate the last CLOSED bar at once.
   g_lastBar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   g_armed   = true;

   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   if(!CreateIndicators())
      return(INIT_FAILED);

   if(InpUseMartingale)
     {
      double worst = 0.0;
      for(int k = 0; k <= InpMaxRecovery; k++)
         worst += InpInitialLot * MathPow(InpMartingaleMult, k);
      PrintFormat("Sentinal: MARTINGALE ON. Ladder %d steps x%.2f. A full losing "
                  "sequence stakes %.2f lots in total before the ladder resets.",
                  InpMaxRecovery, InpMartingaleMult, worst);
     }

   if(InpZeroLossRecovery)
      PrintFormat("Sentinal: ZERO-LOSS recovery ON — losses are postponed in a ledger "
                  "until profits repay them (cover x%.2f, max risk %.1f%% per trade).",
                  InpRecoveryCover, InpMaxRiskPercent);

   if(InpIntrabarSignals)
      Print("Sentinal: INTRABAR mode — rules read the forming candle. Entries are "
            "faster but a signal can appear and then vanish before the candle closes, "
            "so live results will differ from a bar-close backtest.");
   else
      Print("Sentinal: BAR-CLOSE (interbar) mode — signals read only closed candles "
            "and entries fire at the next bar open, so backtest and live agree.");

   if(InpStopMode == STOP_ATR)
      PrintFormat("Sentinal: ATR stops ON (stop %.2f x ATR, target %.2f x ATR)%s",
                  InpATRStopMult, InpATRTargetMult,
                  (InpUseAdaptiveATR
                   ? StringFormat(", adaptive scale x%.2f..x%.2f over %d bars",
                                  InpATRScaleMin, InpATRScaleMax, InpATRAdaptBars)
                   : ""));
   else
      Print("Sentinal: fixed $ stops ON — SL/TP amounts adapt to the actual lot.");

   if(InpShowPanel)
      PanelUpdate();

   PrintFormat("Sentinal v2.08 on %s | strategy=%s | auto-trade=%s | digits=%d | point=%s",
               _Symbol, EnumToString(InpStrategy), (InpAutoTrade ? "ON" : "OFF"),
               _Digits, DoubleToString(_Point, _Digits));

   if(InpShowPanel)
      EventSetMillisecondTimer(1000);   // 1s clock — panel stays live with no ticks

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Shutdown                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hFast  != INVALID_HANDLE)
      IndicatorRelease(g_hFast);
   if(g_hSlow  != INVALID_HANDLE)
      IndicatorRelease(g_hSlow);
   if(g_hRSI   != INVALID_HANDLE)
      IndicatorRelease(g_hRSI);
   if(g_hATR   != INVALID_HANDLE)
      IndicatorRelease(g_hATR);
   if(g_hTrend != INVALID_HANDLE)
      IndicatorRelease(g_hTrend);
   if(g_hADX   != INVALID_HANDLE)
      IndicatorRelease(g_hADX);
   if(g_hMACD  != INVALID_HANDLE)
      IndicatorRelease(g_hMACD);

   EventKillTimer();
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ChartRedraw();

   PrintSummary();
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Timer — keeps the status panel live (1s) even when the market    |
//| is closed and no ticks are arriving.                             |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(InpShowPanel)
      PanelUpdate();
  }

//+------------------------------------------------------------------+
//| End-of-run breakdown. This is the answer to "why isn't it        |
//| trading" — a count per gate, not an impression.                  |
//+------------------------------------------------------------------+
void PrintSummary()
  {
   Print("======== Sentinal summary ========");
   PrintFormat("Bars evaluated: %I64d   Orders placed: %I64d", g_barsSeen, g_ordersPlaced);

   if(InpZeroLossRecovery)
      PrintFormat("Zero-loss ledger: %.2f postponed, %.2f repaid by winners.",
                  g_recoveryDebt, g_recoveryTotal);

   if(g_barsSeen == 0)
     {
      Print("No bars were evaluated at all. OnTick returned before the entry check on");
      Print("every tick, which means TradingReady() was false throughout: no connection,");
      Print("algo trading disabled, or the symbol was never tradeable.");
      Print("==================================");
      return;
     }

   for(int b = 0; b < BLK_COUNT; b++)
     {
      if(g_blockTally[b] == 0)
         continue;
      PrintFormat("  %-34s %6I64d bars (%.1f%%)",
                  BlockName(b), g_blockTally[b],
                  100.0 * (double)g_blockTally[b] / (double)g_barsSeen);
     }

   if(g_sizingSkips > 0)
      PrintFormat("  %-34s %6I64d times", "passed all gates, sizing refused", g_sizingSkips);

   Print("==================================");
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(InpUseRiskPercent && InpRiskPercent <= 0.0)
     { Print("Sentinal: InpRiskPercent must be > 0."); return(false); }
   if(!InpUseRiskPercent && InpFixedLots <= 0.0)
     { Print("Sentinal: InpFixedLots must be > 0."); return(false); }
   if(InpStopMode == STOP_DOLLAR && InpStopLossPoints <= 0)
     { Print("Sentinal: fixed stops need InpStopLossPoints > 0."); return(false); }
   if(InpStopMode == STOP_ATR && InpATRStopMult <= 0.0)
     { Print("Sentinal: InpATRStopMult must be > 0."); return(false); }
   if(InpMaxPositions < 1)
     { Print("Sentinal: InpMaxPositions must be >= 1."); return(false); }
   if(InpMaxRiskPercent > 0.0 && InpMaxRiskPercent < InpRiskPercent)
     { Print("Sentinal: InpMaxRiskPercent must be >= InpRiskPercent (it is a ceiling)."); return(false); }
   if(InpMaxTotalRiskPct > 0.0 && InpMaxTotalRiskPct < InpMaxRiskPercent)
      Print("Sentinal: warning — InpMaxTotalRiskPct is below the per-trade ceiling; "
            "some single trades will be rejected by the portfolio cap.");

   if(InpStrategy == STRAT_EMA_CROSS && InpFastEMA >= InpSlowEMA)
     { Print("Sentinal: InpFastEMA must be smaller than InpSlowEMA."); return(false); }
   if(InpStrategy == STRAT_RSI_REVERSION &&
      (InpRSIOversold <= 0 || InpRSIOverbought >= 100 || InpRSIOversold >= InpRSIOverbought))
     { Print("Sentinal: need 0 < oversold < overbought < 100."); return(false); }
   if(InpStrategy == STRAT_BREAKOUT && InpBreakoutBars < 2)
     { Print("Sentinal: InpBreakoutBars must be >= 2."); return(false); }

   if(InpUseTimeFilter && (InpStartHour < 0 || InpEndHour > 24 || InpStartHour >= InpEndHour))
     { Print("Sentinal: need 0 <= StartHour < EndHour <= 24."); return(false); }

   if(InpScaleToBalance && InpRefBalance <= 0.0)
     { Print("Sentinal: InpRefBalance must be > 0 when scaling to balance."); return(false); }

   if(InpUseMACD && (InpMACDFast >= InpMACDSlow || InpMACDFast < 1 || InpMACDSignal < 1))
     { Print("Sentinal: need 1 <= MACD fast < slow, and signal >= 1."); return(false); }

   if(InpUseInfiniteRR)
     {
      if(InpBreakevenAtR <= 0.0)
        { Print("Sentinal: InpBreakevenAtR must be > 0."); return(false); }
      if(InpTrailBars < 1)
        { Print("Sentinal: InpTrailBars must be >= 1."); return(false); }
      if(InpBEBufferR < 0.0)
        { Print("Sentinal: InpBEBufferR cannot be negative."); return(false); }
     }

   if(InpStopMode == STOP_DOLLAR)
     {
      if(InpInitialLot <= 0.0)
        { Print("Sentinal: InpInitialLot must be > 0."); return(false); }
      if(InpStopLossUSD <= 0.0)
        { Print("Sentinal: InpStopLossUSD must be > 0 in dollar-stop mode."); return(false); }
     }

   if(InpUseAdaptiveATR)
     {
      if(InpATRAdaptBars < 2)
        { Print("Sentinal: InpATRAdaptBars must be >= 2."); return(false); }
      if(InpATRScaleMin <= 0.0 || InpATRScaleMax < InpATRScaleMin)
        { Print("Sentinal: need 0 < InpATRScaleMin <= InpATRScaleMax."); return(false); }
     }

   if(InpZeroLossRecovery && InpRecoveryCover < 1.0)
     { Print("Sentinal: InpRecoveryCover must be >= 1.0."); return(false); }

   if(InpUseMartingale)
     {
      if(InpMartingaleMult < 1.0)
        { Print("Sentinal: InpMartingaleMult must be >= 1.0."); return(false); }
      if(InpMaxRecovery < 0)
        { Print("Sentinal: InpMaxRecovery cannot be negative."); return(false); }
      if(InpLossTriggerUSD < 0.0)
        { Print("Sentinal: InpLossTriggerUSD cannot be negative."); return(false); }
     }

   if(InpNewYorkOnly && (InpNYStartHour < 0 || InpNYStartHour > 23 ||
                         InpNYEndHour   < 1 || InpNYEndHour   > 24))
     { Print("Sentinal: NY hours must be 0-23 (start) and 1-24 (end)."); return(false); }

   return(true);
  }

//+------------------------------------------------------------------+
//| Indicator handles                                                |
//+------------------------------------------------------------------+
bool CreateIndicators()
  {
   switch(InpStrategy)
     {
      case STRAT_EMA_CROSS:
         g_hFast = iMA(_Symbol, PERIOD_CURRENT, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
         g_hSlow = iMA(_Symbol, PERIOD_CURRENT, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
         if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE)
           { Print("Sentinal: EMA handle failed. err=", GetLastError()); return(false); }
         break;

      case STRAT_RSI_REVERSION:
         g_hRSI = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE);
         if(g_hRSI == INVALID_HANDLE)
           { Print("Sentinal: RSI handle failed. err=", GetLastError()); return(false); }
         break;

      case STRAT_BREAKOUT:
         break;   // raw price data, no handle needed
     }

   if(InpStopMode == STOP_ATR || InpUseTrailingStop)
     {
      g_hATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
      if(g_hATR == INVALID_HANDLE)
        { Print("Sentinal: ATR handle failed. err=", GetLastError()); return(false); }
     }

   if(InpUseTrendFilter || InpAdaptiveTrendSL)
     {
      g_hTrend = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hTrend == INVALID_HANDLE)
        { Print("Sentinal: trend EMA handle failed. err=", GetLastError()); return(false); }
     }

   if(InpUseADX)
     {
      g_hADX = iADX(_Symbol, InpTrendTF, InpADXPeriod);
      if(g_hADX == INVALID_HANDLE)
        { Print("Sentinal: ADX handle failed. err=", GetLastError()); return(false); }
     }

   if(InpUseMACD)
     {
      g_hMACD = iMACD(_Symbol, PERIOD_CURRENT, InpMACDFast, InpMACDSlow,
                      InpMACDSignal, PRICE_CLOSE);
      if(g_hMACD == INVALID_HANDLE)
        { Print("Sentinal: MACD handle failed. err=", GetLastError()); return(false); }
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Momentum confirmation.                                           |
//|                                                                  |
//| An EMA cross says direction changed; it says nothing about        |
//| whether anything is behind the move. A rising MACD histogram is   |
//| momentum building, a falling one is a cross happening into a      |
//| fading move - which is where fast crosses on gold produce most    |
//| of their losers.                                                  |
//+------------------------------------------------------------------+
bool MomentumAgrees(const ESignal sig)
  {
   if(!InpUseMACD || g_hMACD == INVALID_HANDLE || sig == SIGNAL_NONE)
      return(true);

   double macdMain[], macdSig[];
   ArraySetAsSeries(macdMain, true);
   ArraySetAsSeries(macdSig,  true);

   int s = SignalShift();
   if(CopyBuffer(g_hMACD, 0, s, 2, macdMain) < 2) return(false);
   if(CopyBuffer(g_hMACD, 1, s, 2, macdSig)  < 2) return(false);

   double h0 = macdMain[0] - macdSig[0];   // histogram, bar being tested
   double h1 = macdMain[1] - macdSig[1];   // the bar before it

   return(sig == SIGNAL_BUY ? (h0 > h1) : (h0 < h1));
  }

//+------------------------------------------------------------------+
//| Infinite RR bookkeeping — one slot per open position             |
//+------------------------------------------------------------------+
int RRSlot(const ulong ticket, const double riskIfNew)
  {
   int freeSlot = -1;
   for(int i = 0; i < RR_SLOTS; i++)
     {
      if(g_rrTicket[i] == ticket)
         return(i);
      if(g_rrTicket[i] == 0 && freeSlot < 0)
         freeSlot = i;
     }
   if(freeSlot < 0 || riskIfNew <= 0.0)
      return(-1);

   g_rrTicket[freeSlot] = ticket;
   g_rrRisk[freeSlot]   = riskIfNew;
   g_rrBE[freeSlot]     = false;
   return(freeSlot);
  }

void RRRelease(const ulong ticket)
  {
   for(int i = 0; i < RR_SLOTS; i++)
      if(g_rrTicket[i] == ticket)
        {
         g_rrTicket[i] = 0;
         g_rrRisk[i]   = 0.0;
         g_rrBE[i]     = false;
        }
  }

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpShowPanel)
      PanelUpdate();

   // Track the Algo Trading switch on EVERY tick, before the trading
   // gate below. While Algo Trading is OFF, TradingReady() returns early
   // and would otherwise leave g_algoWasOn stuck at its old value, so an
   // OFF -> ON transition could never re-arm the instant start. Moved
   // here so the first tick after every switch-on evaluates the last
   // CLOSED bar immediately.
   bool algoOn = MQLInfoInteger(MQL_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   if(algoOn && !g_algoWasOn)
      g_armed = true;
   g_algoWasOn = algoOn;

   if(!TradingReady())
      return;

// Manage what is already open every tick, not just on new bars —
// trailing stops and reversals should not wait for a candle to close.
   ManageOpenPositions();
   CloseAllOnFloatingProfit();

   UpdateDailyTracking();
   UpdateRecoveryState();

   if(InpDailyProfitUSD > 0.0 && !g_dayHalted && g_dayStartBalance > 0.0)
     {
      double dayProfit = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBalance;
      double dayTarget = ScaledUSD(InpDailyProfitUSD);
      if(dayProfit >= dayTarget)
        {
         g_dayHalted = true;
         PrintFormat("Sentinal: daily profit target %.2f reached (%.2f). Done for today.",
                     dayTarget, dayProfit);
        }
     }

   if(InpTargetProfitPct > 0.0 && !g_halted && g_startBalance > 0.0)
     {
      double gainPct = (AccountInfoDouble(ACCOUNT_EQUITY) - g_startBalance)
                       / g_startBalance * 100.0;
      if(gainPct >= InpTargetProfitPct)
        {
         g_halted = true;
         PrintFormat("Sentinal: target +%.2f%% reached (%.2f%%). Halting new entries.",
                     InpTargetProfitPct, gainPct);
        }
     }
   bool newBar = IsNewBar();

   // In bar-close mode nothing is re-evaluated mid-candle: the signal is
   // read once per completed bar. g_armed is the one exception — it is
   // set when Algo Trading is switched on, so arming mid-candle gets an
   // immediate evaluation of the last CLOSED bar instead of waiting for
   // the next one. The Algo Trading state itself is tracked at the top of
   // OnTick, before the trading gate, so it is always current here.
   if(!InpIntrabarSignals)
     {
      if(!newBar && !g_armed)
         return;
      g_armed = false;
     }

// Work out whether this bar trades, and if not, exactly why. "Nothing
// is happening" is the normal state for a filtered strategy, so this
// has to distinguish that from something actually being broken. Note
// auto-trade being off is counted as a reason rather than an early
// return, so a monitor-only run still reports what it would have done.
   EBlock  blk    = BLK_ENTER;
   ESignal signal = SIGNAL_NONE;
   int     trend  = 0;

   if(!InpAutoTrade)
      blk = BLK_AUTOTRADE_OFF;
   else
      if(g_halted)
         blk = BLK_TARGET_HALT;
      else
         if(MaxTotalLossHit())
            blk = BLK_MAXLOSS;
         else
            if(!WithinNewYorkSession())
               blk = BLK_SESSION;
            else
               if(!WithinTradingHours())
                  blk = BLK_HOURS;
               else
                  if(DailyLossHit())
                     blk = BLK_DAILY_LOSS;
                  else
                     if(!SpreadAcceptable())
                        blk = BLK_SPREAD;
                     else
                        if(OpenPositionCount() >= InpMaxPositions)
                           blk = BLK_POSLIMIT;
                        else
                           if(InpMaxTotalRiskPct > 0.0 && OpenRiskPercent() >= InpMaxTotalRiskPct)
                              blk = BLK_TOTALRISK;
                           else
                             {
                              signal = Signal();
                              trend  = TrendDirection();

                              if(signal == SIGNAL_NONE)
                                 blk = BLK_NOSIGNAL;
                              else
                                 if((InpDirection == DIR_LONG_ONLY  && signal == SIGNAL_SELL) ||
                                    (InpDirection == DIR_SHORT_ONLY && signal == SIGNAL_BUY))
                                    blk = BLK_DIRECTION;
                                 else
                                    if(InpUseTrendFilter && trend == 0)
                                       blk = BLK_TREND_FLAT;
                                    else
                                       if(InpUseTrendFilter && trend != (int)signal)
                                          blk = BLK_TREND_OPPOSED;
                                       else
                                          if(!MomentumAgrees(signal))
                                             blk = BLK_MOMENTUM;
                             }

// Tally once per bar, so the summary's percentages stay per-bar and
// are not diluted by tick count in intrabar mode.
   if(newBar)
     {
      g_barsSeen++;
      g_blockTally[blk]++;
     }

   if(InpVerboseLog && newBar)
     {
      double atr = AdaptiveATR();
      PrintFormat("Sentinal bar %s | signal=%s trend=%s spread=%.0f atr=%.0f -> %s",
                  TimeToString(g_lastBar, TIME_DATE | TIME_MINUTES),
                  (signal == SIGNAL_BUY ? "BUY" : (signal == SIGNAL_SELL ? "SELL" : "none")),
                  (trend > 0 ? "up" : (trend < 0 ? "down" : "flat")),
                  CurrentSpreadPoints(),
                  (atr > 0.0 ? atr / _Point : 0.0),
                  BlockName(blk));
     }

   if(blk != BLK_ENTER)
      return;

// One entry per candle while the position opened on this candle is
// still open. Once it has closed (a closing deal newer than the last
// entry), a fresh signal may open another trade on the same candle —
// several positions can therefore be open at the same time.
   if(g_lastEntryBar == g_lastBar && LastCloseTime() <= g_lastEntryTime)
      return;                       // already entered on this candle

   OpenTrade(signal == SIGNAL_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   g_lastEntryBar = g_lastBar;
  }

//+------------------------------------------------------------------+
//| Trend direction: +1 up, -1 down, 0 undecided / not trending      |
//+------------------------------------------------------------------+
int TrendDirection()
  {
   if(!InpUseTrendFilter)
      return(0);

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_hTrend, 0, 0, 2, ema) < 2)
      return(0);

// ADX measures trend strength, not direction: a low reading means
// the market is ranging, where trend-following entries bleed.
   if(InpUseADX)
     {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(g_hADX, 0, 0, 2, adx) < 2)
         return(0);
      if(adx[0] < InpADXMin)
         return(0);
     }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      return(0);

   if(price > ema[0])
      return(1);
   if(price < ema[0])
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Higher-TF trend independent of the entry filter — used only to   |
//| adapt the stop so it never fights the trend. +1 up, -1 down,     |
//| 0 flat / undecided.                                              |
//+------------------------------------------------------------------+
int HigherTFTrend()
  {
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_hTrend, 0, 0, 2, ema) < 2)
      return(0);

   if(InpUseADX)
     {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(g_hADX, 0, 0, 2, adx) < 2)
         return(0);
      if(adx[0] < InpADXMin)
         return(0);
     }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      return(0);

   if(price > ema[0])
      return(1);
   if(price < ema[0])
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Stop multiplier from the trend. Trading WITH the trend gets more |
//| room so ordinary pullbacks don't stop the trade before it has    |
//| reached positive floating P/L; against the trend it tightens.    |
//+------------------------------------------------------------------+
double TrendSLFactor(const int signalDir)
  {
   if(!InpAdaptiveTrendSL)
      return(1.0);

   int trend = HigherTFTrend();
   if(trend == 0)
      return(1.0);

// Strategy-aware: trend-following entries need room to RUN with the
// trend; mean-reversion entries (RSI) need room to BOUNCE against it.
   bool withTrend = (trend == signalDir);
   bool widen     = (InpStrategy == STRAT_RSI_REVERSION) ? !withTrend : withTrend;

   if(widen)
      return(MathMax(InpTrendSLWiden, 1.0));

// Floored at 0.1: this multiplies the stop distance, so a tighten value
// of 0 would collapse the stop to zero and every entry would be rejected
// with "could not convert $ stop into a price distance" - a silent, total
// block from one innocuous-looking setting.
   return(MathMax(MathMin(InpTrendSLTighten, 1.0), 0.1));
  }

//| Entry signals — all read CLOSED candles only                     |
//+------------------------------------------------------------------+
ESignal Signal()
  {
   switch(InpStrategy)
     {
      case STRAT_EMA_CROSS:
         return(SignalEmaCross());
      case STRAT_RSI_REVERSION:
         return(SignalRsiReversion());
      case STRAT_BREAKOUT:
         return(SignalBreakout());
     }
   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| Which bar the rules read. 1 = the last CLOSED candle (settled,   |
//| a signal here can never be taken back). 0 = the candle currently |
//| forming, which reacts instantly but can change its mind on the   |
//| next tick.                                                       |
//+------------------------------------------------------------------+
int SignalShift()
  {
   return(InpIntrabarSignals ? 0 : 1);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ESignal SignalEmaCross()
  {
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   int s = SignalShift();
   if(CopyBuffer(g_hFast, 0, s, 2, fast) < 2)
      return(SIGNAL_NONE);
   if(CopyBuffer(g_hSlow, 0, s, 2, slow) < 2)
      return(SIGNAL_NONE);

   if(fast[1] <= slow[1] && fast[0] > slow[0])
      return(SIGNAL_BUY);
   if(fast[1] >= slow[1] && fast[0] < slow[0])
      return(SIGNAL_SELL);
   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ESignal SignalRsiReversion()
  {
   double rsi[];
   ArraySetAsSeries(rsi, true);

   int s = SignalShift();
   if(CopyBuffer(g_hRSI, 0, s, 2, rsi) < 2)
      return(SIGNAL_NONE);

   if(rsi[1] <  InpRSIOversold   && rsi[0] >= InpRSIOversold)
      return(SIGNAL_BUY);
   if(rsi[1] >  InpRSIOverbought && rsi[0] <= InpRSIOverbought)
      return(SIGNAL_SELL);
   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ESignal SignalBreakout()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);

   int s    = SignalShift();
   int need = InpBreakoutBars + s + 2;
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, need, r) < need)
      return(SIGNAL_NONE);

// Range excludes the bar being tested, so its close is measured
// against a range it did not help form.
   double hi = r[s + 1].high, lo = r[s + 1].low;
   for(int i = s + 2; i <= s + InpBreakoutBars; i++)
     {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }

   if(r[s].close > hi)
      return(SIGNAL_BUY);
   if(r[s].close < lo)
      return(SIGNAL_SELL);
   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| Adaptive ATR.                                                    |
//|                                                                  |
//| The raw ATR is scaled by how the current reading compares with   |
//| its own recent average: in a calm regime the scale drops below 1 |
//| and stops tighten, while in an expanding-volatility regime it    |
//| rises above 1 and stops widen ahead of the noise. The scale is   |
//| clamped so one freak bar can never produce a degenerate stop.    |
//+------------------------------------------------------------------+
double AdaptiveATR()
  {
   double atr = CurrentATR();
   if(atr <= 0.0)
      return(0.0);

   if(!InpUseAdaptiveATR || InpATRAdaptBars < 2)
      return(atr);

   double vals[];
   ArraySetAsSeries(vals, true);
   int n = InpATRAdaptBars;
   if(CopyBuffer(g_hATR, 0, 1, n, vals) < n)
      return(atr);

   double sum = 0.0;
   for(int i = 0; i < n; i++)
      sum += vals[i];
   double mean = sum / (double)n;
   if(mean <= 0.0)
      return(atr);

   double scale = atr / mean;
   scale = MathMax(InpATRScaleMin, MathMin(InpATRScaleMax, scale));

   return(atr * scale);
  }

//+------------------------------------------------------------------+
//| Current ATR in price terms                                       |
//+------------------------------------------------------------------+
double CurrentATR()
  {
   if(g_hATR == INVALID_HANDLE)
      return(0.0);

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1)
      return(0.0);

   return(atr[0]);
  }

//+------------------------------------------------------------------+
//| Stop / target distances in price, adapted to live volatility     |
//+------------------------------------------------------------------+
bool StopDistances(double &stopDist, double &targetDist)
  {
   if(InpStopMode == STOP_ATR)
     {
      double atr = AdaptiveATR();
      if(atr <= 0.0)
        {
         Print("Sentinal: ATR unavailable; skipping entry.");
         return(false);
        }
      stopDist   = atr * InpATRStopMult;
      targetDist = atr * InpATRTargetMult;
     }
   else
     {
      stopDist   = InpStopLossPoints   * _Point;
      targetDist = InpTakeProfitPoints * _Point;
     }

// Respect the broker's minimum stop distance by widening, not by
// abandoning the trade.
   double minDist = MinStopDistance();
   if(stopDist   < minDist)
      stopDist   = minDist;
   if(targetDist > 0.0 && targetDist < minDist)
      targetDist = minDist;

   return(stopDist > 0.0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   long stopLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLvl  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long lvl        = MathMax(stopLevel, freezeLvl);
   double spread   = SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                     SymbolInfoDouble(_Symbol, SYMBOL_BID);

// A stop inside the spread is hit the instant it is placed.
   return(MathMax(lvl * _Point, spread * 2.0));
  }

//+------------------------------------------------------------------+
//| Money risked per lot over a given price distance                 |
//+------------------------------------------------------------------+
double MoneyPerLot(const double priceDist)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || priceDist <= 0.0)
      return(0.0);
   return((priceDist / tickSize) * tickValue);
  }

//+------------------------------------------------------------------+
//| Combined risk of everything currently open, as % of balance      |
//+------------------------------------------------------------------+
double OpenRiskPercent()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return(0.0);

   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Symbol() != _Symbol || position.Magic() != InpMagicNumber)
         continue;

      double sl = position.StopLoss();
      if(sl <= 0.0)
         continue;
      total += MoneyPerLot(MathAbs(position.PriceOpen() - sl)) * position.Volume();
     }

   return(total / balance * 100.0);
  }

//+------------------------------------------------------------------+
//| Position sizing — everything scales off the LIVE balance, so the |
//| same settings stay correct as the account grows or shrinks.      |
//+------------------------------------------------------------------+
double CalculateLots(const double stopDist)
  {
   if(!InpUseRiskPercent)
      return(NormalizeLots(InpFixedLots));

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return(0.0);

   double lossPerLot = MoneyPerLot(stopDist);
   if(lossPerLot <= 0.0)
     {
      Print("Sentinal: cannot size by risk (bad tick value/size).");
      return(0.0);
     }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lots   = (balance * InpRiskPercent / 100.0) / lossPerLot;

   if(lots < minLot)
     {
      // The smallest tradeable position risks more than the target. Take
      // it only while that stays under the ceiling — which is itself a
      // percentage, so this constraint dissolves as the balance grows
      // and tightens automatically if the account draws down.
      double minLotPct = lossPerLot * minLot / balance * 100.0;

      if(InpMaxRiskPercent <= 0.0 || minLotPct > InpMaxRiskPercent)
        {
         PrintFormat("Sentinal: min lot %.2f risks %.2f%% of %.2f (target %.2f%%, ceiling %.2f%%). Skipped.",
                     minLot, minLotPct, balance, InpRiskPercent, InpMaxRiskPercent);
         return(0.0);
        }

      PrintFormat("Sentinal: min lot %.2f risks %.2f%% vs %.2f%% target — within the %.2f%% ceiling, taking it.",
                  minLot, minLotPct, InpRiskPercent, InpMaxRiskPercent);
      lots = minLot;
     }

   return(NormalizeLots(lots));
  }

//+------------------------------------------------------------------+
//| Convert a dollar risk into a price distance for a given lot size |
//+------------------------------------------------------------------+
double UsdToPriceDist(const double usd, const double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || lots <= 0.0 || usd <= 0.0)
      return(0.0);
   return((usd * tickSize) / (tickValue * lots));
  }

//+------------------------------------------------------------------+
//| Recovery risk in account currency.                               |
//|                                                                  |
//| Normally one trade risks the $ stop amount (scaled with the      |
//| balance). While the zero-loss ledger is open, the risk grows so  |
//| a single winning trade repays the whole postponed loss — the     |
//| classic "one winner erases the streak" recovery, capped by the   |
//| per-trade risk ceiling so the ladder can never go exponential.   |
//+------------------------------------------------------------------+
double RecoveryRiskUSD()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return(0.0);

   double riskUSD = ScaledUSD(InpStopLossUSD);
   if(InpZeroLossRecovery && g_recoveryDebt > 0.0)
     {
      double coverRisk = g_recoveryDebt *
                         (InpStopLossUSD / MathMax(InpTakeProfitUSD, 0.01)) *
                         InpRecoveryCover;
      riskUSD = MathMax(riskUSD, coverRisk);
     }

   double riskCap = balance * InpMaxRiskPercent / 100.0;
   if(riskUSD > riskCap)
      riskUSD = riskCap;
   return(riskUSD);
  }

//+------------------------------------------------------------------+
//| Order execution                                                  |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type)
  {
   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      return;

   double stopDist = 0.0, targetDist = 0.0, lots = 0.0;

// Trend-adaptive stop: with the trend the stop widens so normal
// pullbacks can't stop the trade before floating P/L turns positive.
   int    signalDir   = (type == ORDER_TYPE_BUY) ? 1 : -1;
   double trendFactor = TrendSLFactor(signalDir);

   if(InpStopMode == STOP_DOLLAR)
     {
      // Capital-adaptive sizing: the $ risk scales with the account and,
      // during an active recovery, with the postponed-loss ledger, so one
      // winning trade can clear the whole debt. The lot follows the risk.
      double riskUSD = RecoveryRiskUSD();
      if(riskUSD <= 0.0)
        {
         g_sizingSkips++;
         return;
        }

      // Price shape: the $ stop expressed at the base lot. The lot then
      // scales with the risk so the money at risk stays exact at any lot.
      double baseStop = UsdToPriceDist(ScaledUSD(InpStopLossUSD), InpInitialLot) * trendFactor;
      if(baseStop <= 0.0)
        {
         Print("Sentinal: could not convert $ stop into a price distance.");
         g_sizingSkips++;
         return;
        }

      lots = NormalizeLots(riskUSD / MoneyPerLot(baseStop));
      if(lots <= 0.0)
        {
         g_sizingSkips++;
         return;
        }

      // SL/TP distances adapt to the ACTUAL lot: the $ amount at risk —
      // and the $ target, at the same reward/risk ratio — stays the same
      // whether the lot is 0.01 or 0.50. Bigger lots, same $ risk.
      stopDist   = UsdToPriceDist(riskUSD, lots);
      targetDist = UsdToPriceDist(riskUSD * (InpTakeProfitUSD /
                                             MathMax(InpStopLossUSD, 0.01)), lots);

      double minDist = MinStopDistance();
      if(stopDist   < minDist)
         stopDist   = minDist;
      if(targetDist > 0.0 && targetDist < minDist)
         targetDist = minDist;
     }
   else
     {
      if(!StopDistances(stopDist, targetDist))
         return;
      stopDist *= trendFactor;
      lots = CalculateLots(stopDist);

      // Recovery scaling in ATR mode: while the ledger is open the lot
      // grows so one winning trade can clear the postponed losses.
      if(InpZeroLossRecovery && g_recoveryDebt > 0.0)
        {
         double cover  = RecoveryRiskUSD();
         double perLot = MoneyPerLot(stopDist);
         if(perLot > 0.0 && cover > ScaledUSD(InpStopLossUSD))
            lots = NormalizeLots(cover / perLot);
        }

      // Keep the martingale ladder working in ATR mode too.
      if(InpUseMartingale && g_recoveryStep > 0)
         lots = NormalizeLots(lots * MathPow(InpMartingaleMult, g_recoveryStep));
     }

// The trend factor can shrink a stop below the broker minimum —
// widen it back, never abandon the trade.
   double trendMin = MinStopDistance();
   if(stopDist < trendMin)
      stopDist = trendMin;

   double sl = (type == ORDER_TYPE_BUY) ? price - stopDist : price + stopDist;

   // Infinite RR runs without a fixed target: the trade is secured at
   // breakeven and then trailed, so a winner is closed by the market
   // running out rather than by a ceiling set at entry.
   double tp = 0.0;
   if(targetDist > 0.0 && !InpUseInfiniteRR)
      tp = (type == ORDER_TYPE_BUY) ? price + targetDist : price - targetDist;

   sl = NormalizeDouble(sl, _Digits);
   tp = (tp > 0.0) ? NormalizeDouble(tp, _Digits) : 0.0;

   if(lots <= 0.0)
     {
      g_sizingSkips++;
      return;
     }

// Portfolio cap: one trade may be within its own limit and still take
// the account's combined exposure past what it can absorb.
   if(InpMaxTotalRiskPct > 0.0)
     {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > 0.0)
        {
         double newRiskPct = MoneyPerLot(stopDist) * lots / balance * 100.0;
         double projected  = OpenRiskPercent() + newRiskPct;
         if(projected > InpMaxTotalRiskPct)
           {
            PrintFormat("Sentinal: entry would take combined open risk to %.2f%% (cap %.2f%%). Skipped.",
                        projected, InpMaxTotalRiskPct);
            return;
           }
        }
     }

   if(!MarginSufficient(type, lots, price))
      return;

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "Sentinal")
             : trade.Sell(lots, _Symbol, 0.0, sl, tp, "Sentinal");

   if(!ok)
      PrintFormat("Sentinal: order failed. retcode=%d (%s)",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else
     {
      g_ordersPlaced++;
      g_lastEntryTime = TimeCurrent();
      PrintFormat("Sentinal: %s %.2f lots @ %s  SL=%s TP=%s  (stop %.0f pts, risk %.2f)",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots,
                  DoubleToString(trade.ResultPrice(), _Digits),
                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
                  stopDist / _Point, MoneyPerLot(stopDist) * lots);
     }
  }

//+------------------------------------------------------------------+
//| Martingale state + zero-loss ledger.                             |
//|                                                                  |
//| Every closing deal is fed into the ledger first: losses are      |
//| postponed (added to the debt), wins repay the debt before they   |
//| count as profit. The recovery stays elevated until the ledger is |
//| fully cleared — that is what makes the recovery "zero-loss".     |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Blackbox journal: one row per closed deal, with the context that  |
//| produced it. Post-mortem is impossible without this - the MT5     |
//| history shows what happened, not what the bot believed at entry.  |
//+------------------------------------------------------------------+
void JournalDeal(const ulong dealTicket, const double net)
  {
   if(!InpWriteJournal)
      return;

   int h = FileOpen("Sentinal_journal.csv",
                    FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
      return;

   FileSeek(h, 0, SEEK_END);
   if(FileSize(h) == 0)
      FileWrite(h, "close_time", "symbol", "type", "volume", "price",
                "net", "balance", "equity", "recovery_step", "debt",
                "spread_pts", "atr_pts", "strategy", "intrabar");

   double atr = AdaptiveATR();
   FileWrite(h,
             TimeToString((datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME),
                          TIME_DATE | TIME_SECONDS),
             HistoryDealGetString(dealTicket, DEAL_SYMBOL),
             (HistoryDealGetInteger(dealTicket, DEAL_TYPE) == DEAL_TYPE_BUY ? "buy" : "sell"),
             DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_VOLUME), 2),
             DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_PRICE), _Digits),
             DoubleToString(net, 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             IntegerToString(g_recoveryStep),
             DoubleToString(g_recoveryDebt, 2),
             DoubleToString(CurrentSpreadPoints(), 0),
             DoubleToString((atr > 0.0 ? atr / _Point : 0.0), 0),
             EnumToString(InpStrategy),
             (InpIntrabarSignals ? "yes" : "no"));

   FileClose(h);
  }

void UpdateRecoveryState()
  {
   // The journal and the RR slot release both ride on this deal scan, so
   // it has to run even when neither recovery mode is active.
   if(!InpUseMartingale && !InpZeroLossRecovery && !InpWriteJournal && !InpUseInfiniteRR)
      return;

   if(!HistorySelect(g_lastDealTime, TimeCurrent() + 60))
      return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      datetime dt = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(dt <= g_lastDealTime)
         continue;
      g_lastDealTime = dt;

      double net = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                   + HistoryDealGetDouble(ticket, DEAL_SWAP)
                   + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      // The position is gone: free its Infinite RR slot and record it.
      RRRelease((ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID));
      JournalDeal(ticket, net);

      // Zero-loss ledger: postpone losses, repay with profits.
      if(InpZeroLossRecovery)
        {
         if(net < 0.0)
           {
            g_recoveryDebt += -net;
            if(g_recoveryStep < InpMaxRecovery)
               g_recoveryStep++;
            PrintFormat("Sentinal: loss %.2f postponed — ledger %.2f (step %d).",
                        net, g_recoveryDebt, g_recoveryStep);
           }
         else
            if(net > 0.0 && g_recoveryDebt > 0.0)
              {
               g_recoveryDebt = MathMax(0.0, g_recoveryDebt - net);
               if(g_recoveryDebt <= 0.0)
                 {
                  g_recoveryTotal += net;
                  PrintFormat("Sentinal: zero-loss recovery complete — %.2f profit "
                              "cleared the ledger. Equity back to flat.",
                              net);
                  g_recoveryStep = 0;
                 }
               else
                 {
                  PrintFormat("Sentinal: %.2f repaid — ledger %.2f remains.",
                              net, g_recoveryDebt);
                  g_recoveryStep = InpMaxRecovery;
                 }
              }
            else
               if(net > 0.0)
                  g_recoveryStep = 0;
         continue;
        }

      // Legacy martingale ladder (only when zero-loss recovery is off).
      if(net < -ScaledUSD(InpLossTriggerUSD))
        {
         if(g_recoveryStep < InpMaxRecovery)
           {
            g_recoveryStep++;
            PrintFormat("Sentinal: loss %.2f -> recovery step %d of %d (next lot x%.2f).",
                        net, g_recoveryStep, InpMaxRecovery,
                        MathPow(InpMartingaleMult, g_recoveryStep));
           }
         else
           {
            PrintFormat("Sentinal: loss %.2f at max recovery (%d). Ladder reset to base lot.",
                        net, InpMaxRecovery);
            g_recoveryStep = 0;
           }
        }
      else
         if(net > 0.0)
           {
            if(g_recoveryStep > 0)
               PrintFormat("Sentinal: win %.2f — recovery ladder reset.", net);
            g_recoveryStep = 0;
           }
     }
  }

//+------------------------------------------------------------------+
//| Balance scaling.                                                 |
//|                                                                  |
//| The dollar settings describe a shape, not an amount: $2 risked to |
//| make $1 on a $1000 account is 0.2% to make 0.1%. Multiplying the  |
//| LOT by balance/reference keeps those percentages constant at any  |
//| account size, while the price distances - derived from the        |
//| unscaled reference pair - stay exactly where they were, so the    |
//| bot goes on trading the same shape of move it always did.         |
//+------------------------------------------------------------------+
double BalanceFactor()
  {
   if(!InpScaleToBalance || InpRefBalance <= 0.0)
      return(1.0);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return(1.0);

   return(balance / InpRefBalance);
  }

// A dollar setting expressed at the live balance.
double ScaledUSD(const double usd)
  {
   return(usd * BalanceFactor());
  }

// The base lot before any martingale escalation.
double BaseLot()
  {
   return(NormalizeLots(InpInitialLot * BalanceFactor()));
  }

//+------------------------------------------------------------------+
//| Lot size for the fixed-lot / martingale path                     |
//+------------------------------------------------------------------+
double MartingaleLots()
  {
   double lots = BaseLot();
   if(InpUseMartingale && g_recoveryStep > 0)
      lots = BaseLot() * MathPow(InpMartingaleMult, g_recoveryStep);
   return(NormalizeLots(lots));
  }

//+------------------------------------------------------------------+
//| Total loss guard, measured against the balance at attach         |
//+------------------------------------------------------------------+
bool MaxTotalLossHit()
  {
   if(InpMaxLossPctBal <= 0.0 || g_startBalance <= 0.0)
      return(false);

   double changePct = (AccountInfoDouble(ACCOUNT_EQUITY) - g_startBalance)
                      / g_startBalance * 100.0;
   return(changePct <= -InpMaxLossPctBal);
  }

//+------------------------------------------------------------------+
//| New York session, checked against GMT rather than server time,   |
//| so the window is correct on any broker without calibration. The  |
//| panel translates it to the local clock. (In the Strategy Tester  |
//| GMT is approximated from server time, so backtests may sit a     |
//| couple of hours off — live trading is exact.)                    |
//+------------------------------------------------------------------+
bool WithinNewYorkSession()
  {
   if(!InpNewYorkOnly)
      return(true);

   MqlDateTime t;
   TimeToStruct(TimeGMT(), t);

   if(InpNYStartHour <= InpNYEndHour)
      return(t.hour >= InpNYStartHour && t.hour < InpNYEndHour);

// Window wraps past midnight.
   return(t.hour >= InpNYStartHour || t.hour < InpNYEndHour);
  }

//+------------------------------------------------------------------+
//| Daily loss limit, rebased to balance at the start of each day    |
//+------------------------------------------------------------------+
void UpdateDailyTracking()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0;
   t.min = 0;
   t.sec = 0;
   datetime today = StructToTime(t);

   if(today != g_dayStamp)
     {
      g_dayStamp        = today;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dayHalted       = false;
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool DailyLossHit()
  {
   if(InpMaxDailyLossPct <= 0.0 || g_dayStartBalance <= 0.0)
      return(false);
   if(g_dayHalted)
      return(true);

   double change = (AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBalance)
                   / g_dayStartBalance * 100.0;

   if(change <= -InpMaxDailyLossPct)
     {
      g_dayHalted = true;
      PrintFormat("Sentinal: daily loss limit hit (%.2f%% of %.2f). No new entries today.",
                  change, g_dayStartBalance);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0.0)
      lotStep = 0.01;

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   int lotDigits = (int)MathMax(0, MathRound(-MathLog10(lotStep)));
   return(NormalizeDouble(lots, lotDigits));
  }

//+------------------------------------------------------------------+
//| Reject the order before the broker does                          |
//+------------------------------------------------------------------+
bool MarginSufficient(const ENUM_ORDER_TYPE type, const double lots, const double price)
  {
   double required = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, required))
     {
      Print("Sentinal: OrderCalcMargin failed. err=", GetLastError());
      return(false);
     }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(required > freeMargin)
     {
      PrintFormat("Sentinal: not enough free margin (need %.2f, have %.2f).",
                  required, freeMargin);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Manage open positions: reversal exit, then trailing stop         |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   int trend = TrendDirection();
   double atr = (InpUseTrailingStop ? AdaptiveATR() : 0.0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Symbol() != _Symbol || position.Magic() != InpMagicNumber)
         continue;

      bool isBuy = (position.PositionType() == POSITION_TYPE_BUY);
      int  dir   = isBuy ? 1 : -1;

      // Trend flipped against an open trade — exit rather than sit
      // through it waiting for the stop.
      if(InpCloseOnReverse && InpUseTrendFilter && trend != 0 && trend != dir)
        {
         if(trade.PositionClose(position.Ticket()))
            PrintFormat("Sentinal: closed #%I64u on trend reversal.", position.Ticket());
         else
            PrintFormat("Sentinal: failed to close #%I64u. retcode=%d",
                        position.Ticket(), trade.ResultRetcode());
         continue;
        }

      // ---- Infinite RR: breakeven first, then run behind the bars ----
      if(InpUseInfiniteRR)
        {
         double entry = position.PriceOpen();
         double curSL = position.StopLoss();
         double cur   = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         int slot = RRSlot(position.Ticket(),
                           (curSL > 0.0 ? MathAbs(entry - curSL) : 0.0));
         if(slot < 0)
            continue;                       // no risk recorded, nothing to measure against

         double R          = g_rrRisk[slot];
         double profitDist = isBuy ? cur - entry : entry - cur;

         // Phase 1 — secure the trade at breakeven plus a buffer.
         if(!g_rrBE[slot] && profitDist >= InpBreakevenAtR * R)
           {
            double be = isBuy ? entry + InpBEBufferR * R
                              : entry - InpBEBufferR * R;
            be = NormalizeDouble(be, _Digits);

            bool ok = isBuy ? (be < cur && (curSL <= 0.0 || be > curSL))
                            : (be > cur && (curSL <= 0.0 || be < curSL));
            if(ok && trade.PositionModify(position.Ticket(), be, position.TakeProfit()))
              {
               g_rrBE[slot] = true;
               PrintFormat("Sentinal: #%I64u to breakeven at %.1fR (SL %s).",
                           position.Ticket(), InpBreakevenAtR,
                           DoubleToString(be, _Digits));
              }
           }

         // Phase 2 — moon run: trail behind the recent bars' extreme.
         if(g_rrBE[slot])
           {
            MqlRates r[];
            ArraySetAsSeries(r, true);
            int need = MathMax(InpTrailBars, 1) + 2;
            if(CopyRates(_Symbol, PERIOD_CURRENT, 0, need, r) >= need)
              {
               double ext = isBuy ? r[1].low : r[1].high;
               for(int k = 2; k <= MathMax(InpTrailBars, 1); k++)
                  ext = isBuy ? MathMin(ext, r[k].low) : MathMax(ext, r[k].high);

               double newSL  = NormalizeDouble(ext, _Digits);
               double minGap = MinStopDistance();
               bool   valid  = isBuy ? (newSL < cur - minGap && newSL > curSL)
                                     : (newSL > cur + minGap && newSL < curSL);
               if(valid)
                  trade.PositionModify(position.Ticket(), newSL, position.TakeProfit());
              }
           }
         continue;                          // Infinite RR supersedes the $ trail
        }

      if(!InpUseTrailingStop)
         continue;

      // The trail is denominated the same way the stop is. In dollar
      // mode the $ trail amount is scaled to the ACTUAL position volume,
      // so a 0.05 lot trade trails differently from a 0.20 lot trade.
      double trailDist, startDist;
      if(InpStopMode == STOP_DOLLAR)
        {
         trailDist = UsdToPriceDist(ScaledUSD(InpTrailDistUSD),  position.Volume());
         startDist = UsdToPriceDist(ScaledUSD(InpTrailStartUSD), position.Volume());
        }
      else
        {
         if(atr <= 0.0)
            continue;
         trailDist = atr * InpATRTrailMult;
         startDist = 0.0;
        }
      trailDist = MathMax(trailDist, MinStopDistance());

      double current = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                       : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // Only start trailing once the trade is far enough into profit.
      double profitDist = isBuy ? current - position.PriceOpen()
                          : position.PriceOpen() - current;
      if(profitDist < startDist)
         continue;

      double newSL = isBuy ? current - trailDist : current + trailDist;
      newSL = NormalizeDouble(newSL, _Digits);

      double oldSL = position.StopLoss();

      // Only ever tighten, never loosen — so trailing can reduce the risk
      // on a trade but never widen it beyond the original stop. The stop
      // must also stay on the correct side of the current price.
      bool improves = isBuy
                      ? (newSL < current && (oldSL <= 0.0 || newSL > oldSL))
                      : (newSL > current && (oldSL <= 0.0 || newSL < oldSL));

      if(!improves)
         continue;

      // Skip micro-adjustments; every modify is a server round trip.
      if(oldSL > 0.0 && MathAbs(newSL - oldSL) < MinStopDistance())
         continue;

      if(!trade.PositionModify(position.Ticket(), newSL, position.TakeProfit()))
         PrintFormat("Sentinal: trail modify failed on #%I64u. retcode=%d",
                     position.Ticket(), trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Close ALL open trades the moment combined floating P/L on this   |
//| symbol turns positive. TP is irrelevant: a portfolio in profit   |
//| is banked immediately instead of waiting for any single target.  |
//+------------------------------------------------------------------+
void CloseAllOnFloatingProfit()
  {
   if(!InpCloseAllOnProfit)
      return;

   double floating    = 0.0;
   double totalVolume = 0.0;
   int    count    = 0;
   ulong  tickets[];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totalVolume += PositionGetDouble(POSITION_VOLUME);
      count++;
      ArrayResize(tickets, count);
      tickets[count - 1] = ticket;
     }

   if(count == 0 || floating <= 0.0)

      return;

// Scalper rule: never bank noise. The profit must clear the fixed
// minimum AND the current spread cost of the open volume, so a
// sudden spread widening cannot turn the exit into a loss.
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ctr  = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), 0.0);
   double spreadCost = (ask - bid) * totalVolume * ctr;
   double minProfit  = MathMax(InpCloseAllMinUSD, spreadCost);
   if(floating < minProfit)
      return;

   PrintFormat("Sentinal: total floating P/L +%.2f >= %.2f — closing all %d positions now (TP not required).",
               floating, minProfit, count);
   for(int i = 0; i < count; i++)
     {
      if(!trade.PositionClose(tickets[i]))
         PrintFormat("Sentinal: failed to close #%I64u. retcode=%d",
                     tickets[i], trade.ResultRetcode());
     }
  }

//| Guards                                                           |
//+------------------------------------------------------------------+
bool TradingReady()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return(false);
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return(false);
   if(!MarketOpen())
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Gold trades nearly around the clock but still has a daily break. |
//| Full trade mode plus a fresh tick is the reliable test.          |
//+------------------------------------------------------------------+
bool MarketInBreak(const datetime t)
  {
   if(!InpUseMarketBreak)
      return(false);

   MqlDateTime dt;
   TimeToStruct(t, dt);
   int nowMin = dt.hour * 60 + dt.min;
   int start  = InpBreakStartHour * 60 + InpBreakStartMin;
   int end    = InpBreakEndHour   * 60 + InpBreakEndMin;

// The window wraps past midnight (23:50 -> 01:10). Equal start/end
// means "no break", so a mistyped value can never close the market 24/7.
   if(start == end)
      return(false);
   if(start < end)
      return(nowMin >= start && nowMin < end);
   return(nowMin >= start || nowMin < end);
  }

bool MarketOpen()
  {
   // Daily maintenance break: gold halts 23:50 - 01:10 local. The broker
   // can still stream quotes through the halt, so the symbol check below
   // alone cannot tell "closed" from "open".
   if(InpUseMarketBreak && MarketInBreak(TimeLocal()))
      return(false);

   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode != SYMBOL_TRADE_MODE_FULL && mode != SYMBOL_TRADE_MODE_LONGONLY &&
      mode != SYMBOL_TRADE_MODE_SHORTONLY)
      return(false);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return(false);
   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool WithinTradingHours()
  {
   if(!InpUseTimeFilter)
      return(true);

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return(t.hour >= InpStartHour && t.hour < InpEndHour);
  }

//+------------------------------------------------------------------+
//| Spread filter.                                                   |
//|                                                                  |
//| An absolute point limit is broker-specific: gold quotes at 2 or  |
//| 3 digits depending on the broker, so the same 26c spread reads   |
//| as 26 points on one and 260 on another. The ATR-relative test    |
//| is the one that actually means something — a spread that is a    |
//| large fraction of the current range eats the trade regardless    |
//| of what the absolute number looks like.                          |
//+------------------------------------------------------------------+
bool SpreadAcceptable()
  {
   double spreadPts = CurrentSpreadPoints();

   if(InpMaxSpreadPoints > 0 && spreadPts > InpMaxSpreadPoints)
      return(false);

   if(InpMaxSpreadATR > 0.0)
     {
      double atr = AdaptiveATR();
      if(atr > 0.0 && (spreadPts * _Point) > (atr * InpMaxSpreadATR))
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CurrentSpreadPoints()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(_Point <= 0.0)
      return(0.0);
   return((ask - bid) / _Point);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int OpenPositionCount()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Symbol() == _Symbol && position.Magic() == InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Time of the most recent closing deal for this symbol, or 0.      |
//| Used to let a new entry open on the same candle once the trade   |
//| that started there has already been closed.                      |
//+------------------------------------------------------------------+
datetime LastCloseTime()
  {
   if(!HistorySelect(0, TimeCurrent() + 60))
      return(0);

   datetime t = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0)
         continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      break;
     }
   return(t);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime thisBar = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
   if(thisBar == g_lastBar)
      return(false);
   g_lastBar = thisBar;
   return(true);
  }

//+------------------------------------------------------------------+
//| Status panel — every value read straight from the terminal       |
//+------------------------------------------------------------------+
void PanelUpdate()
  {
   bool connected = TerminalInfoInteger(TERMINAL_CONNECTED);
   bool expertsOn = MQLInfoInteger(MQL_TRADE_ALLOWED) &&
                    AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) &&
                    AccountInfoInteger(ACCOUNT_TRADE_EXPERT);

   string state;
   color stateColor;
   if(!connected)
     {
      state = "DISCONNECTED";
      stateColor = clrOrangeRed;
     }
   else
      if(!MarketOpen())
        {
         state = "MARKET CLOSED";
         stateColor = clrGold;
        }
      else
         if(g_halted)
           {
            state = "HALTED (target)";
            stateColor = clrGold;
           }
         else
            if(g_dayHalted)
              {
               state = "HALTED (daily loss)";
               stateColor = clrOrangeRed;
              }
            else
               if(!expertsOn)
                 {
                  state = "TRADING BLOCKED (algo OFF)";
                  stateColor = clrOrangeRed;
                 }
               else
                  if(!InpAutoTrade)
                    {
                     state = "MONITOR ONLY";
                     stateColor = clrGold;
                    }
                  else
                    {
                     state = "LIVE";
                     stateColor = clrLime;
                    }

   int trend = TrendDirection();
   string trendText = !InpUseTrendFilter ? "off"
                      : (trend > 0 ? "UP" : (trend < 0 ? "DOWN" : "ranging / weak"));

   double rawAtr   = CurrentATR();
   double atr      = AdaptiveATR();
   double atrScale = (InpUseAdaptiveATR && rawAtr > 0.0) ? atr / rawAtr : 1.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   int row = 0;
   PanelLine(row++, "Sentinal",  stateColor, state);
   PanelLine(row++, "Server",    InpPanelColor, AccountInfoString(ACCOUNT_SERVER));
   PanelLine(row++, "Account",   InpPanelColor,
             IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "  " +
             AccountInfoString(ACCOUNT_CURRENCY) +
             (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO
              ? "  [DEMO]" : "  [REAL]"));
   PanelLine(row++, "Symbol",    InpPanelColor,
             _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)Period()));
   PanelLine(row++, "Strategy",  InpPanelColor, EnumToString(InpStrategy));
   PanelLine(row++, "Trend",     InpPanelColor,
             trendText + "  (" + EnumToString(InpTrendTF) + " EMA" +
             IntegerToString(InpTrendEMA) + ")");
   PanelLine(row++, "Bid/Ask",   InpPanelColor,
             DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits) + " / " +
             DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits));
   PanelLine(row++, "Spread",    InpPanelColor,
             DoubleToString(CurrentSpreadPoints(), 0) + " / " +
             IntegerToString(InpMaxSpreadPoints) + " pts" +
             (SpreadAcceptable() ? "" : "  (TOO WIDE - no entries)"));
   PanelLine(row++, "ATR",       InpPanelColor,
             (atr > 0.0 ? DoubleToString(atr / _Point, 0) + " pts" : "warming up") +
             (InpUseAdaptiveATR ? StringFormat("  (x%.2f)", atrScale) : ""));
   PanelLine(row++, "Positions", InpPanelColor,
             IntegerToString(OpenPositionCount()) + " / " + IntegerToString(InpMaxPositions));
   PanelLine(row++, "Equity",    InpPanelColor,
             DoubleToString(equity, 2) + "   P/L " +
             DoubleToString(equity - g_startBalance, 2));

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpStopMode == STOP_DOLLAR)
     {
      // With risk-based sizing, show what the next entry stands to lose
      // and what an active recovery would risk to clear the ledger.
      double nextRisk = RecoveryRiskUSD();
      bool   heavy    = (InpMaxLossPctBal > 0.0 &&
                         nextRisk / MathMax(balance, 0.01) * 100.0 > InpMaxRiskPercent);

      PanelLine(row++, "Risk", (heavy ? clrOrangeRed : InpPanelColor),
                StringFormat("next %.2f  |  %s",
                             nextRisk,
                             (InpZeroLossRecovery && g_recoveryDebt > 0.0
                              ? StringFormat("cover %.2f", g_recoveryDebt * InpRecoveryCover)
                              : "no ledger open")));
     }
   else
     {
      // ATR mode: whether the smallest tradeable position fits the risk
      // budget is what decides if a signal becomes a trade at all.
      double minLotPct = 0.0;
      if(atr > 0.0 && balance > 0.0)
        {
         double sd     = atr * InpATRStopMult;
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         minLotPct     = MoneyPerLot(sd) * minLot / balance * 100.0;
        }
      bool affordable = (minLotPct > 0.0 && minLotPct <= InpMaxRiskPercent);
      PanelLine(row++, "Risk", (minLotPct > 0.0 && !affordable ? clrOrangeRed : InpPanelColor),
                StringFormat("%.1f%% target | min lot %.2f%% | ceiling %.1f%%%s",
                             InpRiskPercent, minLotPct, InpMaxRiskPercent,
                             (minLotPct > 0.0 && !affordable ? "  (NO TRADES)" : "")));
     }
   PanelLine(row++, "Open risk", InpPanelColor,
             StringFormat("%.2f%% / %.1f%%", OpenRiskPercent(), InpMaxTotalRiskPct));

   if(InpZeroLossRecovery)
      PanelLine(row++, "Recovery", (g_recoveryDebt > 0.0 ? clrOrangeRed : InpPanelColor),
                StringFormat("ledger %.2f%s", g_recoveryDebt,
                             (g_recoveryDebt > 0.0
                              ? StringFormat("  (step %d, risk %.2f)",
                                             g_recoveryStep, RecoveryRiskUSD())
                              : "  (flat)")));

   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
// Shown in the LOCAL clock — the machine's own timezone — with the
// NY window translated into it, so no mental conversion is needed.
   TimeToStruct(TimeLocal(), st);
   int h12 = st.hour % 12;
   if(h12 == 0)
      h12 = 12;
   string ampm = (st.hour < 12) ? "AM" : "PM";
   int offH = (int)MathRound((double)(TimeLocal() - TimeGMT()) / 3600.0);
   int nyLo = ((InpNYStartHour + offH) % 24 + 24) % 24;
   int nyHi = ((InpNYEndHour   + offH) % 24 + 24) % 24;
   PanelLine(row++, "Time", (InpNewYorkOnly && !WithinNewYorkSession()
                             ? clrGold : InpPanelColor),
             StringFormat("%d:%02d:%02d %s local%s", h12, st.min, st.sec, ampm,
                          (InpNewYorkOnly
                           ? StringFormat("   NY %02d:00-%02d:00 %s", nyLo, nyHi,
                                          (WithinNewYorkSession() ? "OPEN" : "closed"))
                           : "")));

   if(InpUseMartingale)
      PanelLine(row++, "Ladder", (g_recoveryStep > 0 ? clrOrangeRed : InpPanelColor),
                StringFormat("step %d / %d   next lot %.2f",
                             g_recoveryStep, InpMaxRecovery, MartingaleLots()));

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void PanelLine(const int row, const string label, const color clr, const string value)
  {
   string name = PANEL_PREFIX + IntegerToString(row);

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
     }

   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20 + row * 16);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, StringFormat("%-10s %s", label + ":", value));
  }
//+------------------------------------------------------------------+
