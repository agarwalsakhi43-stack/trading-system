# Strategy Selector — How to Pick the Right Strategy

Use this guide to decide which strategy to apply to any stock or index before taking a trade.

---

## Step 1 — Identify the Instrument

**Is it Nifty or Sensex (an index)?**

→ Use **Dow Theory** on the **Weekly chart**
- Look for higher highs and higher lows = primary uptrend = Buy
- Lower lows breaking structure = primary downtrend = Stay out / Sell
- Hold horizon: 5 years
- Do not use candlestick or short-term strategies on indices

If it is a regular stock, proceed to Step 2.

---

## Step 2 — Decide Your Time Horizon

Choose your holding period first. Your time horizon determines your strategy.

---

### 6–9 Months → EMA 80 (preferred) or SMA 80

- Plot EMA 80 on the **Daily chart** — this is now the **default** choice, not SMA 80
- **Buy** when price crosses and closes **above** the line
- **Sell** when price crosses and closes **below** the line
- **Why EMA over SMA**: 2-year backtest (`backtest.sh`, see `backtest_results.txt`) showed EMA 80
  beating SMA 80 on RELIANCE (+5.7% vs +2.2%) and INFY (-20.3% vs -21.8%) — it reacts faster to
  price and gave a better result on both trending names tested. SMA 80 remains an acceptable
  fallback if you prefer smoother, less whipsaw-prone signals.
- **Exception**: for FMCG / Consumer sector stocks, skip this entirely — see the Sector Override below
- Always check the Golden Cross / Death Cross before entering (see Step 4)

---

### Sector Override — FMCG / Consumer Stocks → Prefer MACD (RSI-confirmed)

- Regardless of your intended holding period, if the stock's sector is **FMCG** or **Consumer**
  (including sub-tags like "Consumer Discretionary", "FMCG (Beverages)", etc.), use **MACD (12-26-9)**
  as the default strategy instead of SMA 80 / EMA 80
- **New: require RSI 14 confirmation.** Only take the MACD buy signal if **RSI(14) > 30** at the
  same time — i.e. the stock isn't still in an oversold breakdown. Apply this on top of the existing
  "both below zero" MACD condition.
- **Why RSI confirmation was added**: in the same 2-year backtest round, RSI 14 run *standalone*
  (buy when RSI crosses above 30 from below) was the single best-performing strategy tested on
  NESTLEIND — **+37.6% return, 50% win rate**, well ahead of MACD alone (+22.7%). Folding RSI's
  oversold-recovery logic into the MACD entry as a confirmation filter combines both signals rather
  than choosing one over the other.
- **Why MACD (with the original evidence)**: 2-year backtest on NESTLEIND (FMCG) showed MACD
  returning **+22.7%** with a **55.6% win rate**, dramatically beating EMA 80 (-11.1%) and SMA 80
  (-8.2%) on the same stock and window.
- **Caveat — thin evidence**: only one genuinely FMCG-tagged stock (NESTLEIND) was backtested here.
  PIDILITIND was tested alongside it expecting a similar "Consumer" profile, but this project's own
  sector data classifies PIDILITIND as **Chemicals**, not FMCG/Consumer — so it doesn't actually
  support this rule, even though MACD happened to be the least-bad MA-alternative for it too (-5.5%
  vs SMA 80 -11.9% / EMA 80 -12.9%). Treat this override as a strong lead from a single data point,
  not a validated sector-wide rule — worth backtesting more FMCG/Consumer names (HINDUNILVR, ITC,
  BRITANNIA, DABUR, MARICO, TATACONSUM, TITAN) before trusting it broadly.

---

### Sub-Override — Trending Consumer Names → Prefer Bollinger Breakout

- Within the FMCG/Consumer sector, a handful of names behave more like **trending breakout stocks**
  than range-bound staples. For these, prefer **Bollinger Bands (20, 2) breakout** over MACD:
  **Buy** when price crosses above the **upper band**; **Sell** when price falls back to the
  **middle band (SMA 20)**. Note this is the *opposite* of the mean-reversion Bollinger rule further
  down this doc (buy at the lower band) — it's a deliberately different, breakout-style variant.
- **Currently applies to: ASIANPAINT only.** 2-year backtest: Bollinger Breakout **+20.1%** vs
  RSI-confirmed MACD ≈ **+15.0%** vs buy-and-hold **-8.5%** — a meaningfully wider margin than the
  general FMCG/Consumer MACD edge.
- **Caveat — single-stock evidence, do not generalize yet.** This is based on exactly one ticker.
  There's no reliable rule yet for *which* Consumer names are "trending" enough to warrant this
  override versus staying on MACD — expand this list only after backtesting more candidates
  (e.g. TITAN, PIDILITIND-adjacent paints/building-materials names) and seeing the same pattern hold.

---

### 1–2 Months → MACD (12-26-9)

- Plot MACD on the **Daily chart**
- **Buy** when the MACD line crosses above the signal line **while both are below the zero line**
- The below-zero condition is critical — crossovers above zero are weaker signals
- **Sell** when MACD line crosses back below the signal line
- Hold for 1 to 1.5 months
- This is also the go-to strategy for FMCG/Consumer stocks regardless of horizon — see the Sector
  Override above

---

### 1–2 Weeks → Bollinger Bands (20, 2) — mean-reversion (default)

- Plot Bollinger Bands on the **Daily chart**
- **Buy** when price touches or breaks below the **lower band** and then reverses back inside
- **Target**: middle band (SMA 20) for conservative exit, upper band for full target
- **Sell / Exit** when price reaches the middle or upper band
- Avoid buying when bands are expanding sharply (high volatility, trend move — not mean reversion)
- **Note**: a separate *breakout* variant (buy above upper band, sell at middle) is used for trending
  Consumer names — see the Sub-Override above. Don't mix the two rules on the same stock.

---

### 5–10 Days → Candlestick Patterns

Look for one of the following patterns on the **Daily chart**. Trade only when the pattern appears after a clear downtrend.

| Pattern | What to Look For | Candles Needed | Status |
|---|---|---|---|
| **Bullish Engulfing** | Large green candle fully engulfs prior red candle's body | 2 (in 5-candle context) | Active |
| **Morning Star** | Red candle → small doji/spinning top → large green candle closing above red midpoint | 3 (in 6-candle context) | ⚠️ Low confidence |
| **Piercing Pattern** | Green candle opens below prior red candle's low, closes above its midpoint | 2 | ⚠️ Low confidence |
| ~~Bullish Harami~~ | ~~Small green candle contained inside prior large red candle's body~~ | 2 | ❌ Removed — see below |

**❌ Bullish Harami — removed from active strategies (as of this backtest round).** 2-year backtest
across 6 stocks, *with* the MACD/MA/RSI confirmation filter applied, still showed negative or flat
returns on 4 of 6 names, the lowest win rates of any strategy tested (14–32%), and the most trades
(10–22 per stock) generating the least edge. No real edge found even with confirmation — do not use
this pattern until/unless it's re-tested with a materially different confirmation rule.

**⚠️ Morning Star / Piercing Pattern — low confidence, insufficient sample size.** 2-year backtest
produced only 0–4 trades per stock for each pattern (vs. 6–22 for other strategies) — these patterns
are genuinely rare in daily NSE data. Any single trade swings the whole result, so don't trust their
backtested win rates/returns as real edge yet. Usable as a discretionary secondary confirmation, but
not as a standalone signal until tested over a longer window or larger stock universe produces enough
trades to mean something.

**Entry**: Buy at the close of the signal candle
**Exit**: After 5 days, or at your predefined target / stop loss

---

### Intraday → Support and Resistance

- Use the **5-minute chart**
- Mark key support and resistance levels from the previous day's high, low, and close, and from the current day's opening range
- **Buy** when price bounces from a support level with a confirming candle (e.g. bullish engulfing on 5m)
- **Sell short** when price rejects a resistance level with a confirming candle
- **Exit** at the next resistance (for longs) or next support (for shorts)
- Always set a stop loss — intraday moves can be fast
- Do not carry intraday positions overnight

---

## Step 3 — RSI 14 Confirmation (Apply to Any Strategy)

Regardless of which strategy you are using, always check RSI 14 on the Daily chart as an additional filter.

- **RSI crosses above 30 from below** = stock is recovering from oversold = **additional Buy confirmation**
- This adds conviction to any entry signal from Steps 2
- If RSI is above 70 (overbought), be cautious — avoid fresh buying even if another signal is present
- RSI alone is not a buy signal — it must support an existing setup

---

## Step 4 — Golden Cross and Death Cross Check (Long-Term Filter)

Before entering any positional trade (6–9 months or longer), check whether a Golden Cross or Death Cross has occurred recently.

| Signal | Condition | Action |
|---|---|---|
| **Golden Cross** | 50 DMA crosses **above** 200 DMA | Strong long-term **Buy** signal — confirms uptrend |
| **Death Cross** | 50 DMA crosses **below** 200 DMA | Strong **Sell / Avoid** signal — confirms downtrend |

- Plot both SMA 50 and SMA 200 on the Daily chart
- A Golden Cross appearing alongside an SMA 80 / EMA 80 crossover is a very high-confidence setup
- A Death Cross overrides all short-term buy signals — do not initiate positional longs during a Death Cross

---

## Quick Reference — Strategy Decision Tree

```
Is it Nifty or Sensex?
│
├── YES → Dow Theory (Weekly chart) — 5 year horizon
│
└── NO (regular stock)
    │
    ├── Sector = FMCG/Consumer AND a "trending" name (currently: ASIANPAINT only)?
    │     → Bollinger Breakout 20-2 (Daily, buy above upper band, sell at middle)
    │
    ├── Sector = FMCG or Consumer (otherwise)?
    │     → MACD 12-26-9 (Daily, below zero line only) + RSI(14) > 30 confirmation
    │       — overrides horizon-based choice below
    │
    ├── 6–9 months?   → EMA 80 (preferred) or SMA 80 (Daily)
    ├── 1–2 months?   → MACD 12-26-9 (Daily, below zero line only)
    ├── 1–2 weeks?    → Bollinger Bands 20-2 mean-reversion (Daily, lower band bounce)
    ├── 5–10 days?    → Candlestick patterns (Daily) — Engulfing (active),
    │                   Morning Star / Piercing (low confidence, use with caution)
    └── Intraday?     → Support & Resistance (5-minute chart)

Always check:
  → RSI 14: extra buy confirmation if crossing above 30 from below (required, not optional,
    for the FMCG/Consumer MACD override above)
  → Golden Cross: confirms long-term uptrend (strong buy)
  → Death Cross: confirms long-term downtrend (avoid longs / sell)
```

---

## Common Mistakes to Avoid

- Do not default to SMA 80 for a new positional trade — EMA 80 has the better 2-year backtest and
  should be your first choice; fall back to SMA 80 only if you specifically want smoother signals
- Do not use SMA 80 / EMA 80 crossover as the first choice for FMCG or Consumer sector stocks —
  MACD backtested far better on the one FMCG name tested (NESTLEIND); re-validate on more names
  before treating this as settled
- Do not take a FMCG/Consumer MACD buy signal without the RSI(14) > 30 confirmation — RSI's own
  recovery logic was the single best-performing strategy tested (+37.6% on NESTLEIND), so an
  unconfirmed MACD-only signal is leaving evidence on the table
- Do not use MACD as the default for ASIANPAINT (or other confirmed "trending Consumer" names) —
  Bollinger Breakout backtested meaningfully better there (+20.1% vs ~+15%)
- Do not use Dow Theory on individual stocks — it is for indices only
- Do not trade Bullish Harami at all — it's been removed from active strategies; 2yr backtest found
  no real edge even with confirmation applied
- Do not treat Morning Star or Piercing Pattern backtest results as reliable — sample sizes (0–4
  trades per stock) are too small to trust
- Do not buy at the lower Bollinger Band if bands are widening aggressively (mean-reversion variant
  only — doesn't apply to the breakout variant used for trending Consumer names)
- Do not enter positional longs when a Death Cross is active on the Daily chart
- RSI crossing 30 is a filter, not a standalone entry signal
- For intraday, always exit before market close — no overnight holds
