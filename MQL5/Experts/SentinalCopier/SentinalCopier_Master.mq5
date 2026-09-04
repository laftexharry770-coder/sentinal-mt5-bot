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
input group "=== Channel ==="
input string InpChannel        = "sentinal";  // Channel name (slaves must match)
input int    InpPublishMs      = 100;         // Heartbeat interval (ms); trades publish instantly

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

   PrintFormat("Copier master on account %I64d (%s). Channel '%s' -> Common\\Files\\%s",
               AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_COMPANY),
               ch, g_file);
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
   int h = FileOpen(g_tmp, FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
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
      if(g_writeFails == 0)
         PrintFormat("Copier master: cannot publish %s (err %d).", g_file, GetLastError());
      return(false);
     }
   return(true);
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
   if(!ok)
      PanelLine(row++, "Error", clrOrangeRed,
                IntegerToString(g_writeFails) + " consecutive write failures");

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
