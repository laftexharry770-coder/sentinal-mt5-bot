# Sentinal Copier

Mirrors every position from one MetaTrader account onto any number of others.
The accounts can be at **different brokers**, with different symbol names,
different account sizes and different currencies.

Two EAs: put **Master** on the account you trade, **Slave** on each account that
should follow.

## How it works, and why it works across brokers

Terminals cannot talk to each other. What they *can* share is one folder:
MT4 and MT5 both map `FILE_COMMON` to the same
`…\AppData\Roaming\MetaQuotes\Terminal\Common\Files` directory, whatever broker
each terminal belongs to.

The master writes a snapshot of its open positions to
`Common\Files\SentinalCopy\<channel>.csv`; every slave reads it. No server, no
network, no account credentials anywhere.

The consequence is the one real constraint: **all terminals must run on the same
PC or VPS.** Copying between machines needs a relay server instead.

## Latency

- The master publishes **the instant a trade event fires** (`OnTradeTransaction`),
  not on the next timer tick.
- It also republishes on every tick and on a **100 ms** heartbeat, so a change
  can never sit unnoticed.
- Slaves poll every **100 ms** and on every tick, whichever comes first.
- The snapshot is written to a temp file and renamed, so a slave never reads a
  half-written file and never has to retry.

End to end on one VPS that is typically **100–250 ms** from master fill to slave
fill. Both intervals can go to 10 ms if you want to trade CPU for speed, though
below ~50 ms you are mostly measuring the brokers' own execution.

What you cannot remove is the slave broker's execution time and the price
difference between two brokers at the same instant. A copier makes the decision
travel quickly; it cannot make two brokers fill at one price.

## Setup

**On the master account's terminal**

1. Copy `SentinalCopier_Master.mq5` into `MQL5\Experts\SentinalCopier\`, F7
2. Attach to any one chart — the symbol does not matter, it publishes every position
3. Allow Algo Trading

**On each slave terminal**

1. Copy `SentinalCopier_Slave.mq5` into `MQL5\Experts\SentinalCopier\`, F7
2. Attach to any one chart, allow Algo Trading
3. `InpChannel` must match the master's exactly

The master panel shows `MASTER publishing`; each slave shows `COPYING` with the
master's login, its broker, and the live lot ratio.

## Sizing

`InpLotMode` decides how master lots become slave lots:

| Mode | Behaviour |
|---|---|
| `LOT_BALANCE_RATIO` *(default)* | slave balance ÷ master balance × master lot |
| `LOT_EQUITY_RATIO` | same, on equity |
| `LOT_MULTIPLIER` | master lot × `InpMultiplier` |
| `LOT_FIXED` | always `InpFixedLot` |

Every result is clamped to the slave broker's own min, max and step. On a small
slave account the broker minimum is a floor — a $100 account following a $10,000
master will trade 0.01 lots where the ratio asks for 0.001, which is
proportionally **ten times** the master's risk. `InpMaxLot` caps the other
direction.

## Symbols

Resolution runs in three steps: an explicit `InpSymbolMap` entry, then the exact
name, then a base-name match against everything the broker lists.

Base matching strips the decoration, so `XAUUSD` finds `XAUUSD.m`, `XAUUSDm`,
`XAUUSD_i` or `XAUUSD#` by itself. When it cannot, the log names the symbol it
could not place and `InpSymbolMap` takes overrides:

```
XAUUSD=XAUUSD.m,US30=US30.cash
```

## Stops

Stops and targets are copied as **distances from the master's own fill**, then
applied to the slave's fill. Two brokers quoting a few cents apart therefore get
the same risk in money, not the same absolute price. Distances below the slave
broker's minimum stop distance are widened to it.

Under `InpReverse` the two swap: the master's stop distance becomes the slave's
target and vice versa, because the master's stop being hit is the price moving
in the mirrored trade's favour.

## Safety behaviour

**A stale feed never closes anything.** If the master stops publishing, the
terminal is closed, or the file cannot be read, slaves *hold*. Missing data is
not evidence that the master closed its positions, and closing live trades on
that assumption is the worst thing a copier can do. Positions keep their own
stops. `InpMaxAgeSec` sets how old is too old; the panel shows the age.

**Closing the master EA publishes an offline marker** so slaves see the feed as
dead immediately rather than after the timeout.

**A copy closed by its own stop is not re-opened.** If the slave's stop or target
closes a position while the master still holds its own, that is finished
business — re-entering would be a new trade at a worse price, repeatedly. The
master ticket is remembered until it leaves the feed.

**Pre-existing trades are not adopted.** Positions already open when a slave
starts are skipped (`InpSkipOlderSec`): entering an hours-old position at today's
price is a different trade from the one the master took.

## MT4

The file protocol is platform-neutral and the Common folder is shared, so an MT4
terminal can take part in the same channel. **The MT4 EAs are not written yet** —
only the MT5 pair above exists today. Ask and they follow, using this same
channel format so the two platforms interoperate in either direction.
