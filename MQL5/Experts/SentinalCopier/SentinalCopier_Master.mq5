//+------------------------------------------------------------------+
//|                                      SentinalCopier_Master.mq5   |
//|          Publishes this account's open positions for the slaves   |
//+------------------------------------------------------------------+
#property copyright "Sentinal"
#property version   "1.00"
#property strict
#property description "Copy trading MASTER. Publishes every open position to a"
#property description "shared file that slave terminals read - any broker, MT4 or MT5."

#include <Trade/PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
enum ETransport
  {
   TRANSPORT_FILE,   // Shared folder - same PC/VPS only, lowest latency
   TRANSPORT_HTTP    // Relay URL - slaves on other devices
  };

input group "=== Channel ==="
input string     InpChannel    = "sentinal";  // Channel name (slaves must match)
input ETransport InpTransport  = TRANSPORT_FILE; // How slaves receive this feed
input int    InpPublishMs      = 100;         // Heartbeat interval (ms); trades publish instantly

input group "=== Relay (TRANSPORT_HTTP) ==="
input string InpRelayUrl       = "";          // e.g. https://relay.example.com
input string InpRelayKey       = "";          // Shared secret; must match the relay and slaves
input int    InpHttpTimeoutMs  = 2000;        // Request timeout (ms)

input group "=== Filters ==="
input bool   InpOnlyMagic      = false;       // Publish only positions with the magic below
input long   InpMagicFilter    = 0;           // Magic to publish when the filter is on
input string InpSymbolFilter   = "";          // Only these symbols, comma separated; empty = all

input group "=== Display ==="
input bool   InpShowPanel      = true;        // Show status panel

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CPositionInfo position;

string   g_file      = "";
string   g_tmp       = "";
string   g_lastBody  = "";      // last payload, to skip identical rewrites
long     g_published = 0;
datetime g_lastWrite = 0;
int      g_writeFails = 0;
string   g_lastError  = "";     // shown on the panel, not only in the log

const string PANEL_PREFIX = "SCM_";
#define PROTOCOL_VERSION 1

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   string ch = Trim(InpChannel);
   if(ch == "")
     {
      Print("Copier master: InpChannel cannot be empty.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpPublishMs < 10)
     {
      Print("Copier master: InpPublishMs must be >= 10.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Both MT4 and MT5 map this to the same Common\Files directory, which
   // is what lets a master on one broker feed slaves on another - and a
   // master on one platform feed slaves on the other.
   g_file = "SentinalCopy\\" + ch + ".csv";
   g_tmp  = "SentinalCopy\\" + ch + ".tmp";

   if(!FolderCreate("SentinalCopy", FILE_COMMON))
     {
      int err = GetLastError();
      if(err != ERR_FILE_NOT_EXIST && err != 0)
         PrintFormat("Copier master: could not create the shared folder (err %d). "
                     "Check that terminals are not sandboxed.", err);
     }

   EventSetMillisecondTimer(InpPublishMs);
   Publish();

   PrintFormat("Copier master on account %I64d (%s). Channel '%s'.",
               AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_COMPANY), ch);

   // Print the absolute path. A slave that reports "no feed file" while
   // this master says it is publishing means the two terminals do not
   // share a Common folder - which happens when either was started with
   // /portable. Comparing these two lines settles it immediately.
   PrintFormat("Copier master WRITING TO: %s\\Files\\%s",
               TerminalInfoString(TERMINAL_COMMONDATA_PATH), g_file);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ChartRedraw();

   // Leave a final snapshot with a zero heartbeat so slaves see the feed
   // as stale rather than believing the last picture is still current.
   if(reason != REASON_CHARTCHANGE)
      PublishStale();
  }

void OnTimer()   { Publish(); if(InpShowPanel) PanelUpdate(); }
void OnTick()    { Publish(); }

// A trade event is the moment the picture changes, so publish at once
// rather than waiting up to InpPublishMs for the timer.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   Publish();
  }

//+------------------------------------------------------------------+
//| Build the payload and write it if it changed                     |
//+------------------------------------------------------------------+
void Publish()
  {
   string body = "";
   long   count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!position.SelectByIndex(i))
         continue;
      if(InpOnlyMagic && position.Magic() != InpMagicFilter)
         continue;
      if(!SymbolAllowed(position.Symbol()))
         continue;

      // Prices are sent as the master saw them. The slave converts them
      // into distances from its own fill, so a broker quoting a few
      // cents away still gets the same stop in money terms.
      body += StringFormat("POS,%I64u,%s,%d,%.2f,%s,%s,%s,%I64d,%I64d\n",
                           position.Ticket(),
                           position.Symbol(),
                           (position.PositionType() == POSITION_TYPE_BUY ? 0 : 1),
                           position.Volume(),
                           DoubleToString(position.PriceOpen(), 8),
                           DoubleToString(position.StopLoss(),  8),
                           DoubleToString(position.TakeProfit(),8),
                           (long)position.Time(),
                           position.Magic());
      count++;
     }

   // Pending orders travel too - a straddle or breakout strategy has
   // nothing but pending orders until one fills, so a copier that only
   // publishes positions copies nothing at all for those.
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(InpOnlyMagic && (long)OrderGetInteger(ORDER_MAGIC) != InpMagicFilter)
         continue;

      string sym = OrderGetString(ORDER_SYMBOL);
      if(!SymbolAllowed(sym))
         continue;

      long type = OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT  && type != ORDER_TYPE_SELL_LIMIT &&
         type != ORDER_TYPE_BUY_STOP   && type != ORDER_TYPE_SELL_STOP)
         continue;                       // market orders are already positions

      // The market price at this instant travels with the order, so the
      // slave can place its own pending the same DISTANCE from its own
      // market rather than at an absolute level its broker may not share.
      bool   isBuySide = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP);
      double market    = isBuySide ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                   : SymbolInfoDouble(sym, SYMBOL_BID);

      body += StringFormat("ORD,%I64u,%s,%d,%.2f,%s,%s,%s,%I64d,%I64d,%s\n",
                           ticket, sym, (int)type,
                           OrderGetDouble(ORDER_VOLUME_CURRENT),
                           DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), 8),
                           DoubleToString(OrderGetDouble(ORDER_SL), 8),
                           DoubleToString(OrderGetDouble(ORDER_TP), 8),
                           (long)OrderGetInteger(ORDER_TIME_SETUP),
                           (long)OrderGetInteger(ORDER_MAGIC),
                           DoubleToString(market, 8));
      count++;
     }

   // Skip the write when nothing changed: the heartbeat still refreshes
   // on the interval below, but the disk stays quiet in between.
   bool sameBody = (body == g_lastBody);
   if(sameBody && (TimeCurrent() - g_lastWrite) < 2)
      return;

   string header = StringFormat("HDR,%d,%I64d,%s,%.2f,%.2f,%I64d,%I64d\n",
                                PROTOCOL_VERSION,
                                AccountInfoInteger(ACCOUNT_LOGIN),
                                Sanitise(AccountInfoString(ACCOUNT_COMPANY)),
                                AccountInfoDouble(ACCOUNT_BALANCE),
                                AccountInfoDouble(ACCOUNT_EQUITY),
                                (long)TimeGMT(),
                                count);

   if(WriteAtomically(header + body))
     {
      g_lastBody  = body;
      g_lastWrite = TimeCurrent();
      g_published = count;
      g_writeFails = 0;
     }
   else
      g_writeFails++;
  }

//+------------------------------------------------------------------+
//| Publish a snapshot whose heartbeat is deliberately old, so the   |
//| slaves stop acting on it instead of holding the last picture.    |
//+------------------------------------------------------------------+
void PublishStale()
  {
   string header = StringFormat("HDR,%d,%I64d,%s,%.2f,%.2f,%I64d,%I64d\n",
                                PROTOCOL_VERSION,
                                AccountInfoInteger(ACCOUNT_LOGIN),
                                Sanitise(AccountInfoString(ACCOUNT_COMPANY)),
                                AccountInfoDouble(ACCOUNT_BALANCE),
                                AccountInfoDouble(ACCOUNT_EQUITY),
                                (long)0,      // zero heartbeat = master offline
                                (long)0);
   WriteAtomically(header);
  }

//+------------------------------------------------------------------+
//| Write to a temp name then rename, so a slave never reads a file  |
//| that is halfway through being written.                           |
//+------------------------------------------------------------------+
bool WriteAtomically(const string payload)
  {
   if(InpTransport == TRANSPORT_HTTP)
      return(PostToRelay(payload));


   int h = FileOpen(g_tmp, FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      g_lastError = "cannot write the shared folder";
      if(g_writeFails == 0)
         PrintFormat("Copier master: cannot open %s (err %d).", g_tmp, GetLastError());
      return(false);
     }

   uchar bytes[];
   int n = StringToCharArray(payload, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      FileWriteArray(h, bytes, 0, n - 1);   // drop the trailing NUL
   FileClose(h);

   FileDelete(g_file, FILE_COMMON);
   if(!FileMove(g_tmp, FILE_COMMON, g_file, FILE_COMMON | FILE_REWRITE))
     {
      g_lastError = "cannot rename into place";
      if(g_writeFails == 0)
         PrintFormat("Copier master: cannot publish %s (err %d).", g_file, GetLastError());
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Push the snapshot to the relay so slaves on other machines can    |
//| read it. The URL must be whitelisted in                           |
//| Tools > Options > Expert Advisors > Allow WebRequest.             |
//+------------------------------------------------------------------+
bool PostToRelay(const string payload)
  {
   string url = Trim(InpRelayUrl);
   if(url == "")
     {
      g_lastError = "no relay URL set";
      if(g_writeFails == 0)
         Print("Copier master: TRANSPORT_HTTP needs InpRelayUrl.");
      return(false);
     }
   if(StringLen(url) > 0 && StringSubstr(url, StringLen(url) - 1) == "/")
      url = StringSubstr(url, 0, StringLen(url) - 1);
   url += "/publish?channel=" + Trim(InpChannel);

   char post[], reply[];
   string replyHeaders;
   int n = StringToCharArray(payload, post, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0)
      ArrayResize(post, n - 1);          // drop the trailing NUL

   string headers = "Content-Type: text/plain\r\nX-Copier-Key: " + Trim(InpRelayKey) + "\r\n";

   ResetLastError();
   int code = WebRequest("POST", url, headers, InpHttpTimeoutMs, post, reply, replyHeaders);

   if(code == 200)
     {
      g_lastError = "";
      return(true);
     }

   int werr = GetLastError();
   if(code == -1)
      g_lastError = (werr == 4014)
                    ? "URL not whitelisted in Options"
                    : StringFormat("relay unreachable (err %d)", werr);
   else
      g_lastError = StringFormat("relay HTTP %d", code);

   if(g_writeFails == 0)
     {
      if(code == -1)
         PrintFormat("Copier master: WebRequest blocked (err %d). Add %s to "
                     "Tools > Options > Expert Advisors > Allow WebRequest.",
                     GetLastError(), Trim(InpRelayUrl));
      else
         PrintFormat("Copier master: relay returned HTTP %d - %s",
                     code, CharArrayToString(reply, 0, MathMin(200, ArraySize(reply))));
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string Trim(const string s)
  {
   string t = s;
   StringTrimLeft(t);
   StringTrimRight(t);
   return(t);
  }

// Commas would break the CSV, and the broker name is free text.
string Sanitise(const string s)
  {
   string t = s;
   StringReplace(t, ",", " ");
   StringReplace(t, "\n", " ");
   StringReplace(t, "\r", " ");
   return(t);
  }

bool SymbolAllowed(const string sym)
  {
   string filter = Trim(InpSymbolFilter);
   if(filter == "")
      return(true);

   string parts[];
   int n = StringSplit(filter, ',', parts);
   for(int i = 0; i < n; i++)
      if(StringCompare(Trim(parts[i]), sym, false) == 0)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void PanelUpdate()
  {
   int row = 0;
   bool ok = (g_writeFails == 0);

   PanelLine(row++, "Copier", (ok ? clrLime : clrOrangeRed),
             (ok ? "MASTER publishing" : "MASTER write FAILING"));
   PanelLine(row++, "Channel",  clrWhite, Trim(InpChannel));
   PanelLine(row++, "Account",  clrWhite,
             IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "  " +
             AccountInfoString(ACCOUNT_COMPANY));
   PanelLine(row++, "Balance",  clrWhite,
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " +
             AccountInfoString(ACCOUNT_CURRENCY));
   PanelLine(row++, "Published",clrWhite, IntegerToString((int)g_published) + " positions");
   PanelLine(row++, "Last write",clrWhite,
             (g_lastWrite > 0 ? TimeToString(g_lastWrite, TIME_SECONDS) : "never"));
   PanelLine(row++, "Transport", clrWhite,
             (InpTransport == TRANSPORT_HTTP ? "HTTP relay" : "shared folder"));
   if(!ok)
      PanelLine(row++, "Error", clrOrangeRed,
                (g_lastError != "" ? g_lastError : "write failing") +
                "  (x" + IntegerToString(g_writeFails) + ")");

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
