//+------------------------------------------------------------------+
//|                                               RiskManagerEA.mq5  |
//|  Manual trade panel with risk-based position sizing and a        |
//|  daily loss / win guard.                                         |
//|                                                                  |
//|  - Market, Buy/Sell Limit and Buy/Sell Stop orders               |
//|  - Lot size calculated from risk (% balance, % equity or money)  |
//|  - Draggable Entry / SL / TP lines with live risk & reward       |
//|  - Hard cap on risk per trade, SL always required                |
//|  - Daily guard: max losses, max daily loss %, max wins           |
//|      * Loss lock: NO override until the next trading day         |
//|      * Win lock : can be overridden from the panel               |
//+------------------------------------------------------------------+
#property copyright "leolinkz"
#property version   "1.00"
#property description "Manual trade panel: risk-based lot sizing for market and pending orders,"
#property description "with a daily loss/win guard (loss lock cannot be overridden)."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_RM_RISK_MODE
  {
   RM_RISK_PCT_BALANCE = 0, // % of balance
   RM_RISK_PCT_EQUITY  = 1, // % of equity
   RM_RISK_MONEY       = 2  // Fixed money amount
  };

enum ENUM_RM_EXPIRY
  {
   RM_EXP_GTC = 0, // Good till cancelled
   RM_EXP_DAY = 1  // Expire at end of trading day
  };

#define KIND_MARKET 0
#define KIND_LIMIT  1
#define KIND_STOP   2

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Risk per trade ==="
input ENUM_RM_RISK_MODE InpRiskMode         = RM_RISK_PCT_BALANCE; // Risk mode
input double            InpDefaultRisk      = 1.0;    // Default risk (% or money, per mode)
input double            InpMaxRiskPct       = 2.0;    // HARD cap per trade, % of balance (0 = none)
input double            InpCommissionPerLot = 0.0;    // Round-turn commission per 1.0 lot (account ccy)
input double            InpMaxLots          = 0.0;    // Max lots per order (0 = symbol max)

input group "=== Default levels ==="
input int               InpDefaultSLPoints     = 200; // Default SL distance (points)
input int               InpPendingOffsetPoints = 150; // Default pending entry offset from price (points)
input double            InpDefaultRR           = 2.0; // Default reward:risk (0 = no TP)

input group "=== Daily guard ==="
input bool              InpGuardEnabled        = true; // Enable daily guard
input int               InpMaxLossesPerDay     = 2;    // Max losing trades per day (0 = off)
input double            InpMaxDailyLossPct     = 1.0;  // Max daily loss, % of day-start balance (0 = off)
input int               InpMaxWinsPerDay       = 1;    // Max winning trades per day (0 = off, overridable)
input int               InpDayResetHour        = 0;    // Trading day starts at this server hour (0-23)
input double            InpBreakevenTolerance  = 0.0;  // |net P/L| <= this counts as breakeven (money)
input bool              InpCapToDailyBudget    = true; // Shrink lot so worst case never breaches daily loss
input bool              InpBlockIfUnprotected  = true; // Block new trades while any open trade has no SL
input bool              InpEnforceLock         = true; // While locked: close/delete trades opened anywhere
input bool              InpDeletePendingsOnLock= true; // When a lock triggers: delete ALL pending orders
input bool              InpPushNotifications   = false;// Send push notification when a lock triggers

input group "=== Execution ==="
input ulong             InpMagic           = 20261106;  // Magic number
input int               InpSlippagePoints  = 10;        // Max slippage for market orders (points)
input ENUM_RM_EXPIRY    InpPendingExpiry   = RM_EXP_GTC;// Pending order expiry
input bool              InpConfirmOrders   = true;      // Ask for confirmation before sending
input string            InpComment         = "RiskMgr"; // Order comment

input group "=== Panel & lines ==="
input int               InpPanelX       = 10;              // Panel X
input int               InpPanelY       = 30;              // Panel Y
input color             InpEntryColor   = clrDodgerBlue;   // Entry line
input color             InpSLColor      = clrTomato;       // Stop loss line
input color             InpTPColor      = clrMediumSeaGreen; // Take profit line
input bool              InpShowZones    = true;            // Shade risk / reward zones
input color             InpSLZoneColor  = C'70,28,28';     // Risk zone colour
input color             InpTPZoneColor  = C'24,60,40';     // Reward zone colour

//+------------------------------------------------------------------+
//| Object names                                                     |
//+------------------------------------------------------------------+
#define PFX        "RM_"
#define O_BG       "RM_bg"
#define B_BUY      "RM_b_buy"
#define B_SELL     "RM_b_sell"
#define B_MKT      "RM_b_mkt"
#define B_LMT      "RM_b_lmt"
#define B_STP      "RM_b_stp"
#define B_RMODE    "RM_b_rmode"
#define B_PLACE    "RM_b_place"
#define B_RESET    "RM_b_reset"
#define B_CLOSE    "RM_b_close"
#define B_DELPEND  "RM_b_delpend"
#define B_OVERRIDE "RM_b_override"
#define E_RISK     "RM_e_risk"
#define E_ENTRY    "RM_e_entry"
#define E_SL       "RM_e_sl"
#define E_SLPTS    "RM_e_slpts"
#define E_TP       "RM_e_tp"
#define E_RR       "RM_e_rr"
#define L_ENTRY    "RM_ln_entry"
#define L_SL       "RM_ln_sl"
#define L_TP       "RM_ln_tp"
#define Z_SL       "RM_z_sl"
#define Z_TP       "RM_z_tp"
#define T_ENTRY    "RM_t_entry"
#define T_SL       "RM_t_sl"
#define T_TP       "RM_t_tp"

#define PANEL_W    310

//--- panel palette
#define CLR_BG     C'24,26,32'
#define CLR_BORDER C'60,64,78'
#define CLR_TXT    C'230,232,238'
#define CLR_TXT2   C'150,155,170'
#define CLR_OFF    C'52,56,68'
#define CLR_ON     C'80,90,120'
#define CLR_EDIT   C'36,39,48'
#define CLR_RO     C'30,32,40'
#define CLR_OK     C'70,200,120'
#define CLR_WARN   C'240,170,60'
#define CLR_ERR    C'240,90,90'
#define CLR_BUY    C'0,140,90'
#define CLR_SELL   C'190,50,50'
#define CLR_DIS    C'70,72,82'

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
CTrade   g_trade;

bool     g_ready        = false;   // state survives timeframe changes
string   g_stateSymbol  = "";
bool     g_isBuy        = true;
int      g_kind         = KIND_MARKET;
bool     g_riskMoneyMode= false;
double   g_riskInput    = 1.0;
double   g_entry        = 0.0;
double   g_sl           = 0.0;
double   g_tp           = 0.0;
double   g_rr           = 2.0;

//--- calculation results
double   c_lossPerLot   = 0.0;
double   c_requested    = 0.0;
double   c_allowed      = 0.0;
double   c_lots         = 0.0;
double   c_riskMoney    = 0.0;
double   c_riskPct      = 0.0;
double   c_reward       = 0.0;
double   c_margin       = 0.0;
double   c_slPoints     = 0.0;
double   c_budgetLeft   = 0.0;
string   c_capNote      = "";
string   c_sizeMsg      = "";

//--- daily stats / guard
datetime d_start        = 0;
double   d_startBalance = 0.0;
double   d_realized     = 0.0;
int      d_wins         = 0;
int      d_losses       = 0;
double   d_openRisk     = 0.0;
bool     d_unprotected  = false;
string   d_unprotectedInfo = "";

bool     g_guardSticky  = false;
int      g_effMaxLosses = 0;
double   g_effMaxLossPct= 0.0;
bool     g_winOverride  = false;
bool     g_lossLocked   = false;
bool     g_winLocked    = false;
bool     g_firstEval    = true;
datetime g_lockTime     = 0;
string   g_lockReason   = "";

//--- UI
string   g_flash        = "";
color    g_flashColor   = CLR_TXT;
uint     g_flashUntil   = 0;
int      g_overrideY    = 0;
int      g_bgH          = 0;
uint     g_lastDayRefresh = 0;
bool     g_forceDayRefresh = true;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
double Ask() { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double Bid() { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }

double NormPrice(const double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0.0)
      return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }

int LotDigits()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 2;
   int d = 0;
   while(d < 8 && MathAbs(step * MathPow(10, d) - MathRound(step * MathPow(10, d))) > 1e-8)
      d++;
   return d;
  }

// Round DOWN to the volume step (never round risk up). Returns 0 if below min lot.
double NormalizeLots(const double raw)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 0.01;
   if(InpMaxLots > 0.0 && InpMaxLots < vmax)
      vmax = InpMaxLots;
   double lots = MathFloor(raw / step + 1e-7) * step;
   if(lots > vmax)
      lots = MathFloor(vmax / step + 1e-7) * step;
   if(lots < vmin - 1e-10)
      return 0.0;
   return NormalizeDouble(lots, LotDigits());
  }

string Ccy() { return AccountInfoString(ACCOUNT_CURRENCY); }

string Money(const double v, const bool sign = false)
  {
   string s = DoubleToString(MathAbs(v), 2) + " " + Ccy();
   if(v < 0)
      return "-" + s;
   if(sign && v > 0)
      return "+" + s;
   return s;
  }

double PipFactor() { return (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0; }

int StopsLevelPts() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }

void Flash(const string msg, const color clr, const uint ms = 6000)
  {
   g_flash = msg;
   g_flashColor = clr;
   g_flashUntil = GetTickCount() + ms;
   Print("[RiskMgr] ", msg);
  }

string KindName(const int k)
  {
   if(k == KIND_LIMIT)
      return "LIMIT";
   if(k == KIND_STOP)
      return "STOP";
   return "MARKET";
  }

ENUM_ORDER_TYPE CurrentOrderType()
  {
   if(g_kind == KIND_LIMIT)
      return g_isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   if(g_kind == KIND_STOP)
      return g_isBuy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   return g_isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
  }

int TighterInt(const int a, const int b)
  {
   if(a <= 0)
      return b;
   if(b <= 0)
      return a;
   return MathMin(a, b);
  }

double TighterDbl(const double a, const double b)
  {
   if(a <= 0.0)
      return b;
   if(b <= 0.0)
      return a;
   return MathMin(a, b);
  }

//+------------------------------------------------------------------+
//| Risk maths                                                       |
//+------------------------------------------------------------------+
// Money lost on 1.0 lot if price goes from entry to SL (incl. commission).
// Returns 0 if the SL is not on the losing side of the entry.
double LossPerLot(const string sym, const bool isBuy, const double entry, const double sl)
  {
   if(entry <= 0.0 || sl <= 0.0)
      return 0.0;
   double profit = 0.0;
   ENUM_ORDER_TYPE t = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(t, sym, 1.0, entry, sl, profit))
     {
      if(profit >= 0.0)
         return 0.0;
      return -profit + InpCommissionPerLot;
     }
   // Fallback: tick value maths
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0)
      return 0.0;
   bool wrongSide = isBuy ? (sl >= entry) : (sl <= entry);
   if(wrongSide)
      return 0.0;
   return MathAbs(entry - sl) / ts * tv + InpCommissionPerLot;
  }

bool GuardOn() { return InpGuardEnabled || g_guardSticky; }

// How much more money may be put at risk today without breaching the daily loss limit.
double DailyBudgetLeft()
  {
   if(!GuardOn() || g_effMaxLossPct <= 0.0)
      return DBL_MAX;
   double limit = d_startBalance * g_effMaxLossPct / 100.0;
   // Today's profits do NOT extend the loss budget (conservative).
   return limit + MathMin(d_realized, 0.0) - d_openRisk;
  }

void Recalc()
  {
   double ask = Ask(), bid = Bid();
   if(g_kind == KIND_MARKET)
      g_entry = g_isBuy ? ask : bid;

   double dist = MathAbs(g_entry - g_sl);
   if(g_rr > 0.0 && dist > 0.0)
      g_tp = NormPrice(g_isBuy ? g_entry + g_rr * dist : g_entry - g_rr * dist);
   else
      if(g_rr <= 0.0)
         g_tp = 0.0;

   c_slPoints   = dist / _Point;
   c_lossPerLot = LossPerLot(_Symbol, g_isBuy, g_entry, g_sl);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_riskMoneyMode)
      c_requested = g_riskInput;
   else
      c_requested = ((InpRiskMode == RM_RISK_PCT_EQUITY) ? eq : bal) * g_riskInput / 100.0;

   c_allowed = c_requested;
   c_capNote = "";
   if(InpMaxRiskPct > 0.0)
     {
      double cap = bal * InpMaxRiskPct / 100.0;
      if(c_allowed > cap)
        {
         c_allowed = cap;
         c_capNote = "capped at max " + DoubleToString(InpMaxRiskPct, 2) + "%/trade";
        }
     }
   c_budgetLeft = DailyBudgetLeft();
   if(InpCapToDailyBudget && c_budgetLeft < c_allowed)
     {
      c_allowed = MathMax(0.0, c_budgetLeft);
      c_capNote = "capped to daily loss budget";
     }

   c_lots = 0.0;
   c_sizeMsg = "";
   if(c_lossPerLot <= 0.0)
      c_sizeMsg = "Set a valid stop loss (SL is required)";
   else
      if(c_allowed <= 0.0)
         c_sizeMsg = "No daily loss budget left";
      else
        {
         c_lots = NormalizeLots(c_allowed / c_lossPerLot);
         if(c_lots <= 0.0)
           {
            double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            c_sizeMsg = "Min lot " + DoubleToString(mn, LotDigits()) + " risks " + Money(mn * c_lossPerLot) +
                        " > allowed " + Money(c_allowed) + ". Tighten SL.";
           }
        }

   c_riskMoney = c_lots * c_lossPerLot;
   c_riskPct   = (bal > 0.0) ? c_riskMoney / bal * 100.0 : 0.0;

   c_reward = 0.0;
   if(g_tp > 0.0 && c_lots > 0.0)
     {
      double p = 0.0;
      if(OrderCalcProfit(g_isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, g_entry, g_tp, p))
         c_reward = c_lots * p - c_lots * InpCommissionPerLot;
     }

   c_margin = 0.0;
   if(c_lots > 0.0)
     {
      double m = 0.0;
      if(OrderCalcMargin(g_isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, c_lots, g_entry, m))
         c_margin = m;
     }
  }

//+------------------------------------------------------------------+
//| Validation - returns "" when the order may be sent               |
//+------------------------------------------------------------------+
string Validate()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return "Algo Trading is OFF in the terminal toolbar";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return "Allow Algo Trading in the EA properties";
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return "Trading is not allowed on this account";

   if(g_lossLocked || g_winLocked)
      return g_lockReason;
   if(GuardOn() && InpBlockIfUnprotected && d_unprotected)
      return "Blocked: " + d_unprotectedInfo + " - set its SL first";

   long tm = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tm == SYMBOL_TRADE_MODE_DISABLED)
      return "Trading disabled for " + _Symbol;
   if(tm == SYMBOL_TRADE_MODE_CLOSEONLY)
      return _Symbol + " is close-only";
   if(tm == SYMBOL_TRADE_MODE_LONGONLY && !g_isBuy)
      return _Symbol + " allows long trades only";
   if(tm == SYMBOL_TRADE_MODE_SHORTONLY && g_isBuy)
      return _Symbol + " allows short trades only";

   double ask = Ask(), bid = Bid();
   if(ask <= 0.0 || bid <= 0.0)
      return "No price for " + _Symbol;
   double stops = StopsLevelPts() * _Point;

   if(g_sl <= 0.0)
      return "Stop loss is required";
   if(g_isBuy && g_sl >= g_entry)
      return "Buy SL must be BELOW entry";
   if(!g_isBuy && g_sl <= g_entry)
      return "Sell SL must be ABOVE entry";
   if(g_tp > 0.0)
     {
      if(g_isBuy && g_tp <= g_entry)
         return "Buy TP must be ABOVE entry";
      if(!g_isBuy && g_tp >= g_entry)
         return "Sell TP must be BELOW entry";
     }

   if(g_kind == KIND_LIMIT)
     {
      if(g_isBuy && g_entry >= ask)
         return "Buy Limit must be below Ask (use STOP)";
      if(!g_isBuy && g_entry <= bid)
         return "Sell Limit must be above Bid (use STOP)";
     }
   if(g_kind == KIND_STOP)
     {
      if(g_isBuy && g_entry <= ask)
         return "Buy Stop must be above Ask (use LIMIT)";
      if(!g_isBuy && g_entry >= bid)
         return "Sell Stop must be below Bid (use LIMIT)";
     }
   if(g_kind != KIND_MARKET && stops > 0.0)
     {
      double ref = g_isBuy ? ask : bid;
      if(MathAbs(g_entry - ref) < stops)
         return "Entry too close to price (min " + IntegerToString(StopsLevelPts()) + " pts)";
     }

   // SL / TP distance vs stops level
   if(stops > 0.0)
     {
      double slRef = g_entry, tpRef = g_entry;
      if(g_kind == KIND_MARKET)
        {
         // a buy closes at Bid, a sell closes at Ask
         slRef = g_isBuy ? bid : ask;
         tpRef = slRef;
        }
      if(MathAbs(slRef - g_sl) < stops)
         return "SL too close (min " + IntegerToString(StopsLevelPts()) + " pts)";
      if(g_tp > 0.0 && MathAbs(g_tp - tpRef) < stops)
         return "TP too close (min " + IntegerToString(StopsLevelPts()) + " pts)";
     }

   if(c_lossPerLot <= 0.0)
      return "Cannot price the stop loss for " + _Symbol;
   if(c_lots <= 0.0)
      return c_sizeMsg;
   if(c_margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      return "Not enough free margin (" + Money(c_margin) + " needed)";
   return "";
  }

//+------------------------------------------------------------------+
//| Daily guard                                                      |
//+------------------------------------------------------------------+
datetime DayStart()
  {
   datetime now = TimeTradeServer();
   MqlDateTime t;
   TimeToStruct(now, t);
   t.hour = MathMax(0, MathMin(23, InpDayResetHour));
   t.min  = 0;
   t.sec  = 0;
   datetime s = StructToTime(t);
   if(s > now)
      s -= 86400;
   return s;
  }

string GVKey(const string name)
  {
   MqlDateTime t;
   TimeToStruct(d_start, t);
   return "RM_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" +
          StringFormat("%04d%02d%02d", t.year, t.mon, t.day) + "_" + name;
  }

void CleanupOldGlobals()
  {
   string mine  = "RM_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_";
   string today = GVKey("");
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string n = GlobalVariableName(i);
      if(StringFind(n, mine) == 0 && StringFind(n, today) != 0)
         GlobalVariableDel(n);
     }
  }

// Limits for the day are frozen once set: they can be tightened, never loosened,
// and turning the guard off mid-day has no effect until the next trading day.
void LoadDayLimits()
  {
   string kg = GVKey("guard");
   if(InpGuardEnabled)
      GlobalVariableSet(kg, 1.0);
   g_guardSticky = GlobalVariableCheck(kg) && GlobalVariableGet(kg) > 0.5;

   string kl = GVKey("maxLoss");
   int ml = InpMaxLossesPerDay;
   if(GlobalVariableCheck(kl))
      ml = TighterInt((int)GlobalVariableGet(kl), ml);
   g_effMaxLosses = ml;
   if(g_guardSticky)
      GlobalVariableSet(kl, (double)ml);

   string kp = GVKey("maxLossPct");
   double mp = InpMaxDailyLossPct;
   if(GlobalVariableCheck(kp))
      mp = TighterDbl(GlobalVariableGet(kp), mp);
   g_effMaxLossPct = mp;
   if(g_guardSticky)
      GlobalVariableSet(kp, mp);

   g_winOverride = GlobalVariableCheck(GVKey("winOverride"));
   GlobalVariablesFlush();
   CleanupOldGlobals();
  }

void ComputeDayStats()
  {
   d_realized = 0.0;
   d_wins     = 0;
   d_losses   = 0;
   double allNet = 0.0;

   ulong  ids[];
   double nets[];
   int    cnt = 0;

   if(HistorySelect(d_start, TimeTradeServer() + 3600))
     {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         double net = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                      HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         allNet += net;
         long type = HistoryDealGetInteger(d, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;           // deposits, credits, etc.
         d_realized += net;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
            continue;
         ulong pid = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
         int k = -1;
         for(int j = 0; j < cnt; j++)
            if(ids[j] == pid)
              {
               k = j;
               break;
              }
         if(k < 0)
           {
            ArrayResize(ids, cnt + 1);
            ArrayResize(nets, cnt + 1);
            ids[cnt]  = pid;
            nets[cnt] = 0.0;
            k = cnt;
            cnt++;
           }
         nets[k] += net;
        }
     }
   d_startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - allNet;

   // Classify each position closed today as win / loss (entry-side costs included).
   for(int j = 0; j < cnt; j++)
     {
      if(PositionSelectByTicket(ids[j]))
         continue;                     // partially closed, still open -> not counted yet
      double total = nets[j];
      if(HistorySelectByPosition(ids[j]))
        {
         int m = HistoryDealsTotal();
         for(int i = 0; i < m; i++)
           {
            ulong d = HistoryDealGetTicket(i);
            if(d == 0)
               continue;
            if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
               total += HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
           }
        }
      if(total > InpBreakevenTolerance)
         d_wins++;
      else
         if(total < -InpBreakevenTolerance)
            d_losses++;
     }
  }

// Worst-case loss of everything already open or pending (account-wide).
void ComputeOpenRisk()
  {
   d_openRisk = 0.0;
   d_unprotected = false;
   d_unprotectedInfo = "";

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      bool   buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
        {
         d_unprotected = true;
         d_unprotectedInfo = "position #" + (string)tk + " " + sym + " has no SL";
         continue;
        }
      double p = 0.0;
      if(OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, op, sl, p) && p < 0.0)
         d_openRisk += -p;
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      ENUM_ORDER_TYPE ty = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ty == ORDER_TYPE_BUY || ty == ORDER_TYPE_SELL)
         continue;                     // market order in flight; will show up as position
      bool buy = (ty == ORDER_TYPE_BUY_LIMIT || ty == ORDER_TYPE_BUY_STOP || ty == ORDER_TYPE_BUY_STOP_LIMIT);
      string sym = OrderGetString(ORDER_SYMBOL);
      double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double op  = OrderGetDouble(ORDER_PRICE_OPEN);
      if(ty == ORDER_TYPE_BUY_STOP_LIMIT || ty == ORDER_TYPE_SELL_STOP_LIMIT)
         op = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
      double sl  = OrderGetDouble(ORDER_SL);
      if(sl <= 0.0)
        {
         d_unprotected = true;
         d_unprotectedInfo = "pending #" + (string)tk + " " + sym + " has no SL";
         continue;
        }
      double p = 0.0;
      if(OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, op, sl, p) && p < 0.0)
         d_openRisk += -p;
     }
  }

datetime LockTime(const string key)
  {
   string k = GVKey(key);
   if(!GlobalVariableCheck(k))
     {
      GlobalVariableSet(k, (double)TimeTradeServer());
      GlobalVariablesFlush();
     }
   return (datetime)GlobalVariableGet(k);
  }

void Notify(const string msg)
  {
   Alert("[RiskMgr] ", msg);
   if(InpPushNotifications)
      SendNotification("[RiskMgr] " + msg);
  }

void EvaluateLocks()
  {
   bool wasLoss = g_lossLocked, wasWin = g_winLocked;
   g_lossLocked = false;
   g_winLocked  = false;
   g_lockReason = "";

   if(GuardOn())
     {
      double limit = (g_effMaxLossPct > 0.0) ? d_startBalance * g_effMaxLossPct / 100.0 : 0.0;
      if(g_effMaxLosses > 0 && d_losses >= g_effMaxLosses)
        {
         g_lossLocked = true;
         g_lockReason = "LOSS LOCK: " + IntegerToString(d_losses) + "/" + IntegerToString(g_effMaxLosses) +
                        " losses today. No override - resets next day.";
        }
      else
         if(limit > 0.0 && -d_realized >= limit - 0.005)
           {
            g_lossLocked = true;
            g_lockReason = "LOSS LOCK: daily loss " + Money(d_realized) + " hit the " +
                           DoubleToString(g_effMaxLossPct, 2) + "% limit. No override.";
           }

      if(!g_lossLocked && InpMaxWinsPerDay > 0 && d_wins >= InpMaxWinsPerDay && !g_winOverride)
        {
         g_winLocked  = true;
         g_lockReason = "WIN LOCK: " + IntegerToString(d_wins) + "/" + IntegerToString(InpMaxWinsPerDay) +
                        " wins - done for today (override below).";
        }
     }

   if(g_lossLocked)
     {
      g_lockTime = LockTime("lockLoss");
      if(!wasLoss && !g_firstEval)
        {
         Notify(g_lockReason);
         if(InpDeletePendingsOnLock)
            DeleteAllPendings();
        }
     }
   else
      if(g_winLocked)
        {
         g_lockTime = LockTime("lockWin");
         if(!wasWin && !g_firstEval)
           {
            Notify(g_lockReason);
            if(InpDeletePendingsOnLock)
               DeleteAllPendings();
           }
        }
   g_firstEval = false;
  }

void RefreshDay()
  {
   datetime ds = DayStart();
   if(ds != d_start)
     {
      d_start = ds;
      g_lossLocked = false;
      g_winLocked  = false;
      LoadDayLimits();
     }
   ComputeDayStats();
   ComputeOpenRisk();
   EvaluateLocks();
  }

void DeleteAllPendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      ENUM_ORDER_TYPE ty = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ty == ORDER_TYPE_BUY || ty == ORDER_TYPE_SELL)
         continue;
      if(g_trade.OrderDelete(tk))
         Print("[RiskMgr] Guard deleted pending #", tk);
     }
  }

// While locked, anything opened after the lock (from this EA, one-click trading,
// mobile, another EA...) is closed / deleted. Existing trades are left alone.
void EnforceLocks()
  {
   if(!InpEnforceLock || !(g_lossLocked || g_winLocked))
      return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      ENUM_ORDER_TYPE ty = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ty == ORDER_TYPE_BUY || ty == ORDER_TYPE_SELL)
         continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) > g_lockTime)
         if(g_trade.OrderDelete(tk))
            Print("[RiskMgr] Guard deleted pending #", tk, " placed while locked");
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if((datetime)PositionGetInteger(POSITION_TIME) > g_lockTime)
        {
         g_trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));
         if(g_trade.PositionClose(tk))
            Print("[RiskMgr] Guard closed position #", tk, " opened while locked");
        }
     }
   g_trade.SetTypeFillingBySymbol(_Symbol);
  }

void OverrideWinLock()
  {
   if(!g_winLocked)
      return;
   int r = MessageBox("Override the WIN lock for the rest of today?\n\n"
                      "Loss limits (count and daily %) still apply and cannot be overridden.",
                      "Risk Manager - override win lock", MB_YESNO | MB_ICONWARNING);
   if(r != IDYES)
      return;
   GlobalVariableSet(GVKey("winOverride"), 1.0);
   GlobalVariablesFlush();
   g_winOverride = true;
   EvaluateLocks();
   Flash("Win lock overridden for today. Loss limits still active.", CLR_WARN);
  }

//+------------------------------------------------------------------+
//| Level placement                                                  |
//+------------------------------------------------------------------+
void LayoutLevels(double slDist)
  {
   double ask = Ask(), bid = Bid();
   int    minPts = StopsLevelPts() + 5;
   double off = MathMax(InpPendingOffsetPoints, minPts) * _Point;
   if(slDist <= 0.0)
      slDist = InpDefaultSLPoints * _Point;
   slDist = MathMax(slDist, minPts * _Point);

   if(g_kind == KIND_MARKET)
      g_entry = g_isBuy ? ask : bid;
   else
      if(g_kind == KIND_LIMIT)
         g_entry = g_isBuy ? ask - off : bid + off;
      else
         g_entry = g_isBuy ? ask + off : bid - off;
   g_entry = NormPrice(g_entry);
   g_sl    = NormPrice(g_isBuy ? g_entry - slDist : g_entry + slDist);
  }

void ResetLevels()
  {
   LayoutLevels(InpDefaultSLPoints * _Point);
  }

// keep the current SL distance when switching direction / order kind
double CurrentSLDist()
  {
   double d = MathAbs(g_entry - g_sl);
   return (d > 0.0) ? d : InpDefaultSLPoints * _Point;
  }

// When the user moves a pending entry across price, flip LIMIT <-> STOP automatically.
void AutoPendingKind()
  {
   if(g_kind == KIND_MARKET)
      return;
   int k;
   if(g_isBuy)
      k = (g_entry < Ask()) ? KIND_LIMIT : KIND_STOP;
   else
      k = (g_entry > Bid()) ? KIND_LIMIT : KIND_STOP;
   if(k != g_kind)
     {
      g_kind = k;
      Flash("Order type switched to " + (g_isBuy ? "BUY " : "SELL ") + KindName(k), CLR_WARN, 3000);
     }
  }

//+------------------------------------------------------------------+
//| Chart objects                                                    |
//+------------------------------------------------------------------+
void MkRect(const string n, int x, int y, int w, int h, color bg, color border)
  {
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_COLOR, border);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 0);
  }

void MkLabel(const string n, int x, int y, const string text, color clr, int size = 9,
             ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER, const string font = "Segoe UI")
  {
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, n, OBJPROP_FONT, font);
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 5);
  }

void MkButton(const string n, int x, int y, int w, int h, const string text, color bg, color fg, int size = 9)
  {
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, CLR_BORDER);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetInteger(0, n, OBJPROP_STATE, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);
  }

void MkEdit(const string n, int x, int y, int w, int h, const string text)
  {
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, CLR_EDIT);
   ObjectSetInteger(0, n, OBJPROP_COLOR, CLR_TXT);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, CLR_BORDER);
   ObjectSetInteger(0, n, OBJPROP_ALIGN, ALIGN_RIGHT);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetInteger(0, n, OBJPROP_READONLY, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);
  }

void SetText(const string n, const string t)
  {
   if(ObjectGetString(0, n, OBJPROP_TEXT) != t)
      ObjectSetString(0, n, OBJPROP_TEXT, t);
  }

void SetColor(const string n, const color c)
  {
   if((color)ObjectGetInteger(0, n, OBJPROP_COLOR) != c)
      ObjectSetInteger(0, n, OBJPROP_COLOR, c);
  }

void SetBg(const string n, const color c)
  {
   if((color)ObjectGetInteger(0, n, OBJPROP_BGCOLOR) != c)
      ObjectSetInteger(0, n, OBJPROP_BGCOLOR, c);
  }

void KV(const string key, int x, int y, int w, const string label)
  {
   MkLabel("RM_k_" + key, x, y, label, CLR_TXT2, 9);
   MkLabel("RM_v_" + key, x + w, y, "", CLR_TXT, 9, ANCHOR_RIGHT_UPPER);
  }

void BuildPanel()
  {
   int x = InpPanelX, y = InpPanelY, W = PANEL_W;
   int cx = x + 10, iw = W - 20;
   int cy = y + 8;

   MkRect(O_BG, x, y, W, 600, CLR_BG, CLR_BORDER);
   MkLabel("RM_title", cx, cy, "RISK MANAGER", CLR_TXT, 10, ANCHOR_LEFT_UPPER, "Segoe UI Semibold");
   MkLabel("RM_sym", cx + iw, cy + 1, _Symbol, CLR_TXT2, 9, ANCHOR_RIGHT_UPPER);
   cy += 24;

   int bw = (iw - 6) / 2;
   MkButton(B_BUY,  cx,          cy, bw, 28, "BUY",  CLR_BUY, clrWhite, 10);
   MkButton(B_SELL, cx + bw + 6, cy, bw, 28, "SELL", CLR_OFF, clrWhite, 10);
   cy += 34;

   int tw = (iw - 12) / 3;
   MkButton(B_MKT, cx,                cy, tw, 22, "MARKET", CLR_ON,  CLR_TXT, 8);
   MkButton(B_LMT, cx + tw + 6,       cy, tw, 22, "LIMIT",  CLR_OFF, CLR_TXT, 8);
   MkButton(B_STP, cx + 2 * (tw + 6), cy, tw, 22, "STOP",   CLR_OFF, CLR_TXT, 8);
   cy += 30;

   int ex = cx + 48;      // edit column
   MkLabel("RM_l_risk", cx, cy + 3, "Risk", CLR_TXT2, 9);
   MkEdit(E_RISK, ex, cy, 84, 20, "");
   MkButton(B_RMODE, ex + 88, cy, 44, 20, "%", CLR_OFF, CLR_TXT, 8);
   MkLabel("RM_riskinfo", cx + iw, cy + 3, "", CLR_TXT2, 8, ANCHOR_RIGHT_UPPER);
   cy += 26;

   MkLabel("RM_l_entry", cx, cy + 3, "Entry", CLR_TXT2, 9);
   MkEdit(E_ENTRY, ex, cy, 110, 20, "");
   MkLabel("RM_entryinfo", cx + iw, cy + 3, "", CLR_TXT2, 8, ANCHOR_RIGHT_UPPER);
   cy += 26;

   MkLabel("RM_l_sl", cx, cy + 3, "SL", InpSLColor, 9);
   MkEdit(E_SL, ex, cy, 110, 20, "");
   MkLabel("RM_l_slpts", ex + 116, cy + 3, "pts", CLR_TXT2, 8);
   MkEdit(E_SLPTS, cx + iw - 72, cy, 72, 20, "");
   cy += 26;

   MkLabel("RM_l_tp", cx, cy + 3, "TP", InpTPColor, 9);
   MkEdit(E_TP, ex, cy, 110, 20, "");
   MkLabel("RM_l_rr", ex + 116, cy + 3, "R:R", CLR_TXT2, 8);
   MkEdit(E_RR, cx + iw - 72, cy, 72, 20, "");
   cy += 30;

   MkRect("RM_sep1", cx, cy, iw, 1, CLR_BORDER, CLR_BORDER);
   cy += 8;

   MkLabel("RM_k_lots", cx, cy + 2, "Lot size", CLR_TXT2, 9);
   MkLabel("RM_v_lots", cx + iw, cy, "", CLR_TXT, 13, ANCHOR_RIGHT_UPPER, "Segoe UI Semibold");
   cy += 26;
   KV("risk",   cx, cy, iw, "Risk");        cy += 18;
   KV("reward", cx, cy, iw, "Reward");      cy += 18;
   KV("margin", cx, cy, iw, "Margin");      cy += 18;
   KV("dist",   cx, cy, iw, "SL / spread"); cy += 18;
   MkLabel("RM_capnote", cx, cy, "", CLR_WARN, 8);
   cy += 18;

   MkRect("RM_sep2", cx, cy, iw, 1, CLR_BORDER, CLR_BORDER);
   cy += 8;

   MkLabel("RM_guardhdr", cx, cy, "DAILY GUARD", CLR_TXT, 9, ANCHOR_LEFT_UPPER, "Segoe UI Semibold");
   MkLabel("RM_guardstate", cx + iw, cy, "", CLR_OK, 9, ANCHOR_RIGHT_UPPER, "Segoe UI Semibold");
   cy += 20;
   KV("losses", cx, cy, iw, "Losses today");     cy += 18;
   KV("wins",   cx, cy, iw, "Wins today");       cy += 18;
   KV("daypl",  cx, cy, iw, "Day P/L");          cy += 18;
   KV("budget", cx, cy, iw, "Loss budget left"); cy += 22;

   MkRect("RM_sep3", cx, cy, iw, 1, CLR_BORDER, CLR_BORDER);
   cy += 6;
   MkLabel("RM_status1", cx, cy, "", CLR_TXT, 8);
   cy += 14;
   MkLabel("RM_status2", cx, cy, "", CLR_TXT, 8);
   cy += 20;

   MkButton(B_PLACE, cx, cy, iw, 36, "PLACE ORDER", CLR_BUY, clrWhite, 10);
   cy += 42;

   int sw = (iw - 12) / 3;
   MkButton(B_RESET,   cx,                cy, sw, 22, "Reset lines", CLR_OFF, CLR_TXT, 8);
   MkButton(B_CLOSE,   cx + sw + 6,       cy, sw, 22, "Close trades", CLR_OFF, CLR_TXT, 8);
   MkButton(B_DELPEND, cx + 2 * (sw + 6), cy, sw, 22, "Del pendings", CLR_OFF, CLR_TXT, 8);
   cy += 30;

   g_overrideY = cy;
   g_bgH = cy - y;
   ObjectSetInteger(0, O_BG, OBJPROP_YSIZE, g_bgH);
  }

void HLine(const string n, const double price, const color c, const ENUM_LINE_STYLE st)
  {
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, n, OBJPROP_SELECTED, true);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_BACK, false);
      ObjectSetInteger(0, n, OBJPROP_ZORDER, 20);
     }
   else
      if(MathAbs(ObjectGetDouble(0, n, OBJPROP_PRICE) - price) > _Point / 10.0)
         ObjectMove(0, n, 0, 0, price);
   SetColor(n, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
  }

void Zone(const string n, const double p1, const double p2, const color c, datetime t1, datetime t2)
  {
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, n, OBJPROP_FILL, true);
      ObjectSetInteger(0, n, OBJPROP_BACK, true);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectMove(0, n, 0, t1, p1);
      ObjectMove(0, n, 1, t2, p2);
     }
   SetColor(n, c);
  }

void PriceText(const string n, const datetime t, const double p, const string text, const color c)
  {
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_TEXT, 0, t, p);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, n, 0, t, p);
   SetText(n, text);
   SetColor(n, c);
  }

void SyncLines()
  {
   if(g_kind == KIND_MARKET)
      ObjectDelete(0, L_ENTRY);
   else
      HLine(L_ENTRY, g_entry, InpEntryColor, STYLE_SOLID);
   HLine(L_SL, g_sl, InpSLColor, STYLE_DASH);
   if(g_tp > 0.0)
      HLine(L_TP, g_tp, InpTPColor, STYLE_DASH);
   else
      ObjectDelete(0, L_TP);

   int bars = (int)MathMin(40, Bars(_Symbol, _Period) - 1);
   datetime t1 = iTime(_Symbol, _Period, MathMax(bars, 0));
   datetime t2 = iTime(_Symbol, _Period, 0) + PeriodSeconds() * 12;

   if(InpShowZones)
     {
      Zone(Z_SL, g_entry, g_sl, InpSLZoneColor, t1, t2);
      if(g_tp > 0.0)
         Zone(Z_TP, g_entry, g_tp, InpTPZoneColor, t1, t2);
      else
         ObjectDelete(0, Z_TP);
     }

   string lots = DoubleToString(c_lots, LotDigits());
   PriceText(T_ENTRY, t2, g_entry,
             (g_isBuy ? "BUY " : "SELL ") + KindName(g_kind) + "  " + lots + " lots", InpEntryColor);
   PriceText(T_SL, t2, g_sl,
             "SL  " + Money(-c_riskMoney) + "  (" + DoubleToString(c_riskPct, 2) + "%)", InpSLColor);
   if(g_tp > 0.0)
      PriceText(T_TP, t2, g_tp, "TP  " + Money(c_reward, true) + "  (" + DoubleToString(g_rr, 2) + "R)", InpTPColor);
   else
      ObjectDelete(0, T_TP);
  }

// Detect user drags of the lines. Returns true if anything moved.
bool CheckLines()
  {
   bool moved = false;
   if(g_kind != KIND_MARKET && ObjectFind(0, L_ENTRY) >= 0)
     {
      double p = NormPrice(ObjectGetDouble(0, L_ENTRY, OBJPROP_PRICE));
      if(MathAbs(p - g_entry) > _Point / 2.0)
        {
         g_entry = p;
         AutoPendingKind();
         moved = true;
        }
     }
   if(ObjectFind(0, L_SL) >= 0)
     {
      double p = NormPrice(ObjectGetDouble(0, L_SL, OBJPROP_PRICE));
      if(MathAbs(p - g_sl) > _Point / 2.0)
        {
         g_sl = p;
         moved = true;
        }
     }
   if(ObjectFind(0, L_TP) >= 0 && g_tp > 0.0)
     {
      double p = NormPrice(ObjectGetDouble(0, L_TP, OBJPROP_PRICE));
      if(MathAbs(p - g_tp) > _Point / 2.0)
        {
         double dist = MathAbs(g_entry - g_sl);
         double rr = (dist > 0.0) ? (g_isBuy ? p - g_entry : g_entry - p) / dist : 0.0;
         if(rr > 0.0)
            g_rr = NormalizeDouble(rr, 2);
         else
            Flash("TP must be on the profit side of entry", CLR_ERR, 3000);
         moved = true;
        }
     }
   return moved;
  }

void UpdatePanel()
  {
   SetBg(B_BUY,  g_isBuy ? CLR_BUY : CLR_OFF);
   SetBg(B_SELL, !g_isBuy ? CLR_SELL : CLR_OFF);
   SetBg(B_MKT, g_kind == KIND_MARKET ? CLR_ON : CLR_OFF);
   SetBg(B_LMT, g_kind == KIND_LIMIT  ? CLR_ON : CLR_OFF);
   SetBg(B_STP, g_kind == KIND_STOP   ? CLR_ON : CLR_OFF);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   SetText(B_RMODE, g_riskMoneyMode ? Ccy() : "%");
   SetText(E_RISK, DoubleToString(g_riskInput, 2));
   if(g_riskMoneyMode)
      SetText("RM_riskinfo", "= " + DoubleToString(bal > 0 ? g_riskInput / bal * 100.0 : 0, 2) + "%");
   else
      SetText("RM_riskinfo", "= " + Money(c_requested));

   SetText(E_ENTRY, DoubleToString(g_entry, _Digits));
   bool ro = (g_kind == KIND_MARKET);
   if((bool)ObjectGetInteger(0, E_ENTRY, OBJPROP_READONLY) != ro)
      ObjectSetInteger(0, E_ENTRY, OBJPROP_READONLY, ro);
   SetBg(E_ENTRY, ro ? CLR_RO : CLR_EDIT);
   if(ro)
      SetText("RM_entryinfo", "live " + (g_isBuy ? "Ask" : "Bid"));
   else
     {
      double ref = g_isBuy ? Ask() : Bid();
      SetText("RM_entryinfo", DoubleToString(MathAbs(g_entry - ref) / _Point, 0) + " pts away");
     }

   SetText(E_SL, DoubleToString(g_sl, _Digits));
   SetText(E_SLPTS, DoubleToString(c_slPoints, 0));
   SetText(E_TP, g_tp > 0.0 ? DoubleToString(g_tp, _Digits) : "none");
   SetText(E_RR, DoubleToString(g_rr, 2));

   //--- results
   SetText("RM_v_lots", DoubleToString(c_lots, LotDigits()));
   SetColor("RM_v_lots", c_lots > 0.0 ? CLR_TXT : CLR_ERR);
   SetText("RM_v_risk", Money(c_riskMoney) + "  (" + DoubleToString(c_riskPct, 2) + "%)");
   SetColor("RM_v_risk", CLR_ERR);
   SetText("RM_v_reward", g_tp > 0.0 ? Money(c_reward, true) + "  (1:" + DoubleToString(g_rr, 2) + ")" : "no TP");
   SetColor("RM_v_reward", CLR_OK);
   SetText("RM_v_margin", Money(c_margin) + "  / free " + Money(AccountInfoDouble(ACCOUNT_MARGIN_FREE)));
   SetText("RM_v_dist", DoubleToString(c_slPoints, 0) + " pts (" + DoubleToString(c_slPoints / PipFactor(), 1) +
           " pips)  /  " + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)));
   SetText("RM_capnote", c_capNote == "" ? "" : "Risk " + c_capNote);

   //--- guard
   if(!GuardOn())
     {
      SetText("RM_guardstate", "OFF");
      SetColor("RM_guardstate", CLR_TXT2);
     }
   else
      if(g_lossLocked)
        {
         SetText("RM_guardstate", "LOSS LOCK");
         SetColor("RM_guardstate", CLR_ERR);
        }
      else
         if(g_winLocked)
           {
            SetText("RM_guardstate", "WIN LOCK");
            SetColor("RM_guardstate", CLR_WARN);
           }
         else
           {
            SetText("RM_guardstate", g_winOverride ? "ACTIVE (win override)" : "ACTIVE");
            SetColor("RM_guardstate", CLR_OK);
           }

   SetText("RM_v_losses", IntegerToString(d_losses) + " / " + (g_effMaxLosses > 0 ? IntegerToString(g_effMaxLosses) : "off"));
   SetColor("RM_v_losses", (g_effMaxLosses > 0 && d_losses >= g_effMaxLosses) ? CLR_ERR : CLR_TXT);
   SetText("RM_v_wins", IntegerToString(d_wins) + " / " + (InpMaxWinsPerDay > 0 ? IntegerToString(InpMaxWinsPerDay) : "off"));
   double dayPct = d_startBalance > 0 ? d_realized / d_startBalance * 100.0 : 0.0;
   SetText("RM_v_daypl", Money(d_realized, true) + "  (" + DoubleToString(dayPct, 2) + "%)");
   SetColor("RM_v_daypl", d_realized < 0 ? CLR_ERR : (d_realized > 0 ? CLR_OK : CLR_TXT));
   if(c_budgetLeft == DBL_MAX)
      SetText("RM_v_budget", "off");
   else
      SetText("RM_v_budget", Money(MathMax(0.0, c_budgetLeft)) + "  (open risk " + Money(d_openRisk) + ")");

   //--- status
   string err = Validate();
   string msg;
   color  mc;
   if(g_flash != "" && GetTickCount() < g_flashUntil)
     {
      msg = g_flash;
      mc = g_flashColor;
     }
   else
      if(err != "")
        {
         msg = err;
         mc = (g_winLocked && !g_lossLocked) ? CLR_WARN : CLR_ERR;
        }
      else
        {
         msg = "Ready - " + (g_isBuy ? "BUY " : "SELL ") + KindName(g_kind) + " " +
               DoubleToString(c_lots, LotDigits()) + " lots, risk " + Money(c_riskMoney);
         mc = CLR_OK;
        }
   string s1 = msg, s2 = "";
   if(StringLen(msg) > 52)
     {
      int cut = 52;
      for(int i = 52; i > 30; i--)
         if(StringGetCharacter(msg, i) == ' ')
           {
            cut = i;
            break;
           }
      s1 = StringSubstr(msg, 0, cut);
      s2 = StringSubstr(msg, cut + 1);
     }
   SetText("RM_status1", s1);
   SetText("RM_status2", s2);
   SetColor("RM_status1", mc);
   SetColor("RM_status2", mc);

   //--- place button
   SetText(B_PLACE, (g_isBuy ? "BUY " : "SELL ") + (g_kind == KIND_MARKET ? "MARKET" : KindName(g_kind)) +
           "   " + DoubleToString(c_lots, LotDigits()) + " lots");
   SetBg(B_PLACE, err != "" ? CLR_DIS : (g_isBuy ? CLR_BUY : CLR_SELL));

   //--- override button only while win-locked
   if(g_winLocked)
     {
      if(ObjectFind(0, B_OVERRIDE) < 0)
         MkButton(B_OVERRIDE, InpPanelX + 10, g_overrideY, PANEL_W - 20, 24, "OVERRIDE WIN LOCK (today)", C'120,80,20', clrWhite, 9);
      ObjectSetInteger(0, O_BG, OBJPROP_YSIZE, g_bgH + 30);
     }
   else
     {
      if(ObjectFind(0, B_OVERRIDE) >= 0)
         ObjectDelete(0, B_OVERRIDE);
      ObjectSetInteger(0, O_BG, OBJPROP_YSIZE, g_bgH);
     }
  }

void RefreshAll()
  {
   Recalc();
   SyncLines();
   UpdatePanel();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Trading                                                          |
//+------------------------------------------------------------------+
void PendingTime(ENUM_ORDER_TYPE_TIME &tt, datetime &exp)
  {
   int modes = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   exp = 0;
   if(InpPendingExpiry == RM_EXP_DAY)
     {
      if((modes & SYMBOL_EXPIRATION_DAY) != 0)
        {
         tt = ORDER_TIME_DAY;
         return;
        }
      if((modes & SYMBOL_EXPIRATION_SPECIFIED) != 0)
        {
         tt = ORDER_TIME_SPECIFIED;
         exp = d_start + 86400 - 60;
         return;
        }
     }
   if((modes & SYMBOL_EXPIRATION_GTC) != 0)
     {
      tt = ORDER_TIME_GTC;
      return;
     }
   tt = ORDER_TIME_DAY;
  }

void PlaceOrder()
  {
   g_forceDayRefresh = false;
   RefreshDay();            // always decide on fresh guard state
   Recalc();
   string err = Validate();
   if(err != "")
     {
      Flash(err, CLR_ERR);
      return;
     }

   string side = (g_isBuy ? "BUY " : "SELL ") + KindName(g_kind);
   if(InpConfirmOrders)
     {
      string txt = side + "  " + _Symbol + "\n\n" +
                   "Lots:   " + DoubleToString(c_lots, LotDigits()) + "\n" +
                   "Entry:  " + (g_kind == KIND_MARKET ? "market (~" + DoubleToString(g_entry, _Digits) + ")" : DoubleToString(g_entry, _Digits)) + "\n" +
                   "SL:     " + DoubleToString(g_sl, _Digits) + "  (" + DoubleToString(c_slPoints, 0) + " pts)\n" +
                   "TP:     " + (g_tp > 0.0 ? DoubleToString(g_tp, _Digits) + "  (R:R 1:" + DoubleToString(g_rr, 2) + ")" : "none") + "\n\n" +
                   "Risk:   " + Money(c_riskMoney) + "  (" + DoubleToString(c_riskPct, 2) + "% of balance)\n" +
                   "Reward: " + (g_tp > 0.0 ? Money(c_reward) : "-") +
                   (c_capNote != "" ? "\n\nNote: risk " + c_capNote : "");
      if(MessageBox(txt, "Risk Manager - confirm order", MB_OKCANCEL | MB_ICONQUESTION) != IDOK)
        {
         Flash("Order cancelled", CLR_TXT2, 2500);
         return;
        }
      // price may have moved while the dialog was open - recompute and re-check
      RefreshDay();
      Recalc();
      err = Validate();
      if(err != "")
        {
         Flash(err, CLR_ERR);
         return;
        }
     }

   double lots  = c_lots;
   double sl    = NormPrice(g_sl);
   double tp    = (g_tp > 0.0) ? NormPrice(g_tp) : 0.0;
   double price = NormPrice(g_entry);
   ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
   datetime exp = 0;
   PendingTime(tt, exp);

   g_trade.SetTypeFillingBySymbol(_Symbol);
   bool ok = false;
   switch(CurrentOrderType())
     {
      case ORDER_TYPE_BUY:
         ok = g_trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment);
         break;
      case ORDER_TYPE_SELL:
         ok = g_trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment);
         break;
      case ORDER_TYPE_BUY_LIMIT:
         ok = g_trade.BuyLimit(lots, price, _Symbol, sl, tp, tt, exp, InpComment);
         break;
      case ORDER_TYPE_SELL_LIMIT:
         ok = g_trade.SellLimit(lots, price, _Symbol, sl, tp, tt, exp, InpComment);
         break;
      case ORDER_TYPE_BUY_STOP:
         ok = g_trade.BuyStop(lots, price, _Symbol, sl, tp, tt, exp, InpComment);
         break;
      case ORDER_TYPE_SELL_STOP:
         ok = g_trade.SellStop(lots, price, _Symbol, sl, tp, tt, exp, InpComment);
         break;
      default:
         break;
     }

   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      Flash(side + " " + DoubleToString(lots, LotDigits()) + " sent, risk " + Money(c_riskMoney), CLR_OK);
      if(g_kind == KIND_MARKET)
         EnsureStopsOnFill(sl, tp);
     }
   else
      Flash("Order failed: " + IntegerToString(rc) + " " + g_trade.ResultRetcodeDescription(), CLR_ERR, 10000);

   g_forceDayRefresh = true;
  }

// Some brokers ignore SL/TP on market execution - attach them right after the fill.
void EnsureStopsOnFill(const double sl, const double tp)
  {
   ulong deal = g_trade.ResultDeal();
   if(deal == 0 || !HistoryDealSelect(deal))
      return;
   ulong pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(pos == 0 || !PositionSelectByTicket(pos))
      return;
   if(PositionGetDouble(POSITION_SL) <= 0.0)
     {
      if(g_trade.PositionModify(pos, sl, tp))
         Print("[RiskMgr] Attached SL/TP to position #", pos);
      else
         Notify("Position #" + (string)pos + " opened WITHOUT SL and modify failed - set it manually NOW!");
     }
  }

void CloseSymbolPositions()
  {
   if(MessageBox("Close all " + _Symbol + " positions opened by this EA?", "Risk Manager",
                 MB_YESNO | MB_ICONQUESTION) != IDYES)
      return;
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(g_trade.PositionClose(tk))
         n++;
     }
   Flash("Closed " + IntegerToString(n) + " position(s)", CLR_TXT);
   g_forceDayRefresh = true;
  }

void DeleteSymbolPendings()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      ENUM_ORDER_TYPE ty = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ty == ORDER_TYPE_BUY || ty == ORDER_TYPE_SELL)
         continue;
      if(g_trade.OrderDelete(tk))
         n++;
     }
   Flash("Deleted " + IntegerToString(n) + " pending order(s)", CLR_TXT);
   g_forceDayRefresh = true;
  }

//+------------------------------------------------------------------+
//| Edits                                                            |
//+------------------------------------------------------------------+
void HandleEdit(const string name)
  {
   string txt = ObjectGetString(0, name, OBJPROP_TEXT);
   StringReplace(txt, ",", ".");
   double v = StringToDouble(txt);

   if(name == E_RISK)
     {
      if(v <= 0.0)
        {
         Flash("Risk must be > 0", CLR_ERR, 3000);
         return;
        }
      g_riskInput = v;
      if(!g_riskMoneyMode && InpMaxRiskPct > 0.0 && v > InpMaxRiskPct)
        {
         g_riskInput = InpMaxRiskPct;
         Flash("Risk capped at max " + DoubleToString(InpMaxRiskPct, 2) + "% per trade", CLR_WARN);
        }
     }
   else
      if(name == E_ENTRY)
        {
         if(g_kind == KIND_MARKET || v <= 0.0)
            return;
         g_entry = NormPrice(v);
         AutoPendingKind();
        }
      else
         if(name == E_SL)
           {
            if(v > 0.0)
               g_sl = NormPrice(v);
           }
         else
            if(name == E_SLPTS)
              {
               if(v > 0.0)
                  g_sl = NormPrice(g_isBuy ? g_entry - v * _Point : g_entry + v * _Point);
              }
            else
               if(name == E_TP)
                 {
                  double dist = MathAbs(g_entry - g_sl);
                  if(v <= 0.0 || dist <= 0.0)
                     return;
                  double rr = (g_isBuy ? v - g_entry : g_entry - v) / dist;
                  if(rr > 0.0)
                     g_rr = NormalizeDouble(rr, 2);
                  else
                     Flash("TP must be on the profit side of entry", CLR_ERR, 3000);
                 }
               else
                  if(name == E_RR)
                    {
                     if(v >= 0.0)
                        g_rr = NormalizeDouble(v, 2);
                    }
  }

//+------------------------------------------------------------------+
//| Event handlers                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpDefaultRisk <= 0.0)
     {
      Print("[RiskMgr] Default risk must be > 0");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   // Keep the user's setup across timeframe changes; reset on a new symbol.
   if(!g_ready || g_stateSymbol != _Symbol)
     {
      g_riskMoneyMode = (InpRiskMode == RM_RISK_MONEY);
      g_riskInput     = InpDefaultRisk;
      if(!g_riskMoneyMode && InpMaxRiskPct > 0.0 && g_riskInput > InpMaxRiskPct)
         g_riskInput = InpMaxRiskPct;
      g_rr   = MathMax(0.0, InpDefaultRR);
      g_isBuy = true;
      g_kind  = KIND_MARKET;
      ResetLevels();
      g_stateSymbol = _Symbol;
      g_ready = true;
     }

   d_start = 0;           // force LoadDayLimits()
   g_firstEval = true;
   RefreshDay();
   BuildPanel();
   RefreshAll();
   EventSetMillisecondTimer(250);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

void OnTick()
  {
   // Timer drives the UI; ticks just keep market entry fresh.
   if(g_kind == KIND_MARKET)
     {
      Recalc();
      UpdatePanel();
     }
  }

void OnTimer()
  {
   uint now = GetTickCount();
   if(g_forceDayRefresh || now - g_lastDayRefresh >= 1000)
     {
      g_forceDayRefresh = false;
      g_lastDayRefresh = now;
      RefreshDay();
      EnforceLocks();
     }
   CheckLines();
   RefreshAll();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   g_forceDayRefresh = true;
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(StringFind(sparam, PFX) != 0)
         return;
      if(ObjectGetInteger(0, sparam, OBJPROP_TYPE) == OBJ_BUTTON)
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

      if(sparam == B_BUY && !g_isBuy)
        {
         double d = CurrentSLDist();
         g_isBuy = true;
         LayoutLevels(d);
        }
      else
         if(sparam == B_SELL && g_isBuy)
           {
            double d = CurrentSLDist();
            g_isBuy = false;
            LayoutLevels(d);
           }
         else
            if((sparam == B_MKT || sparam == B_LMT || sparam == B_STP))
              {
               int k = (sparam == B_MKT) ? KIND_MARKET : (sparam == B_LMT ? KIND_LIMIT : KIND_STOP);
               if(k != g_kind)
                 {
                  double d = CurrentSLDist();
                  g_kind = k;
                  LayoutLevels(d);
                 }
              }
            else
               if(sparam == B_RMODE)
                 {
                  double bal = AccountInfoDouble(ACCOUNT_BALANCE);
                  double base = (InpRiskMode == RM_RISK_PCT_EQUITY) ? AccountInfoDouble(ACCOUNT_EQUITY) : bal;
                  if(g_riskMoneyMode)
                    {
                     g_riskInput = (base > 0) ? NormalizeDouble(g_riskInput / base * 100.0, 2) : InpDefaultRisk;
                     g_riskMoneyMode = false;
                    }
                  else
                    {
                     g_riskInput = NormalizeDouble(base * g_riskInput / 100.0, 2);
                     g_riskMoneyMode = true;
                    }
                 }
               else
                  if(sparam == B_PLACE)
                     PlaceOrder();
                  else
                     if(sparam == B_RESET)
                        ResetLevels();
                     else
                        if(sparam == B_CLOSE)
                           CloseSymbolPositions();
                        else
                           if(sparam == B_DELPEND)
                              DeleteSymbolPendings();
                           else
                              if(sparam == B_OVERRIDE)
                                 OverrideWinLock();
      RefreshAll();
     }
   else
      if(id == CHARTEVENT_OBJECT_ENDEDIT)
        {
         if(StringFind(sparam, PFX) == 0)
           {
            HandleEdit(sparam);
            RefreshAll();
           }
        }
      else
         if(id == CHARTEVENT_OBJECT_DRAG)
           {
            if(StringFind(sparam, PFX) == 0)
              {
               CheckLines();
               RefreshAll();
              }
           }
         else
            if(id == CHARTEVENT_CHART_CHANGE)
               RefreshAll();
  }
//+------------------------------------------------------------------+
