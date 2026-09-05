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
// LOT_SAME is appended rather than inserted at the front: the value of an
// enum member is its position, so putting it first would silently change
// what every existing .set file means.
enum ELotMode
  {
   LOT_BALANCE_RATIO,   // Scale by slave balance / master balance
   LOT_EQUITY_RATIO,    // Scale by slave equity / master equity
   LOT_MULTIPLIER,      // Master lot x fixed multiplier
   LOT_FIXED,           // Always the same lot
   LOT_SAME             // Identical to the master, lot for lot
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
enum ETransport
  {
   TRANSPORT_FILE,   // Shared folder - same PC/VPS as the master
   TRANSPORT_HTTP    // Relay URL - master on another device
  };

enum EPriceMode
  {
   PRICE_ABSOLUTE,   // The master's exact price levels
   PRICE_DISTANCE    // The master's distances, applied to this fill
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
input ELotMode InpLotMode       = LOT_SAME;   // How slave lots are derived
input double   InpMultiplier    = 1.0;        // Multiplier (LOT_MULTIPLIER)
input double   InpFixedLot      = 0.01;       // Fixed lot (LOT_FIXED)
input double   InpMaxLot        = 0.0;        // Hard cap per trade; 0 = broker maximum

input group "=== Behaviour ==="
input bool       InpCopySLTP    = true;       // Copy stop loss and take profit
input EPriceMode InpPriceMode   = PRICE_ABSOLUTE; // Same prices, or same distances
input bool     InpCopyVolume    = true;       // Follow the master's partial closes and add-ons
input int      InpMaxEntryDiffPts = 0;        // Skip a copy this far off the master's price; 0 = never skip
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
// The master volume we have already matched for that ticket. Volume sync
// works off the CHANGE in this number rather than off a comparison with
// what we currently hold, which is what keeps the protection above intact:
// our own stop closing part of a copy must never look like the master
// adding to its position.
double   g_seenVol[MAX_POS];
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
int      g_resized  = 0;
int      g_adjusted = 0;         // stops this broker would not take as given
bool     g_clamped  = false;     // the last StopsFor had to move a level
string   g_stopNote = "";

// Operations the broker has just refused. A rejection repeats on the next
// cycle and every cycle after it, so without a back-off one bad stop
// becomes ten errors a second and a log nobody can read.
ulong    g_failTicket[MAX_POS];
datetime g_failWhen[MAX_POS];
int      g_failN = 0;
double   g_lastSlip = 0.0;       // points between master fill and ours

// Last sizing decision, for the panel: what the master traded, what we
// actually got on, and why they differ when they do.
double   g_lastMLot = 0.0;
double   g_lastSLot = 0.0;
string   g_lotNote  = "";

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
      "resized="    + IntegerToString(g_resized)                         + "\n" +
      "errors="     + IntegerToString(g_errors)                          + "\n" +
      "lotmode="    + EnumToString(InpLotMode)                           + "\n" +
      "lastmlot="   + DoubleToString(g_lastMLot, 2)                      + "\n" +
      "lastslot="   + DoubleToString(g_lastSLot, 2)                      + "\n" +
      "lotnote="    + g_lotNote                                          + "\n" +
      "pricemode="  + EnumToString(InpPriceMode)                         + "\n" +
      "adjusted="   + IntegerToString(g_adjusted)                        + "\n" +
      "stopnote="   + g_stopNote                                         + "\n" +
      "entryoff="   + DoubleToString(g_lastSlip, 0)                      + "\n" +
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
            PrintFormat("Copier: failed to close #%I64u. retcode=%d (%s) - %s",
                        position.Ticket(), trade.ResultRetcode(),
                        trade.ResultRetcodeDescription(),
                        RetcodeHint((int)trade.ResultRetcode()));
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
        {
         // The master can change a live position two ways after entry: it
         // can move the stops (a trailing EA, a manual drag, a break-even
         // rule) and it can change the size (scaling out of a winner,
         // adding to a runner). Both have to be followed or the copy drifts
         // away from the master while still looking connected.
         if(InpCopyVolume)
            SyncVolume(k);
         if(InpCopySLTP)
            SyncStopsAll(g_mTicket[k], k);
        }
     }
  }

//+------------------------------------------------------------------+
//| Follow the master's partial closes and add-ons.                  |
//|                                                                  |
//| Driven by the CHANGE in the master's volume since we last matched |
//| it, never by comparing against what we currently hold. Our own    |
//| stop taking out part of a copy would otherwise read as the master |
//| having added, and we would pile back in against our own stop.     |
//+------------------------------------------------------------------+
void SyncVolume(const int k)
  {
   ulong  mt    = g_mTicket[k];
   double lastM = HandledVolume(mt);

   // The handled list lives in memory, so after a terminal restart a copy
   // we still hold has no baseline. Adopt the master's size as it stands
   // rather than giving up on it - seeding cannot trade, and without this
   // volume sync stays dormant on that position for the rest of its life.
   if(lastM < 0.0)
     {
      MarkHandled(mt, g_mVolume[k]);
      return;
     }

   double nowM = g_mVolume[k];
   string sym  = ResolveSymbol(g_mSymbol[k]);
   if(sym == "")
      return;

   double step = LotStep(sym);
   if(MathAbs(nowM - lastM) < step * 0.5)
      return;                             // master size unchanged

   if(nowM < lastM)
     {
      // Scaled out. Reduce to the new target, and only ever downward - if
      // our own stop already took us below it, leave the remainder alone.
      double target = SlaveLots(nowM, sym);
      ReduceCopyTo(mt, sym, target);
     }
   else
     {
      // Added to. Put on the DIFFERENCE, not the new total, so a copy our
      // stop has already trimmed is not quietly restored to full size.
      double add = SlaveLots(nowM, sym) - SlaveLots(lastM, sym);
      if(add >= step * 0.5)
         IncreaseCopy(k, sym, add);
     }

   SetHandledVolume(mt, nowM);
   g_lastMLot = nowM;
   g_lastSLot = CopyVolume(mt);
  }

//+------------------------------------------------------------------+
//| Close volume until this master ticket's copies total `target`.   |
//| Hedging accounts can hold several positions for one master       |
//| ticket, so this walks them smallest-first and closes whole ones   |
//| where it can.                                                     |
//+------------------------------------------------------------------+
void ReduceCopyTo(const ulong masterTicket, const string sym, const double target)
  {
   double step   = LotStep(sym);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   double have = CopyVolume(masterTicket);
   double drop = have - target;
   if(drop < step * 0.5)
      return;                             // already at or below the target

   for(int i = PositionsTotal() - 1; i >= 0 && drop >= step * 0.5; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Magic() != InpMagicNumber)
         continue;
      if(MasterTicketOf(position.Comment()) != masterTicket)
         continue;

      ulong  ticket = position.Ticket();
      double vol    = position.Volume();

      // Closing the whole thing is cleaner than leaving a stub the broker
      // would reject anyway, so take it when the remainder cannot stand.
      if(vol - drop < minLot - step * 0.5)
        {
         if(trade.PositionClose(ticket))
           {
            drop -= vol;
            g_resized++;
            PrintFormat("Copier: closed #%I64u in full following master #%I64u scaling out.",
                        ticket, masterTicket);
           }
         else
            g_errors++;
        }
      else
        {
         double cut = NormalizeDouble(MathRound(drop / step) * step,
                                      (int)MathMax(0, MathRound(-MathLog10(step))));
         if(cut < minLot)
            cut = minLot;
         if(trade.PositionClosePartial(ticket, cut))
           {
            drop -= cut;
            g_resized++;
            PrintFormat("Copier: reduced #%I64u by %.2f following master #%I64u.",
                        ticket, cut, masterTicket);
           }
         else
           {
            g_errors++;
            PrintFormat("Copier: partial close failed on #%I64u. retcode=%d (%s) - %s",
                        ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                        RetcodeHint((int)trade.ResultRetcode()));
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Add to this master ticket's copy.                                |
//|                                                                  |
//| On a netting account the broker merges this into the existing     |
//| position; on a hedging account it becomes a second position       |
//| carrying the same master tag, which every lookup here treats as   |
//| part of the same copy.                                            |
//+------------------------------------------------------------------+
void IncreaseCopy(const int k, const string sym, const double addLots)
  {
   double lots = ClampLots(addLots, sym);
   if(lots <= 0.0)
      return;

   bool masterBuy = (g_mType[k] == 0);
   bool buy       = (InpReverse ? !masterBuy : masterBuy);

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     { g_errors++; return; }
   double price = buy ? ask : bid;

   double sl = 0.0, tp = 0.0;
   if(InpCopySLTP)
      StopsFor(k, sym, price, buy, sl, tp);

   string comment = TAG + IntegerToString((long)g_mTicket[k]);

   bool ok = buy ? trade.Buy(lots, sym, 0.0, sl, tp, comment)
                 : trade.Sell(lots, sym, 0.0, sl, tp, comment);
   if(ok)
     {
      g_resized++;
      PrintFormat("Copier: added %.2f %s following master #%I64u scaling in.",
                  lots, sym, g_mTicket[k]);
     }
   else
     {
      g_errors++;
      PrintFormat("Copier: add-on failed for %s. retcode=%d (%s) - %s",
                  sym, trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  RetcodeHint((int)trade.ResultRetcode()));
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

   // A pending order is the one case where the master's exact level can
   // always be honoured: nothing has to fill right now, so the price is
   // simply the price. Distance mode still exists for brokers quoting far
   // enough apart that the master's level means something different here.
   double price;
   if(InpPriceMode == PRICE_ABSOLUTE)
      price = NormalizeDouble(g_oPrice[k], digits);
   else
      price = NormalizeDouble(market + (g_oPrice[k] - g_oMarket[k]), digits);

   // The level still has to sit on the correct side of THIS broker's
   // market or the order is rejected outright.
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minGap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   bool   above  = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_LIMIT);
   double edge   = above ? market + minGap : market - minGap;
   if(above && price < edge) price = NormalizeDouble(edge, digits);
   if(!above && price > edge) price = NormalizeDouble(edge, digits);

   double sl = 0.0, tp = 0.0;
   if(InpCopySLTP)
     {
      if(InpPriceMode == PRICE_ABSOLUTE)
        {
         if(g_oSL[k] > 0.0) sl = NormalizeDouble(g_oSL[k], digits);
         if(g_oTP[k] > 0.0) tp = NormalizeDouble(g_oTP[k], digits);
        }
      else
        {
         if(g_oSL[k] > 0.0)
            sl = NormalizeDouble(price - (g_oPrice[k] - g_oSL[k]), digits);
         if(g_oTP[k] > 0.0)
            tp = NormalizeDouble(price - (g_oPrice[k] - g_oTP[k]), digits);
        }
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
      MarkHandled(g_oTicket[k], g_oVolume[k]);
      PrintFormat("Copier: pending %s %.2f %s @ %s copying master #%I64u.",
                  EnumToString((ENUM_ORDER_TYPE)type), lots, sym,
                  DoubleToString(price, digits), g_oTicket[k]);
     }
   else
     {
      g_errors++;
      g_stopNote = StringFormat("pending rejected %d (%s)",
                                (int)trade.ResultRetcode(),
                                RetcodeHint((int)trade.ResultRetcode()));
      PrintFormat("Copier: pending failed on %s @ %s. retcode=%d (%s) - %s",
                  sym, DoubleToString(price, digits),
                  trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  RetcodeHint((int)trade.ResultRetcode()));
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

   // How far this broker's market is from where the master got filled.
   // A market order fills at the market - there is no way to buy at a
   // price that has already gone - so this is reported, and optionally
   // used to refuse a copy that would enter somewhere quite different.
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point > 0.0 && g_mOpen[k] > 0.0)
     {
      g_lastSlip = MathAbs(price - g_mOpen[k]) / point;
      if(InpMaxEntryDiffPts > 0 && g_lastSlip > InpMaxEntryDiffPts)
        {
         g_feedNote = StringFormat("entry %d pts off master", (int)g_lastSlip);
         PrintFormat("Copier: skipped master #%I64u - this broker is %d points "
                     "from the master's fill (limit %d).",
                     g_mTicket[k], (int)g_lastSlip, InpMaxEntryDiffPts);
         return;
        }
     }

   // Check the margin before asking, so a copy this account cannot afford
   // reports the actual shortfall instead of a bare "not enough money".
   // Copying the master lot for lot on a smaller account is exactly where
   // this bites, and it bites only on the larger positions - which reads
   // as "some trades copy and some do not".
   double need = 0.0;
   if(OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                      sym, lots, price, need))
     {
      double have = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(need > have)
        {
         g_errors++;
         g_lotNote = StringFormat("needs %.2f margin, have %.2f", need, have);
         PrintFormat("Copier: cannot afford master #%I64u - %.2f lots of %s needs "
                     "%.2f %s margin and this account has %.2f free. Use a ratio "
                     "InpLotMode, or cap it with InpMaxLot.",
                     g_mTicket[k], lots, sym, need,
                     AccountInfoString(ACCOUNT_CURRENCY), have);
         return;
        }
     }

   double sl = 0.0, tp = 0.0;
   if(InpCopySLTP)
      StopsFor(k, sym, price, buy, sl, tp);

   string comment = TAG + IntegerToString((long)g_mTicket[k]);

   bool ok = buy ? trade.Buy(lots, sym, 0.0, sl, tp, comment)
                 : trade.Sell(lots, sym, 0.0, sl, tp, comment);
   if(ok)
     {
      g_opened++;
      MarkHandled(g_mTicket[k], g_mVolume[k]);
      g_lastMLot = g_mVolume[k];
      g_lastSLot = lots;
      PrintFormat("Copier: %s %.2f %s copying master #%I64u (master %.2f lots).",
                  (buy ? "BUY" : "SELL"), lots, sym, g_mTicket[k], g_mVolume[k]);
     }
   else
     {
      g_errors++;
      g_stopNote = StringFormat("open rejected %d (%s)",
                                (int)trade.ResultRetcode(),
                                RetcodeHint((int)trade.ResultRetcode()));
      PrintFormat("Copier: open failed for %s %.2f lots. retcode=%d (%s) - %s"
                  "  [SL %s TP %s, market %s/%s]",
                  sym, lots, trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  RetcodeHint((int)trade.ResultRetcode()),
                  DoubleToString(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                  DoubleToString(tp, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                  DoubleToString(bid, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)),
                  DoubleToString(ask, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
     }
  }

//+------------------------------------------------------------------+
//| Translate the master's stops onto this symbol                    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Take the master's absolute level and return the nearest one this  |
//| broker will actually accept.                                      |
//|                                                                   |
//| Two brokers do not quote the same price at the same instant, and   |
//| they do not enforce the same minimum stop distance. A level that   |
//| is legal on the master can therefore be on the wrong side of this  |
//| broker's market, or simply too close to it. Refusing outright      |
//| would leave the copy with no stop at all, which is worse than a    |
//| stop a few points from where it was asked for - so move it the     |
//| smallest amount that makes it legal and say so on the panel.       |
//+------------------------------------------------------------------+
double LegalStop(const string sym, const double want, const bool buy,
                 const bool isStop, const double minGap, const int digits)
  {
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return(NormalizeDouble(want, digits));

   // Which side of the market this level has to be on, and the closest it
   // is allowed to sit. A buy's stop is below and its target above; a
   // sell's are the other way round.
   bool  mustBeBelow = (buy == isStop);
   double limit      = mustBeBelow ? bid - minGap : ask + minGap;

   double got = want;
   if(mustBeBelow && want > limit)
      got = limit;
   if(!mustBeBelow && want < limit)
      got = limit;

   got = NormalizeDouble(got, digits);

   if(MathAbs(got - want) > SymbolInfoDouble(sym, SYMBOL_POINT) * 0.5)
     {
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    off   = (point > 0.0) ? (int)MathRound(MathAbs(got - want) / point) : 0;
      g_stopNote = StringFormat("%s moved %d pts to clear this broker's minimum",
                                (isStop ? "SL" : "TP"), off);
      g_adjusted++;
      g_clamped = true;
     }

   return(got);
  }

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

   // Absolute: put the stop on the master's own price, to the digit.
   // Reversing has no absolute meaning - the master's stop sits below the
   // market and the mirrored trade needs it above - so a reversed slave
   // always falls through to distances.
   if(InpPriceMode == PRICE_ABSOLUTE && !InpReverse)
     {
      g_clamped = false;
      if(g_mSL[k] > 0.0)
         sl = LegalStop(sym, g_mSL[k], buy, true,  minGap, digits);
      if(g_mTP[k] > 0.0)
         tp = LegalStop(sym, g_mTP[k], buy, false, minGap, digits);
      return;
     }

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
//| Keep every position belonging to one master ticket in step.      |
//|                                                                  |
//| A hedging account can hold more than one position for the same    |
//| master trade once the master has scaled in, and a trailing stop   |
//| has to reach all of them, not just the first one found.           |
//+------------------------------------------------------------------+
void SyncStopsAll(const ulong masterTicket, const int k)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Magic() != InpMagicNumber)
         continue;
      if(MasterTicketOf(position.Comment()) != masterTicket)
         continue;
      SyncStops(position.Ticket(), k);
     }
  }

// Everything we hold for one master ticket, added up.
double CopyVolume(const ulong masterTicket)
  {
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(position.Magic() != InpMagicNumber)
         continue;
      if(MasterTicketOf(position.Comment()) == masterTicket)
         v += position.Volume();
     }
   return(v);
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

   // A level the broker's minimum forced us to move is pinned to the
   // market, so it drifts with every tick. Matching it that closely would
   // fire a modification on each one; widen the tolerance to the gap
   // itself so a pinned stop is set once and then left alone until the
   // master genuinely moves it.
   if(g_clamped)
     {
      double minGap = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double spread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
      tol = MathMax(tol, MathMax(minGap, spread * 2.0));
     }

   if(MathAbs(sl - curSL) <= tol && MathAbs(tp - curTP) <= tol)
      return;

   // A broker that refuses this stop will refuse it again in 100 ms, so
   // retrying every cycle achieves nothing except thousands of identical
   // errors and a hammered server. Back off and try again in a moment.
   if(RecentlyFailed(slaveTicket))
      return;

   if(trade.PositionModify(slaveTicket, sl, tp))
      return;

   g_errors++;
   NoteFailure(slaveTicket);

   int rc = (int)trade.ResultRetcode();
   g_stopNote = StringFormat("stop rejected %d (%s)", rc, RetcodeHint(rc));
   PrintFormat("Copier: stop update refused on #%I64u %s. retcode=%d (%s) - %s"
               "  [wanted SL %s TP %s, market %s/%s]",
               slaveTicket, sym, rc, trade.ResultRetcodeDescription(),
               RetcodeHint(rc),
               DoubleToString(sl, digits), DoubleToString(tp, digits),
               DoubleToString(SymbolInfoDouble(sym, SYMBOL_BID), digits),
               DoubleToString(SymbolInfoDouble(sym, SYMBOL_ASK), digits));
  }

//+------------------------------------------------------------------+
//| Plain-language reason for the retcodes this EA actually provokes. |
//| The broker's own description says "Invalid stops"; what it does    |
//| not say is which of the several possible causes applied.           |
//+------------------------------------------------------------------+
string RetcodeHint(const int rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_NO_MONEY:
         return("not enough free margin for this lot size on this account");
      case TRADE_RETCODE_INVALID_STOPS:
         return("stop level rejected: too close to the market, or the wrong "
                "side of it, for this broker");
      case TRADE_RETCODE_INVALID_VOLUME:
         return("lot size outside this broker's min/max/step for the symbol");
      case TRADE_RETCODE_MARKET_CLOSED:
         return("market closed for this symbol here");
      case TRADE_RETCODE_TRADE_DISABLED:
         return("trading disabled for this symbol or account");
      case TRADE_RETCODE_INVALID_PRICE:
         return("price moved away before the order reached the server");
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
         return("price moved during execution - transient, it will retry");
      case TRADE_RETCODE_NO_CHANGES:
         return("the stop is already where we asked for it");
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return("sending faster than this broker allows - raise InpPollMs");
      case TRADE_RETCODE_LIMIT_POSITIONS:
      case TRADE_RETCODE_LIMIT_VOLUME:
         return("broker's own position or volume ceiling reached");
      case TRADE_RETCODE_CONNECTION:
         return("no connection to the trade server");
      default:
         return("see the MQL5 trade server return codes");
     }
  }

//+------------------------------------------------------------------+
//| Short back-off for an operation the broker just refused           |
//+------------------------------------------------------------------+
#define FAIL_BACKOFF_SEC 5

bool RecentlyFailed(const ulong ticket)
  {
   datetime now = TimeCurrent();
   for(int i = 0; i < g_failN; i++)
      if(g_failTicket[i] == ticket)
         return(now - g_failWhen[i] < FAIL_BACKOFF_SEC);
   return(false);
  }

void NoteFailure(const ulong ticket)
  {
   datetime now = TimeCurrent();
   for(int i = 0; i < g_failN; i++)
      if(g_failTicket[i] == ticket)
        { g_failWhen[i] = now; return; }

   if(g_failN < MAX_POS)
     {
      g_failTicket[g_failN] = ticket;
      g_failWhen[g_failN]   = now;
      g_failN++;
      return;
     }

   // Full: replace the oldest rather than losing the newest.
   int oldest = 0;
   for(int i = 1; i < g_failN; i++)
      if(g_failWhen[i] < g_failWhen[oldest])
         oldest = i;
   g_failTicket[oldest] = ticket;
   g_failWhen[oldest]   = now;
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
      case LOT_SAME:
         lots = masterLots;               // lot for lot, whatever the balances
         break;
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
   double wanted = lots;

   // The panel's cap wins when it is set, otherwise the input applies.
   double cap = (g_ctlMaxLot > 0.0) ? g_ctlMaxLot : InpMaxLot;
   if(cap > 0.0 && lots > cap)
      lots = cap;

   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   // Round to the NEAREST step, not down. Flooring turned a requested 0.10
   // into 0.09 wherever the step did not divide it exactly, so "the same as
   // the master" quietly came out smaller every time.
   lots = MathRound(lots / step) * step;
   if(lots < minLot)
      lots = minLot;                      // the broker cannot trade smaller
   if(lots > maxLot)
      lots = maxLot;

   int lotDigits = (int)MathMax(0, MathRound(-MathLog10(step)));
   lots = NormalizeDouble(lots, lotDigits);

   // Say so when this broker would not give us the size we asked for. It
   // is the difference between a copier that is working and one that is
   // silently trading a different size from the master.
   if(MathAbs(lots - wanted) > step * 0.5)
     {
      if(wanted < minLot)
         g_lotNote = StringFormat("broker min %.*f", lotDigits, minLot);
      else if(wanted > maxLot)
         g_lotNote = StringFormat("broker max %.*f", lotDigits, maxLot);
      else if(cap > 0.0 && MathAbs(lots - cap) <= step * 0.5)
         g_lotNote = StringFormat("capped at %.*f", lotDigits, cap);
      else
         g_lotNote = StringFormat("step %.*f", lotDigits, step);
     }
   else
      g_lotNote = "";

   return(lots);
  }

// Smallest volume change this symbol can express, used to decide whether a
// difference is real or just floating-point noise.
double LotStep(const string sym)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   return(step > 0.0 ? step : 0.01);
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

   // 3. canonical-base match across everything the broker offers.
   //    Brokers list several variants of one instrument - XAUUSD alongside
   //    XAUUSD.raw, or a disabled leftover from an old account type - so
   //    take the first TRADABLE match rather than the first match, and
   //    only fall back to a non-tradable one if nothing better exists.
   if(found == "")
     {
      string want     = CanonicalBase(masterSym);
      string fallback = "";
      int total = SymbolsTotal(false);
      for(int i = 0; i < total && found == ""; i++)
        {
         string cand = SymbolName(i, false);
         if(CanonicalBase(cand) != want)
            continue;

         SymbolSelect(cand, true);
         long mode = SymbolInfoInteger(cand, SYMBOL_TRADE_MODE);
         if(mode == SYMBOL_TRADE_MODE_FULL || mode == SYMBOL_TRADE_MODE_LONGONLY ||
            mode == SYMBOL_TRADE_MODE_SHORTONLY)
            found = cand;
         else
            if(fallback == "")
               fallback = cand;
        }
      if(found == "" && fallback != "")
        {
         found = fallback;
         PrintFormat("Copier: '%s' matched '%s', but this broker has it "
                     "close-only or disabled.", masterSym, found);
        }
     }

   if(found != "")
      SymbolSelect(found, true);
   else
      PrintFormat("Copier: nothing on this broker matches '%s' (looked for base "
                  "'%s'). Set InpSymbolMap, e.g. \"%s=<local name>\".",
                  masterSym, CanonicalBase(masterSym), masterSym);

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
   if(b == "GOLD" || b == "GOLDSPOT" || b == "XAUUSD" || b == "GOLDUSD")   return("XAUUSD");
   if(b == "SILVER" || b == "SILVERSPOT" || b == "XAGUSD" ||
      b == "SILVERUSD")                                                    return("XAGUSD");
   if(b == "XPTUSD" || b == "PLATINUM")                                    return("XPTUSD");
   if(b == "XPDUSD" || b == "PALLADIUM")                                   return("XPDUSD");

   // Indices
   if(b == "US30" || b == "DJ30" || b == "DOW" || b == "DOW30" ||
      b == "WS30" || b == "USA30" || b == "DJIA" || b == "US30CASH" ||
      b == "YM")                                                  return("US30");
   if(b == "NAS100" || b == "USTEC" || b == "NDX100" || b == "US100" ||
      b == "USATEC" || b == "NASDAQ" || b == "NDX" || b == "NQ" ||
      b == "TECH100")                                             return("NAS100");
   if(b == "SPX500" || b == "US500" || b == "SP500" || b == "USA500" ||
      b == "SPX" || b == "ES" || b == "SPXUSD")                    return("SPX500");
   if(b == "GER40" || b == "DAX40" || b == "DE40" || b == "GER30" ||
      b == "DAX30" || b == "DE30" || b == "DAX" || b == "GERMANY40") return("GER40");
   if(b == "UK100" || b == "FTSE100" || b == "GB100" || b == "FTSE" ||
      b == "UKX")                                                 return("UK100");
   if(b == "JP225" || b == "NIKKEI" || b == "JPN225" || b == "NI225" ||
      b == "JAPAN225")                                            return("JP225");
   if(b == "FRA40" || b == "CAC40" || b == "FR40" || b == "FRANCE40") return("FRA40");
   if(b == "AUS200" || b == "ASX200" || b == "AU200")             return("AUS200");
   if(b == "EU50" || b == "STOXX50" || b == "ESTX50" || b == "EUSTX50") return("EU50");
   if(b == "HK50" || b == "HSI" || b == "HANGSENG")               return("HK50");
   if(b == "US2000" || b == "RUSSELL2000" || b == "RUT")          return("US2000");

   // Energy
   if(b == "USOIL" || b == "WTI" || b == "CRUDE" || b == "XTIUSD" ||
      b == "OILUSD" || b == "CL" || b == "CRUDEOIL" ||
      b == "WTIUSD" || b == "USCRUDE")                            return("USOIL");
   if(b == "UKOIL" || b == "BRENT" || b == "XBRUSD" || b == "BRENTUSD" ||
      b == "UKBRENT")                                             return("UKOIL");
   if(b == "NATGAS" || b == "XNGUSD" || b == "NGAS" || b == "NG")  return("NATGAS");

   // Crypto
   if(b == "BTCUSD" || b == "BITCOIN" || b == "BTCUSDT" || b == "XBTUSD") return("BTCUSD");
   if(b == "ETHUSD" || b == "ETHEREUM" || b == "ETHUSDT")         return("ETHUSD");
   if(b == "LTCUSD" || b == "LITECOIN" || b == "LTCUSDT")         return("LTCUSD");
   if(b == "XRPUSD" || b == "RIPPLE" || b == "XRPUSDT")           return("XRPUSD");

   return(b);
  }

// Strip a broker's decoration to get at the instrument underneath:
//   "XAUUSD.m" "XAUUSDm" "EURUSD_i" "EURUSD-5" -> suffixes
//   "FX_EURUSD" "#AAPL" "m.XAUUSD"             -> prefixes
//   "US30.cash"                                -> keeps US30
string SymbolBase(const string s)
  {
   string t = s;

   // Split on the separators brokers decorate with and take the first
   // segment that is long enough to be an instrument. Taking the first
   // segment unconditionally turned "FX_EURUSD" into "FX"; taking the
   // longest turns "US30.cash" into "cash". Neither is the instrument.
   string parts[];
   int n = 0;
   StringReplace(t, ".", "|");
   StringReplace(t, "_", "|");
   StringReplace(t, "-", "|");
   StringReplace(t, "#", "|");
   StringReplace(t, "/", "|");
   n = StringSplit(t, '|', parts);
   if(n > 0)
     {
      t = "";
      for(int i = 0; i < n && t == ""; i++)
         if(StringLen(parts[i]) >= 3)
            t = parts[i];
      if(t == "")
         t = parts[0];
     }

   // Leading lower-case decoration: the "m" in mXAUUSD. Only when what is
   // left still looks like an instrument.
   int lead = 0;
   while(lead < StringLen(t))
     {
      ushort c = StringGetCharacter(t, lead);
      if(c >= 'a' && c <= 'z') lead++;
      else break;
     }
   if(lead > 0 && StringLen(t) - lead >= 4)
      t = StringSubstr(t, lead);

   // Trailing lower-case decoration: the "m" in XAUUSDm, the "pro" in
   // EURUSDpro. Naively stripping every trailing lower-case letter also
   // eats real names - "Gold" becomes "GOL", "Silver" becomes "SILV" - so
   // instead take the leading run of upper case and digits and keep it
   // only if that run is itself long enough to be the instrument. A name
   // that is merely capitalised has a run of one and is left alone.
   int core = 0;
   while(core < StringLen(t))
     {
      ushort c = StringGetCharacter(t, core);
      if(!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')))
         break;
      // A capitalised word starting straight after a digit is decoration,
      // not instrument: US30Cash is US30. The digit is what distinguishes
      // it from the D in XAUUSDm, where the letter really is part of the
      // name and only the trailing "m" is the broker's.
      if(c >= 'A' && c <= 'Z' && core > 0 && core + 1 < StringLen(t))
        {
         ushort prv = StringGetCharacter(t, core - 1);
         ushort nxt = StringGetCharacter(t, core + 1);
         if(prv >= '0' && prv <= '9' && nxt >= 'a' && nxt <= 'z')
            break;
        }
      core++;
     }
   if(core >= 4 && core < StringLen(t))
      t = StringSubstr(t, 0, core);

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

void MarkHandled(const ulong t, const double masterVol)
  {
   if(!AlreadyHandled(t) && g_seenN < MAX_POS)
     {
      g_seen[g_seenN]    = t;
      g_seenVol[g_seenN] = masterVol;
      g_seenN++;
     }
  }

// The master volume we last matched for this ticket, or -1 if we have not
// acted on it at all. Volume sync uses the difference against this.
double HandledVolume(const ulong t)
  {
   for(int i = 0; i < g_seenN; i++)
      if(g_seen[i] == t)
         return(g_seenVol[i]);
   return(-1.0);
  }

void SetHandledVolume(const ulong t, const double masterVol)
  {
   for(int i = 0; i < g_seenN; i++)
      if(g_seen[i] == t)
        { g_seenVol[i] = masterVol; return; }
  }

// Once the master's own position is gone the ticket can never come back,
// so drop it and keep the list from filling up over a long session.
void ForgetClosedMasters()
  {
   int w = 0;
   for(int i = 0; i < g_seenN; i++)
      if(FindMaster(g_seen[i]) >= 0 || FindMasterOrder(g_seen[i]) >= 0)
        {
         g_seen[w]    = g_seen[i];
         g_seenVol[w] = g_seenVol[i];
         w++;
        }
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
   PanelLine(row++, "Sizing",  clrWhite,
             (InpLotMode == LOT_SAME
              ? "LOT_SAME - lot for lot"
              : (g_mBalance > 0.0
                 ? StringFormat("%s  x%.3f", EnumToString(InpLotMode),
                                AccountInfoDouble(ACCOUNT_BALANCE) / g_mBalance)
                 : EnumToString(InpLotMode))));

   // Master lot against what we actually got on. Equal numbers here is the
   // quickest confirmation that sizing is doing what you asked; a note
   // beside them says which broker limit moved it when they are not.
   if(g_lastSLot > 0.0)
      PanelLine(row++, "Last lot",
                (g_lotNote == "" ? clrWhite : clrGold),
                StringFormat("master %.2f  ->  this %.2f%s",
                             g_lastMLot, g_lastSLot,
                             (g_lotNote == "" ? "" : "   (" + g_lotNote + ")")));

   // Which pricing rule is in force, and how far this broker's market sat
   // from the master's on the last entry - the number that explains any
   // remaining difference between the two accounts.
   PanelLine(row++, "Prices",
             (InpPriceMode == PRICE_ABSOLUTE ? clrWhite : clrGold),
             (InpPriceMode == PRICE_ABSOLUTE
              ? "ABSOLUTE - master's exact levels"
              : "DISTANCE - master's distances") +
             (g_lastSlip > 0.0 ? StringFormat("   entry %.0f pts off", g_lastSlip) : ""));
   // Whatever last went wrong, in words. An error counter on its own never
   // said which of a dozen possible causes was actually in play.
   if(g_stopNote != "")
      PanelLine(row++, "Last issue", clrGold, g_stopNote);
   if(g_lotNote != "")
      PanelLine(row++, "Sizing note", clrGold, g_lotNote);

   PanelLine(row++, "Master pos", clrWhite, IntegerToString(g_mCount));
   PanelLine(row++, "Copies",  clrWhite,
             IntegerToString(CountCopies()) + " / " + IntegerToString(InpMaxPositions));
   PanelLine(row++, "Session", clrWhite,
             StringFormat("opened %d  closed %d  resized %d  adj %d  errors %d",
                          g_opened, g_closed, g_resized, g_adjusted, g_errors));
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
