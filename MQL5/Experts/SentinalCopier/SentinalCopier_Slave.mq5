//+------------------------------------------------------------------+
//|                                       SentinalCopier_Slave.mq5   |
//|            Mirrors the master account's positions onto this one   |
//+------------------------------------------------------------------+
#property copyright "Sentinal"
#property version   "1.00"
#property strict
#property description "Copy trading SLAVE. Mirrors the master's open positions"
#property description "onto this account - different broker and platform welcome."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ELotMode
  {
   LOT_BALANCE_RATIO,   // Scale by slave balance / master balance
   LOT_EQUITY_RATIO,    // Scale by slave equity / master equity
   LOT_MULTIPLIER,      // Master lot x fixed multiplier
   LOT_FIXED            // Always the same lot
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
enum ETransport
  {
   TRANSPORT_FILE,   // Shared folder - same PC/VPS as the master
   TRANSPORT_HTTP    // Relay URL - master on another device
  };

input group "=== Channel ==="
input string     InpChannel     = "sentinal"; // Channel name (must match the master)
input ETransport InpTransport   = TRANSPORT_FILE; // How this slave receives the feed
input int      InpPollMs        = 100;        // How often to check for changes (ms)
input int      InpMaxAgeSec     = 30;         // Ignore the feed if older than this

input group "=== Relay (TRANSPORT_HTTP) ==="
input string   InpRelayUrl      = "";         // Same URL the master publishes to
input string   InpRelayKey      = "";         // Same shared secret as the master
input int      InpHttpTimeoutMs = 2000;       // Request timeout (ms)

input group "=== Control panel ==="
input bool     InpUsePanel      = true;       // Report to the web panel and obey it
input string   InpPanelUrl      = "";         // Panel URL; empty = use InpRelayUrl
input int      InpStatusMs      = 2000;       // How often to report (ms)

input group "=== Sizing ==="
input ELotMode InpLotMode       = LOT_BALANCE_RATIO; // How slave lots are derived
input double   InpMultiplier    = 1.0;        // Multiplier (LOT_MULTIPLIER)
input double   InpFixedLot      = 0.01;       // Fixed lot (LOT_FIXED)
input double   InpMaxLot        = 0.0;        // Hard cap per trade; 0 = broker maximum

input group "=== Behaviour ==="
input bool     InpCopySLTP      = true;       // Copy stop loss and take profit
input bool     InpReverse       = false;      // Mirror inverted (buy becomes sell)
input int      InpMaxPositions  = 50;         // Refuse to exceed this many copies
input int      InpMaxSlippage   = 30;         // Max deviation (points)
input int      InpSkipOlderSec  = 60;         // Do not copy trades already older than this at startup

input group "=== Symbols ==="
input string   InpSymbolMap     = "";         // Overrides, e.g. "XAUUSD=XAUUSD.m,US30=US30.cash"
input string   InpSymbolAllow   = "";         // Only copy these master symbols; empty = all

input group "=== Display ==="
input bool     InpShowPanel     = true;       // Show status panel
input long     InpMagicNumber   = 990001;     // Magic used for every copied position

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo position;

string   g_file = "";

// Master snapshot
long     g_mAccount = 0;
string   g_mBroker  = "";
double   g_mBalance = 0.0;
double   g_mEquity  = 0.0;
datetime g_mStamp   = 0;
bool     g_feedOk   = false;
string   g_feedNote = "waiting for the master";

#define  MAX_POS 256
ulong    g_mTicket[MAX_POS];
string   g_mSymbol[MAX_POS];
int      g_mType[MAX_POS];
double   g_mVolume[MAX_POS];
double   g_mOpen[MAX_POS];
double   g_mSL[MAX_POS];
double   g_mTP[MAX_POS];
long     g_mTime[MAX_POS];
int      g_mCount = 0;

// Master pending orders. A straddle or breakout master holds nothing but
// these until one triggers, so they have to be mirrored as orders - not
// waited on and then chased as market entries.
ulong    g_oTicket[MAX_POS];
string   g_oSymbol[MAX_POS];
int      g_oType[MAX_POS];
double   g_oVolume[MAX_POS];
double   g_oPrice[MAX_POS];
double   g_oSL[MAX_POS];
double   g_oTP[MAX_POS];
double   g_oMarket[MAX_POS];    // master's market price when it published
int      g_oCount = 0;

// Symbol resolution cache
string   g_cacheFrom[64];
string   g_cacheTo[64];
int      g_cacheN = 0;

// Master tickets we have already acted on. Without this, a copy closed
// by its OWN stop while the master position is still open looks like a
// missing copy on the next pass and gets re-opened - forever, and faster
// the lower the poll interval.
ulong    g_seen[MAX_POS];
int      g_seenN = 0;

// Control from the web panel. These override the inputs while set, so a
// slave can be paused or resized without touching the terminal.
bool     g_paused      = false;
double   g_ctlMult     = 0.0;    // 0 = no override
double   g_ctlMaxLot   = 0.0;    // 0 = no override
datetime g_lastStatus  = 0;
bool     g_panelOk     = false;
string   g_panelNote   = "not reporting";

datetime g_started  = 0;
int      g_opened   = 0;
int      g_closed   = 0;
int      g_errors   = 0;

const string PANEL_PREFIX = "SCS_";
const string TAG          = "SC:";

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   string ch = Trim(InpChannel);
   if(ch == "")
     { Print("Copier slave: InpChannel cannot be empty."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpPollMs < 10)
     { Print("Copier slave: InpPollMs must be >= 10."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpLotMode == LOT_MULTIPLIER && InpMultiplier <= 0.0)
     { Print("Copier slave: InpMultiplier must be > 0."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpLotMode == LOT_FIXED && InpFixedLot <= 0.0)
     { Print("Copier slave: InpFixedLot must be > 0."); return(INIT_PARAMETERS_INCORRECT); }

   g_file = "SentinalCopy\\" + ch + ".csv";
   g_started = TimeGMT();

   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippage);

   EventSetMillisecondTimer(InpPollMs);

   PrintFormat("Copier slave on account %I64d (%s). Channel '%s'.",
               AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_COMPANY), ch);

   // Print the absolute path so it can be compared with the master's.
   // Identical paths and still no file means the master is not running;
   // different paths mean the terminals do not share a Common folder,
   // which is what /portable does.
   PrintFormat("Copier slave READING FROM: %s\\Files\\%s",
               TerminalInfoString(TERMINAL_COMMONDATA_PATH), g_file);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ChartRedraw();
  }

void OnTimer() { Cycle(); }
void OnTick()  { Cycle(); }

//+------------------------------------------------------------------+
//| One pass: read the feed, then reconcile                          |
//+------------------------------------------------------------------+
void Cycle()
  {
   ReadFeed();
   ReportStatus();

   if(InpShowPanel)
      PanelUpdate();

   // A stale or unreadable feed must NEVER be read as "the master closed
   // everything". Holding is the safe failure: the positions keep their
   // own stops, and nothing is closed on the strength of missing data.
   if(!g_feedOk)
      return;

   if(!TradingReady())
      return;

   ForgetClosedMasters();
   ReconcileOrders();
   Reconcile();
  }

//+------------------------------------------------------------------+
//| Read and parse the shared snapshot                               |
//+------------------------------------------------------------------+
void ReadFeed()
  {
   g_feedOk  = false;
   g_mCount  = 0;
   g_oCount  = 0;

   string text = (InpTransport == TRANSPORT_HTTP) ? FetchFromRelay() : ReadLocalFile();
   if(text == "")
      return;                            // the reader already set g_feedNote

   string lines[];
   int nl = StringSplit(text, '\n', lines);
   if(nl <= 0)
     { g_feedNote = "feed unreadable"; return; }

   bool sawHeader = false;
   for(int i = 0; i < nl; i++)
     {
      string line = Trim(lines[i]);
      if(line == "")
         continue;

      string f[];
      int nf = StringSplit(line, ',', f);

      if(nf >= 8 && f[0] == "HDR")
        {
         g_mAccount = StringToInteger(f[2]);
         g_mBroker  = f[3];
         g_mBalance = StringToDouble(f[4]);
         g_mEquity  = StringToDouble(f[5]);
         g_mStamp   = (datetime)StringToInteger(f[6]);
         sawHeader  = true;
        }
      else
         if(nf >= 11 && f[0] == "ORD" && g_oCount < MAX_POS)
           {
            g_oTicket[g_oCount] = (ulong)StringToInteger(f[1]);
            g_oSymbol[g_oCount] = f[2];
            g_oType[g_oCount]   = (int)StringToInteger(f[3]);
            g_oVolume[g_oCount] = StringToDouble(f[4]);
            g_oPrice[g_oCount]  = StringToDouble(f[5]);
            g_oSL[g_oCount]     = StringToDouble(f[6]);
            g_oTP[g_oCount]     = StringToDouble(f[7]);
            g_oMarket[g_oCount] = StringToDouble(f[10]);
            g_oCount++;
           }
      else
         if(nf >= 10 && f[0] == "POS" && g_mCount < MAX_POS)
           {
            g_mTicket[g_mCount] = (ulong)StringToInteger(f[1]);
            g_mSymbol[g_mCount] = f[2];
            g_mType[g_mCount]   = (int)StringToInteger(f[3]);
            g_mVolume[g_mCount] = StringToDouble(f[4]);
            g_mOpen[g_mCount]   = StringToDouble(f[5]);
            g_mSL[g_mCount]     = StringToDouble(f[6]);
            g_mTP[g_mCount]     = StringToDouble(f[7]);
            g_mTime[g_mCount]   = StringToInteger(f[8]);
            g_mCount++;
           }
     }

   if(!sawHeader)
     { g_feedNote = "feed has no header"; return; }

   if(g_mStamp == 0)
     { g_feedNote = "master reports itself offline"; return; }

   long age = (long)TimeGMT() - (long)g_mStamp;
   if(age > InpMaxAgeSec)
     {
      g_feedNote = StringFormat("feed stale by %d s - holding", (int)age);
      return;
     }
   if(age < -300)
     {
      // A master clock far ahead of ours makes the age test meaningless.
      g_feedNote = "master clock ahead - check terminal time";
      return;
     }

   g_feedOk  = true;
   g_feedNote = StringFormat("live, %d s old", (int)MathMax(age, 0));
  }

//+------------------------------------------------------------------+
//| Report to the control panel and read back what it wants.          |
//|                                                                   |
//| One round trip carries both: the status goes up, the pause and    |
//| sizing overrides come back in the reply. The panel never places a  |
//| trade - it only tells this EA what to do next, and this EA is      |
//| still the only thing touching the account.                        |
//+------------------------------------------------------------------+
void ReportStatus()
  {
   if(!InpUsePanel)
      return;
   if(TimeCurrent() - g_lastStatus < (InpStatusMs / 1000))
      return;
   g_lastStatus = TimeCurrent();

   string url = Trim(InpPanelUrl);
   if(url == "")
      url = Trim(InpRelayUrl);
   if(url == "")
     { g_panelNote = "no panel URL"; g_panelOk = false; return; }
   if(StringSubstr(url, StringLen(url) - 1) == "/")
      url = StringSubstr(url, 0, StringLen(url) - 1);
   url += "/status";

   string state = (!g_feedOk ? "HOLDING" : (g_paused ? "PAUSED" : "COPYING"));

   string payload =
      "account="    + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\n" +
      "broker="     + AccountInfoString(ACCOUNT_COMPANY)                 + "\n" +
      "state="      + state                                              + "\n" +
      "balance="    + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n" +
      "equity="     + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)  + "\n" +
      "copies="     + IntegerToString(CountCopies() + CountCopyOrders())  + "\n" +
      "masterpos="  + IntegerToString(g_mCount + g_oCount)               + "\n" +
      "opened="     + IntegerToString(g_opened)                          + "\n" +
      "closed="     + IntegerToString(g_closed)                          + "\n" +
      "errors="     + IntegerToString(g_errors)                          + "\n" +
      "feed="       + g_feedNote                                         + "\n";

   char post[], reply[];
   string replyHeaders;
   int n = StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      ArrayResize(post, n - 1);

   string key = Trim(InpRelayKey);
   string headers = "Content-Type: text/plain\r\nX-Copier-Key: " + key + "\r\n";

   ResetLastError();
   int code = WebRequest("POST", url, headers, InpHttpTimeoutMs, post, reply, replyHeaders);

   if(code != 200)
     {
      g_panelOk = false;
      int err = GetLastError();
      g_panelNote = (code == -1 && err == 4014)
                    ? "panel URL not whitelisted"
                    : StringFormat("panel HTTP %d", code);
      return;
     }

   g_panelOk   = true;
   g_panelNote = "connected";
   ApplyControl(CharArrayToString(reply, 0, ArraySize(reply), CP_UTF8));
  }

//+------------------------------------------------------------------+
//| Parse the panel's reply: paused / multiplier / maxlot            |
//+------------------------------------------------------------------+
void ApplyControl(const string reply)
  {
   string lines[];
   int n = StringSplit(reply, '\n', lines);
   for(int i = 0; i < n; i++)
     {
      string line = Trim(lines[i]);
      int eq = StringFind(line, "=");
      if(eq <= 0)
         continue;

      string k = StringSubstr(line, 0, eq);
      string v = StringSubstr(line, eq + 1);

      if(k == "paused")
        {
         bool p = (StringToInteger(v) != 0);
         if(p != g_paused)
            PrintFormat("Copier: panel %s this slave.", (p ? "PAUSED" : "resumed"));
         g_paused = p;
        }
      else
         if(k == "multiplier")
            g_ctlMult = StringToDouble(v);
         else
            if(k == "maxlot")
               g_ctlMaxLot = StringToDouble(v);
     }
  }

//+------------------------------------------------------------------+
//| Transport: shared folder                                         |
//+------------------------------------------------------------------+
string ReadLocalFile()
  {
   if(!FileIsExist(g_file, FILE_COMMON))
     { g_feedNote = "no feed file - is the master running?"; return(""); }

   int h = FileOpen(g_file, FILE_READ | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE)
     { g_feedNote = "feed locked, retrying"; return(""); }

   ulong size = FileSize(h);
   if(size == 0 || size > 1048576)
     { FileClose(h); g_feedNote = "feed empty or oversized"; return(""); }

   uchar bytes[];
   ArrayResize(bytes, (int)size);
   FileReadArray(h, bytes, 0, (int)size);
   FileClose(h);

   return(CharArrayToString(bytes, 0, (int)size, CP_UTF8));
  }

//+------------------------------------------------------------------+
//| Transport: relay over HTTPS, for a master on another device.     |
//| The URL must be whitelisted in                                   |
//| Tools > Options > Expert Advisors > Allow WebRequest.            |
//+------------------------------------------------------------------+
string FetchFromRelay()
  {
   string url = Trim(InpRelayUrl);
   if(url == "")
     { g_feedNote = "TRANSPORT_HTTP needs InpRelayUrl"; return(""); }
   if(StringSubstr(url, StringLen(url) - 1) == "/")
      url = StringSubstr(url, 0, StringLen(url) - 1);
   url += "/feed?channel=" + Trim(InpChannel);

   char post[], reply[];
   string replyHeaders;
   string headers = "X-Copier-Key: " + Trim(InpRelayKey) + "\r\n";

   ResetLastError();
   int code = WebRequest("GET", url, headers, InpHttpTimeoutMs, post, reply, replyHeaders);

   if(code == -1)
     {
      int err = GetLastError();
      g_feedNote = (err == 4014)
                   ? "URL not allowed - whitelist it in Options"
                   : StringFormat("relay unreachable (err %d)", err);
      return("");
     }
   if(code == 404)
     { g_feedNote = "channel not on the relay yet"; return(""); }
   if(code != 200)
     { g_feedNote = StringFormat("relay HTTP %d", code); return(""); }

   return(CharArrayToString(reply, 0, ArraySize(reply), CP_UTF8));
  }

//+------------------------------------------------------------------+
//| Open what is missing, close what is gone, sync what changed      |
//+------------------------------------------------------------------+
void Reconcile()
  {
   // --- close copies whose master position no longer exists ---
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Magic() != InpMagicNumber)
         continue;

      ulong master = MasterTicketOf(position.Comment());
      if(master == 0)
         continue;                        // not one of ours, or the broker ate the comment

      if(FindMaster(master) < 0)
        {
         if(trade.PositionClose(position.Ticket()))
           {
            g_closed++;
            PrintFormat("Copier: closed #%I64u (master #%I64u closed).",
                        position.Ticket(), master);
           }
         else
           {
            g_errors++;
            PrintFormat("Copier: failed to close #%I64u. retcode=%d (%s)",
                        position.Ticket(), trade.ResultRetcode(),
                        trade.ResultRetcodeDescription());
           }
        }
     }

   // --- open the ones we do not have yet, and sync stops on the rest ---
   for(int k = 0; k < g_mCount; k++)
     {
      if(!SymbolAllowed(g_mSymbol[k]))
         continue;

      ulong slaveTicket = FindCopy(g_mTicket[k]);

      if(slaveTicket == 0)
        {
         if(g_paused)
            continue;                   // no new copies while paused

         // Already opened once and no longer here: our own stop or target
         // closed it. The master still holds its position, but that is
         // finished business for us - re-entering now would be a new trade
         // at a worse price, over and over.
         if(AlreadyHandled(g_mTicket[k]))
            continue;

         // Do not adopt trades that were already open before we started:
         // entering an old position at today's price is a different trade.
         if(InpSkipOlderSec > 0 && g_mTime[k] > 0 &&
            (long)g_started - g_mTime[k] > InpSkipOlderSec)
            continue;

         if(CountCopies() >= InpMaxPositions)
           {
            g_feedNote = "position limit reached";
            continue;
           }
         OpenCopy(k);
        }
      else
         if(InpCopySLTP)
            SyncStops(slaveTicket, k);
     }
  }

//+------------------------------------------------------------------+
//| Mirror the master's pending orders                               |
//+------------------------------------------------------------------+
void ReconcileOrders()
  {
   // Delete copies whose master order is gone - cancelled, expired, or
   // filled and then closed. A master order that FILLED keeps its ticket
   // as the position id, so it still shows up in the position list and
   // this leaves our pending alone until ours fills too.
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      ulong master = MasterTicketOf(OrderGetString(ORDER_COMMENT));
      if(master == 0)
         continue;

      if(FindMasterOrder(master) < 0 && FindMaster(master) < 0)
        {
         if(trade.OrderDelete(t))
           {
            g_closed++;
            PrintFormat("Copier: deleted pending #%I64u (master #%I64u gone).", t, master);
           }
         else
            g_errors++;
        }
     }

   // Paused stops NEW copies only. Deletions above still run, so pausing
   // never strands a copy the master has already finished with.
   if(g_paused)
      return;

   // Place the ones we are missing.
   for(int k = 0; k < g_oCount; k++)
     {
      if(!SymbolAllowed(g_oSymbol[k]))
         continue;
      if(FindCopyOrder(g_oTicket[k]) != 0)
         continue;                       // already have the pending
      if(FindCopy(g_oTicket[k]) != 0)
         continue;                       // ours already filled
      if(AlreadyHandled(g_oTicket[k]))
         continue;
      if(CountCopies() + CountCopyOrders() >= InpMaxPositions)
        {
         g_feedNote = "position limit reached";
         continue;
        }
      PlacePending(k);
     }
  }

//+------------------------------------------------------------------+
//| Place one pending order.                                         |
//|                                                                  |
//| The level is copied as a DISTANCE from the master's market price  |
//| at the moment it published, applied to this broker's market now.  |
//| Copying the absolute level would misplace the order by whatever   |
//| the two brokers differ by - which for gold is routinely cents.    |
//+------------------------------------------------------------------+
void PlacePending(const int k)
  {
   if(InpReverse)
      return;      // inverting a stop/limit straddle has no clear meaning

   string sym = ResolveSymbol(g_oSymbol[k]);
   if(sym == "")
     {
      g_errors++;
      PrintFormat("Copier: no local symbol matches '%s' - add it to InpSymbolMap.",
                  g_oSymbol[k]);
      return;
     }

   double lots = SlaveLots(g_oVolume[k], sym);
   if(lots <= 0.0)
     { g_errors++; return; }

   int    type    = g_oType[k];
   bool   buySide = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP);
   int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double market  = buySide ? SymbolInfoDouble(sym, SYMBOL_ASK)
                            : SymbolInfoDouble(sym, SYMBOL_BID);
   if(market <= 0.0 || g_oMarket[k] <= 0.0)
     { g_errors++; return; }

   double price = NormalizeDouble(market + (g_oPrice[k] - g_oMarket[k]), digits);

   double sl = 0.0, tp = 0.0;
   if(InpCopySLTP)
     {
      if(g_oSL[k] > 0.0)
         sl = NormalizeDouble(price - (g_oPrice[k] - g_oSL[k]), digits);
      if(g_oTP[k] > 0.0)
         tp = NormalizeDouble(price - (g_oPrice[k] - g_oTP[k]), digits);
     }

   string comment = TAG + IntegerToString((long)g_oTicket[k]);

   bool ok = false;
   switch(type)
     {
      case ORDER_TYPE_BUY_LIMIT:  ok = trade.BuyLimit (lots, price, sym, sl, tp, 0, 0, comment); break;
      case ORDER_TYPE_SELL_LIMIT: ok = trade.SellLimit(lots, price, sym, sl, tp, 0, 0, comment); break;
      case ORDER_TYPE_BUY_STOP:   ok = trade.BuyStop  (lots, price, sym, sl, tp, 0, 0, comment); break;
      case ORDER_TYPE_SELL_STOP:  ok = trade.SellStop (lots, price, sym, sl, tp, 0, 0, comment); break;
      default: return;
     }

   if(ok)
     {
      g_opened++;
      MarkHandled(g_oTicket[k]);
      PrintFormat("Copier: pending %s %.2f %s @ %s copying master #%I64u.",
                  EnumToString((ENUM_ORDER_TYPE)type), lots, sym,
                  DoubleToString(price, digits), g_oTicket[k]);
     }
   else
     {
      g_errors++;
      PrintFormat("Copier: pending failed on %s. retcode=%d (%s)",
                  sym, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Open one copy                                                    |
//+------------------------------------------------------------------+
void OpenCopy(const int k)
  {
   string sym = ResolveSymbol(g_mSymbol[k]);
   if(sym == "")
     {
      g_errors++;
      PrintFormat("Copier: no local symbol matches '%s' - add it to InpSymbolMap.",
                  g_mSymbol[k]);
      return;
     }

   double lots = SlaveLots(g_mVolume[k], sym);
   if(lots <= 0.0)
     {
      g_errors++;
      PrintFormat("Copier: computed lot for %s is below this broker's minimum.", sym);
      return;
     }

   bool masterBuy = (g_mType[k] == 0);
   bool buy       = (InpReverse ? !masterBuy : masterBuy);

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     {
      g_errors++;
      PrintFormat("Copier: no price for %s yet.", sym);
      return;
     }
   double price = buy ? ask : bid;

   // Stops travel as DISTANCES from the master's own fill, so a broker
   // quoting a different absolute price still gets the same risk.
   double sl = 0.0, tp = 0.0;
   if(InpCopySLTP)
      StopsFor(k, sym, price, buy, sl, tp);

   string comment = TAG + IntegerToString((long)g_mTicket[k]);

   bool ok = buy ? trade.Buy(lots, sym, 0.0, sl, tp, comment)
                 : trade.Sell(lots, sym, 0.0, sl, tp, comment);
   if(ok)
     {
      g_opened++;
      MarkHandled(g_mTicket[k]);
      PrintFormat("Copier: %s %.2f %s copying master #%I64u (master %.2f lots).",
                  (buy ? "BUY" : "SELL"), lots, sym, g_mTicket[k], g_mVolume[k]);
     }
   else
     {
      g_errors++;
      PrintFormat("Copier: open failed for %s. retcode=%d (%s)",
                  sym, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Translate the master's stops onto this symbol                    |
//+------------------------------------------------------------------+
void StopsFor(const int k, const string sym, const double price,
              const bool buy, double &sl, double &tp)
  {
   sl = 0.0; tp = 0.0;
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minGap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double spread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   minGap = MathMax(minGap, spread * 2.0);

   if(g_mOpen[k] <= 0.0)
      return;

   double slDist = (g_mSL[k] > 0.0) ? MathAbs(g_mOpen[k] - g_mSL[k]) : 0.0;
   double tpDist = (g_mTP[k] > 0.0) ? MathAbs(g_mOpen[k] - g_mTP[k]) : 0.0;

   // Mirrored inverted, the two swap roles. The master's stop being hit
   // is price moving our way, so that distance is our target; the
   // master's target being hit is price moving against us, so that
   // distance is our stop. Copying them straight across would put the
   // stop on the profitable side and the target on the losing one.
   if(InpReverse)
     {
      double t = slDist;
      slDist   = tpDist;
      tpDist   = t;
     }

   if(slDist > 0.0)
     {
      if(slDist < minGap) slDist = minGap;
      sl = NormalizeDouble(buy ? price - slDist : price + slDist, digits);
     }
   if(tpDist > 0.0)
     {
      if(tpDist < minGap) tpDist = minGap;
      tp = NormalizeDouble(buy ? price + tpDist : price - tpDist, digits);
     }
  }

//+------------------------------------------------------------------+
//| Keep an open copy's stops in step with the master                |
//+------------------------------------------------------------------+
void SyncStops(const ulong slaveTicket, const int k)
  {
   if(!position.SelectByTicket(slaveTicket))
      return;

   string sym    = position.Symbol();
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   bool   buy    = (position.PositionType() == POSITION_TYPE_BUY);
   double entry  = position.PriceOpen();

   double sl = 0.0, tp = 0.0;
   StopsFor(k, sym, entry, buy, sl, tp);

   double curSL = position.StopLoss();
   double curTP = position.TakeProfit();
   double tol   = 5 * point;

   if(MathAbs(sl - curSL) > tol || MathAbs(tp - curTP) > tol)
      if(!trade.PositionModify(slaveTicket, sl, tp))
         g_errors++;
  }

//+------------------------------------------------------------------+
//| Lot sizing                                                       |
//+------------------------------------------------------------------+
double SlaveLots(const double masterLots, const string sym)
  {
   double lots;

   // A multiplier set in the panel overrides the input entirely, so one
   // slave can be resized from the browser without a terminal restart.
   if(g_ctlMult > 0.0)
      return(ClampLots(masterLots * g_ctlMult, sym));

   switch(InpLotMode)
     {
      case LOT_FIXED:
         lots = InpFixedLot;
         break;
      case LOT_MULTIPLIER:
         lots = masterLots * InpMultiplier;
         break;
      case LOT_EQUITY_RATIO:
         lots = (g_mEquity  > 0.0)
                ? masterLots * (AccountInfoDouble(ACCOUNT_EQUITY)  / g_mEquity)  : 0.0;
         break;
      default:                            // LOT_BALANCE_RATIO
         lots = (g_mBalance > 0.0)
                ? masterLots * (AccountInfoDouble(ACCOUNT_BALANCE) / g_mBalance) : 0.0;
         break;
     }

   return(ClampLots(lots, sym));
  }

//+------------------------------------------------------------------+
//| Apply the caps and fit the result to what the broker will accept |
//+------------------------------------------------------------------+
double ClampLots(double lots, const string sym)
  {
   // The panel's cap wins when it is set, otherwise the input applies.
   double cap = (g_ctlMaxLot > 0.0) ? g_ctlMaxLot : InpMaxLot;
   if(cap > 0.0 && lots > cap)
      lots = cap;

   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   lots = MathFloor(lots / step) * step;
   if(lots < minLot)
      lots = minLot;                      // the broker cannot trade smaller
   if(lots > maxLot)
      lots = maxLot;

   int lotDigits = (int)MathMax(0, MathRound(-MathLog10(step)));
   return(NormalizeDouble(lots, lotDigits));
  }

//+------------------------------------------------------------------+
//| Symbol resolution across brokers.                                |
//|                                                                  |
//| The same instrument is XAUUSD here, XAUUSD.m there and XAUUSDm    |
//| somewhere else. Strip the decoration from both sides and compare  |
//| what is left, after honouring any explicit override.              |
//+------------------------------------------------------------------+
string ResolveSymbol(const string masterSym)
  {
   for(int i = 0; i < g_cacheN; i++)
      if(g_cacheFrom[i] == masterSym)
         return(g_cacheTo[i]);

   string found = "";

   // 1. explicit override wins
   string map = Trim(InpSymbolMap);
   if(map != "")
     {
      string pairs[];
      int np = StringSplit(map, ',', pairs);
      for(int i = 0; i < np && found == ""; i++)
        {
         string kv[];
         if(StringSplit(Trim(pairs[i]), '=', kv) == 2)
            if(StringCompare(Trim(kv[0]), masterSym, false) == 0)
               found = Trim(kv[1]);
        }
     }

   // 2. the exact name, if this broker happens to use it
   if(found == "" && SymbolInfoInteger(masterSym, SYMBOL_SELECT) >= 0)
      if(SymbolSelect(masterSym, true))
         if(SymbolInfoDouble(masterSym, SYMBOL_BID) > 0.0)
            found = masterSym;

   // 3. canonical-base match across everything the broker offers
   if(found == "")
     {
      string want = CanonicalBase(masterSym);
      int total = SymbolsTotal(false);
      for(int i = 0; i < total && found == ""; i++)
        {
         string cand = SymbolName(i, false);
         if(CanonicalBase(cand) == want)
            found = cand;
        }
     }

   if(found != "")
      SymbolSelect(found, true);

   if(g_cacheN < 64)
     {
      g_cacheFrom[g_cacheN] = masterSym;
      g_cacheTo[g_cacheN]   = found;
      g_cacheN++;
     }
   if(found != "" && found != masterSym)
      PrintFormat("Copier: '%s' resolved to '%s' on this broker.", masterSym, found);

   return(found);
  }

//+------------------------------------------------------------------+
//| Brokers do not merely decorate names, they rename instruments     |
//| outright: FxPro calls gold GOLD where Exness calls it XAUUSDm.     |
//| Stripping suffixes can never bridge that, so equivalent names are  |
//| folded onto one canonical base first.                              |
//+------------------------------------------------------------------+
string CanonicalBase(const string s)
  {
   string b = SymbolBase(s);

   // Metals
   if(b == "GOLD" || b == "GOLDSPOT" || b == "XAUUSD")            return("XAUUSD");
   if(b == "SILVER" || b == "SILVERSPOT" || b == "XAGUSD")        return("XAGUSD");

   // Indices
   if(b == "US30" || b == "DJ30" || b == "DOW" || b == "DOW30" ||
      b == "WS30" || b == "USA30")                                return("US30");
   if(b == "NAS100" || b == "USTEC" || b == "NDX100" || b == "US100" ||
      b == "USATEC" || b == "NASDAQ")                             return("NAS100");
   if(b == "SPX500" || b == "US500" || b == "SP500" || b == "USA500") return("SPX500");
   if(b == "GER40" || b == "DAX40" || b == "DE40" || b == "GER30" ||
      b == "DAX30" || b == "DE30")                                return("GER40");
   if(b == "UK100" || b == "FTSE100" || b == "GB100")             return("UK100");
   if(b == "JP225" || b == "NIKKEI" || b == "JPN225")             return("JP225");

   // Energy
   if(b == "USOIL" || b == "WTI" || b == "CRUDE" || b == "XTIUSD" ||
      b == "OILUSD" || b == "CL")                                 return("USOIL");
   if(b == "UKOIL" || b == "BRENT" || b == "XBRUSD")              return("UKOIL");

   // Crypto
   if(b == "BTCUSD" || b == "BITCOIN")                            return("BTCUSD");
   if(b == "ETHUSD" || b == "ETHEREUM")                           return("ETHUSD");

   return(b);
  }

// "XAUUSD.m" -> "XAUUSD", "XAUUSDm" -> "XAUUSD", "EURUSD_i" -> "EURUSD"
string SymbolBase(const string s)
  {
   string t = s;

   int cut = -1;
   for(int i = 0; i < StringLen(t); i++)
     {
      ushort c = StringGetCharacter(t, i);
      if(c == '.' || c == '_' || c == '-' || c == '#')
        { cut = i; break; }
     }
   if(cut >= 0)
      t = StringSubstr(t, 0, cut);

   // Trailing lower-case decoration such as the "m" in XAUUSDm.
   while(StringLen(t) > 3)
     {
      ushort c = StringGetCharacter(t, StringLen(t) - 1);
      if(c >= 'a' && c <= 'z')
         t = StringSubstr(t, 0, StringLen(t) - 1);
      else
         break;
     }

   StringToUpper(t);
   return(t);
  }

//+------------------------------------------------------------------+
//| Mapping helpers                                                  |
//+------------------------------------------------------------------+
ulong MasterTicketOf(const string comment)
  {
   int p = StringFind(comment, TAG);
   if(p < 0)
      return(0);
   return((ulong)StringToInteger(StringSubstr(comment, p + StringLen(TAG))));
  }

bool AlreadyHandled(const ulong t)
  {
   for(int i = 0; i < g_seenN; i++)
      if(g_seen[i] == t)
         return(true);
   return(false);
  }

void MarkHandled(const ulong t)
  {
   if(!AlreadyHandled(t) && g_seenN < MAX_POS)
      g_seen[g_seenN++] = t;
  }

// Once the master's own position is gone the ticket can never come back,
// so drop it and keep the list from filling up over a long session.
void ForgetClosedMasters()
  {
   int w = 0;
   for(int i = 0; i < g_seenN; i++)
      if(FindMaster(g_seen[i]) >= 0 || FindMasterOrder(g_seen[i]) >= 0)
         g_seen[w++] = g_seen[i];
   g_seenN = w;
  }

int FindMaster(const ulong masterTicket)
  {
   for(int i = 0; i < g_mCount; i++)
      if(g_mTicket[i] == masterTicket)
         return(i);
   return(-1);
  }

int FindMasterOrder(const ulong masterTicket)
  {
   for(int i = 0; i < g_oCount; i++)
      if(g_oTicket[i] == masterTicket)
         return(i);
   return(-1);
  }

ulong FindCopyOrder(const ulong masterTicket)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      if(MasterTicketOf(OrderGetString(ORDER_COMMENT)) == masterTicket)
         return(t);
     }
   return(0);
  }

int CountCopyOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         n++;
     }
   return(n);
  }

ulong FindCopy(const ulong masterTicket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Magic() != InpMagicNumber)
         continue;
      if(MasterTicketOf(position.Comment()) == masterTicket)
         return(position.Ticket());
     }
   return(0);
  }

int CountCopies()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Magic() == InpMagicNumber)
         n++;
     }
   return(n);
  }

bool SymbolAllowed(const string sym)
  {
   string filter = Trim(InpSymbolAllow);
   if(filter == "")
      return(true);
   string parts[];
   int n = StringSplit(filter, ',', parts);
   for(int i = 0; i < n; i++)
      if(StringCompare(Trim(parts[i]), sym, false) == 0)
         return(true);
   return(false);
  }

bool TradingReady()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))   return(false);
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))         return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return(false);
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))  return(false);
   return(true);
  }

string Trim(const string s)
  {
   string t = s;
   StringTrimLeft(t);
   StringTrimRight(t);
   return(t);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void PanelUpdate()
  {
   int row = 0;
   bool algo = MQLInfoInteger(MQL_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_EXPERT);

   string state; color col;
   if(!g_feedOk)                { state = "HOLDING";  col = clrGold;      }
   else if(!algo)               { state = "ALGO OFF"; col = clrOrangeRed; }
   else if(g_paused)            { state = "PAUSED";   col = clrGold;      }
   else                         { state = "COPYING";  col = clrLime;      }

   PanelLine(row++, "Copier",  col, state + "   (" + g_feedNote + ")");
   if(InpUsePanel)
      PanelLine(row++, "Panel", (g_panelOk ? clrWhite : clrOrangeRed),
                g_panelNote +
                (g_ctlMult   > 0.0 ? StringFormat("  x%.2f", g_ctlMult) : "") +
                (g_ctlMaxLot > 0.0 ? StringFormat("  cap %.2f", g_ctlMaxLot) : ""));
   PanelLine(row++, "Channel", clrWhite, Trim(InpChannel));
   PanelLine(row++, "Master",  clrWhite,
             (g_mAccount > 0
              ? IntegerToString(g_mAccount) + "  " + g_mBroker
              : "unknown"));
   PanelLine(row++, "Master bal", clrWhite,
             (g_mBalance > 0.0 ? DoubleToString(g_mBalance, 2) : "-"));
   PanelLine(row++, "This bal",   clrWhite,
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " +
             AccountInfoString(ACCOUNT_CURRENCY));
   PanelLine(row++, "Ratio",   clrWhite,
             (g_mBalance > 0.0
              ? StringFormat("x%.3f  (%s)", AccountInfoDouble(ACCOUNT_BALANCE) / g_mBalance,
                             EnumToString(InpLotMode))
              : EnumToString(InpLotMode)));
   PanelLine(row++, "Master pos", clrWhite, IntegerToString(g_mCount));
   PanelLine(row++, "Copies",  clrWhite,
             IntegerToString(CountCopies()) + " / " + IntegerToString(InpMaxPositions));
   PanelLine(row++, "Session", clrWhite,
             StringFormat("opened %d  closed %d  errors %d", g_opened, g_closed, g_errors));
   if(InpReverse)
      PanelLine(row++, "Mode", clrGold, "REVERSED - buys copy as sells");

   ChartRedraw();
  }

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
     }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20 + row * 16);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, StringFormat("%-11s %s", label + ":", value));
  }
//+------------------------------------------------------------------+
