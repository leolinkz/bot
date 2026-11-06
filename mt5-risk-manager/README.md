# MT5 Risk Manager EA

An on-chart trade panel for MetaTrader 5. You place every trade by hand through this panel, and
it sizes the lot from your risk, makes you set a stop loss, and applies a daily loss/win guard.

```
┌ RISK MANAGER ─────────── EURUSD ┐
│ [   BUY    ] [   SELL   ]       │   direction
│ [MARKET] [LIMIT] [STOP]         │   order type
│ Risk  [ 1.00][%]   = 100.00 USD │   % or money (toggle)
│ Entry [1.08500]     150 pts away│   editable for pending
│ SL    [1.08300] pts [   200]    │   price or distance
│ TP    [1.08900] R:R [  2.00]    │   price or R:R
│─────────────────────────────────│
│ Lot size                   0.50 │
│ Risk          100.00 USD (1.00%)│
│ Reward       +200.00 USD (1:2)  │
│ Margin / SL dist / spread       │
│─────────────────────────────────│
│ DAILY GUARD              ACTIVE │
│ Losses today              0 / 2 │
│ Wins today                0 / 1 │
│ Day P/L / loss budget left      │
│─────────────────────────────────│
│ status / reason it is blocked   │
│ [   BUY LIMIT   0.50 lots     ] │
│ [Reset][Close trades][Del pend] │
└─────────────────────────────────┘
```

## Install

1. In MT5: **File → Open Data Folder**, then open `MQL5/Experts/`.
2. Copy `RiskManagerEA.mq5` there.
3. Open it in **MetaEditor** (F4) and press **Compile** (F7). It should compile with 0 errors.
4. Drag **RiskManagerEA** onto a chart. On the *Common* tab, tick **Allow Algo Trading**.
5. Make sure the **Algo Trading** button on the toolbar is on (green).

> **Test it on a demo account first.** In the Strategy Tester, chart buttons don't respond to
> clicks, so you can only check the panel properly on a live demo chart.

## Placing a trade

1. Pick **BUY** or **SELL**, then **MARKET**, **LIMIT** or **STOP**.
2. Set the levels. Either drag the lines on the chart (blue = entry, red = SL, green = TP) or type
   into the boxes:
   - **SL**: a price, or a distance in points.
   - **TP**: a price, or an R:R. TP follows your R:R, so moving the entry or SL moves the TP with
     them. Dragging the TP line changes the R:R instead. Set R:R to `0` for no TP.
3. Look at the lot size, the risk, the reward and the status line.
4. Press the big button. A confirmation box shows the full order before anything is sent.

If you drag a pending entry to the other side of price, the order type switches between LIMIT and
STOP to match (for example, a buy entry above Ask becomes a Buy Stop).

## How the lot size is calculated

- **Loss per 1.0 lot** comes from MT5's `OrderCalcProfit(entry → SL)`, so it is correct for FX,
  JPY pairs, metals, indices, crypto and synthetics (Deriv V75 and similar) without any pip-value
  tables. The round-turn commission per lot is added on top.
- **Lots = allowed risk ÷ loss per lot**, always rounded **down** to the volume step. The EA never
  rounds up to a size that risks more than you set.
- **Allowed risk** is the smallest of:
  1. what you asked for (% of balance, % of equity, or a money amount);
  2. the **hard cap** `InpMaxRiskPct` (2% by default). Typing a higher value is refused;
  3. the **daily loss budget left**: daily limit − today's realised losses − worst-case loss of
     every open position and pending order on the account.
- If even the minimum lot would risk more than is allowed, the order is **blocked** and the panel
  tells you why. The EA doesn't quietly over-risk.
- Market orders are checked again *after* you confirm, using the live price. If the broker drops
  the SL/TP on a market fill, the EA adds them straight away. If it can't, it raises an alert.

## Every order is checked for

SL present and on the correct side · TP on the correct side · LIMIT/STOP on the correct side of
price · broker stops-level distance · minimum lot · free margin · symbol trade mode · Algo Trading
switched on · daily guard state · no unprotected (no-SL) trades open on the account.

## Daily guard

| Rule | Default | Override? |
|---|---|---|
| Max losing trades per day | 2 | **No** |
| Max daily loss (% of day-start balance) | 1% | **No** |
| Max winning trades per day ("1 win and done") | 1 | **Yes**, button on the panel |

- Wins and losses are counted per **closed position**, account-wide, net of commission and swap.
  The **breakeven tolerance** input lets near-zero results count as neither.
- The trading day resets at `InpDayResetHour` in **broker server time**.
- **Loss lock** lasts until the next trading day. No button, no input, no restart turns it off:
  - Today's limits are saved when the day starts. Changing the inputs mid-day can make them
    **tighter but not looser**.
  - Switching the guard off mid-day only takes effect the next day.
  - Restarting MT5 or reattaching the EA rebuilds the counts from the account history.
- **Win lock** shows an **OVERRIDE WIN LOCK** button. Press it and confirm, and the win limit is
  lifted for the rest of the day. The loss rules still apply.
- **When a lock triggers**, the EA alerts you (and sends a push notification if you turn that on)
  and deletes all pending orders.
- **Enforcer**: while a lock is active, any position or pending order opened *after* the lock is
  closed or deleted, wherever it came from (one-click trading, mobile, another EA). Trades that
  were already open stay as they are.
- **Daily budget sizing**: trades are sized so that, even if every open trade hits its SL, you
  don't go past the daily % limit. Profits made today **don't** add to the loss budget.

Limitation: today's limits and the override flag are saved in MT5 *global variables* (F3). Someone
who deletes those by hand could reset them. That is a deliberate obstacle, not a hard security
barrier. Stronger protection is on the list for later.

## Inputs (summary)

| Group | Inputs |
|---|---|
| Risk per trade | risk mode, default risk, hard cap %, commission/lot, max lots |
| Default levels | default SL points, pending offset points, default R:R |
| Daily guard | enable, max losses, max loss %, max wins, reset hour, breakeven tolerance, cap to budget, block if a trade has no SL, enforcer, delete pendings on lock, push |
| Execution | magic, slippage, pending expiry (GTC / end of day), confirm orders, comment |
| Panel | position, line and zone colours |

## Planned next (guard v2)

- Equity-based daily loss (count floating P/L as well), with an option to flatten everything.
- Override rules: allow only *N* extra trades after a win, or require a cooldown.
- Max trades per day, max open positions, a session/time window, and a cooldown after a loss.
- Break-even and partial-close buttons for open trades.
