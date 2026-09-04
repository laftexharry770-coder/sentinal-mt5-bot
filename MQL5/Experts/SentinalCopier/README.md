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

That is `TRANSPORT_FILE`, and it requires all terminals on the same PC or VPS.

For slaves on **other devices**, set `InpTransport` to `TRANSPORT_HTTP` on the
master and every slave. The master then POSTs each snapshot to a relay URL and
slaves GET it. `relay/copier_relay.py` is that relay - one file, no
dependencies, run it on any machine the terminals can reach:

```
python3 copier_relay.py --key A-LONG-SHARED-SECRET --port 8787
```

Put the same string in `InpRelayKey` on the master and every slave, and the same
`InpRelayUrl`. **Both terminals must whitelist the URL** in
*Tools > Options > Expert Advisors > Allow WebRequest for listed URL*, or every
request returns error 4014 and the slave panel says so.

The relay holds only the newest snapshot per channel, in memory. It never sees an
account password and cannot place a trade. Put it behind TLS if it faces the
open internet - the shared key is the only thing protecting the feed.

## Latency

- The master publishes **the instant a trade event fires** (`OnTradeTransaction`),
  not on the next timer tick.
- It also republishes on every tick and on a **100 ms** heartbeat, so a change
  can never sit unnoticed.
- Slaves poll every **100 ms** and on every tick, whichever comes first.
- The snapshot is written to a temp file and renamed, so a slave never reads a
  half-written file and never has to retry.

End to end on one VPS that is typically **100–250 ms** from master fill to slave
fill; over a relay, add the round trip to wherever you host it. Both intervals can go to 10 ms if you want to trade CPU for speed, though
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

## Pending orders

Pending orders are copied as orders, not waited on and then chased as market
entries - a straddle or breakout master holds nothing but pendings until one
triggers.

The level travels as a **distance from the master's market price** at the moment
it published, applied to the slave broker's market now. Copying the absolute
level would misplace the order by whatever the two brokers differ by, which on
gold is routinely cents.

When a master pending fills, its ticket carries over as the position id, so the
copy is recognised as the same trade and is not duplicated or closed. Reversed
copying is not applied to pendings: inverting a stop/limit straddle has no
single sensible meaning.

## Trailing stops and stop changes

Stops are **re-synced every cycle**, not just at entry. Whatever moves the
master's stop - a trailing EA, a manual drag, a break-even rule - the master
republishes within 100 ms and the slave matches the new distance on its own
entry.

`SyncStops` compares the master's current stop distance against the copy's and
modifies when they differ by more than 5 points, so a trailing stop follows
continuously without spamming the broker with identical modifications.

## Symbols

Resolution runs in three steps: an explicit `InpSymbolMap` entry, then the exact
name, then a base-name match against everything the broker lists.

Base matching strips decoration, so `XAUUSD` finds `XAUUSD.m`, `XAUUSDm`,
`XAUUSD_i` or `XAUUSD#` by itself. Brokers also rename instruments outright, so
an alias table folds the common ones together: `GOLD`/`XAUUSD`,
`SILVER`/`XAGUSD`, `US30`/`DJ30`/`WS30`, `NAS100`/`USTEC`/`US100`,
`SPX500`/`US500`, `GER40`/`DAX40`, `USOIL`/`WTI`, `UKOIL`/`BRENT`,
`BTCUSD`/`BITCOIN`. That is what lets an FxPro master trading `GOLD` feed an
Exness slave trading `XAUUSDm`. When it cannot, the log names the symbol it
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

## Web control panel

The relay also serves a page listing every slave, so day-to-day management
happens in a browser instead of MT5 input dialogs. Open `http://<host>:8787/`
and paste the relay key.

Each slave shows its account, broker, state, balance, live copy count and error
count, and carries two controls:

| Control | Effect |
|---|---|
| **Pause / Resume** | Stops *new* copies. Closes still follow the master, so pausing never strands a copy the master has already finished with. |
| **Multiplier** | Overrides `InpLotMode` entirely for that slave — resize one follower without restarting anything. |
| **Max lot** | Per-trade cap for that slave, overriding `InpMaxLot`. |

Slaves POST their status every `InpStatusMs` (2 s) and the control comes back in
the same reply, so it is one request per cycle rather than two. Set
`InpUsePanel` and either `InpPanelUrl` or `InpRelayUrl`; the panel works with
`TRANSPORT_FILE` too, so terminals sharing a VPS can still be managed remotely.

**The panel never places a trade.** It records what you want and the slave EA
reads it — the EA remains the only thing touching any account. If the panel goes
down, every slave keeps copying on its last known settings.

A slave silent for two minutes is shown as `OFFLINE` rather than quietly
dropping off the list.

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
