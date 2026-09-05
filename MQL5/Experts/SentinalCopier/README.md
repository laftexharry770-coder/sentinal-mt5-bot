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

### Which launcher to run

| Where the terminals are | Run | Address the EAs use |
|---|---|---|
| All on one PC or VPS | nothing - use `TRANSPORT_FILE` | shared Common folder |
| Different PCs, **same** network | `relay/START_RELAY.bat` | `http://<LAN IP>:8787` |
| Different PCs, **different** networks | `relay/START_PUBLIC.bat` | `https://<name>.trycloudflare.com` |

A LAN address is only reachable from the same network, so when the master and the
slaves are in different buildings the middle row cannot work no matter how the
EAs are configured.

`START_PUBLIC.bat` starts the relay and puts a **Cloudflare quick tunnel** in
front of it, giving a public HTTPS address with no account, no router changes and
no port forwarding. It needs `cloudflared.exe` - one file from
[the releases page](https://github.com/cloudflare/cloudflared/releases/latest),
renamed and dropped in the `relay/` folder - and it prints the exact
`InpRelayUrl` and `InpRelayKey` to paste into every terminal.

It verifies the tunnel actually answers before printing it, so an address it
shows you is one that works.

**A quick tunnel gets a new address every restart**, and MT5 only permits URLs
you have whitelisted, so every restart means re-whitelisting in every terminal.
That is fine for testing and tiresome as a routine. For anything you intend to
leave running, put `copier_relay.py` on a small VPS with a fixed address and
whitelist that once - the relay is one file with no dependencies and runs on the
cheapest box available.

## Slaves in different places

Any number of slaves, anywhere, follow one master over `TRANSPORT_HTTP`. They do
not need to be near the master, on the same network, or in the same country —
each one just needs to reach the relay URL. Set the same `InpChannel`,
`InpRelayUrl` and `InpRelayKey` on every slave and whitelist the URL in each
terminal; the relay keeps them apart by account number on the panel.

Two things behave differently once a slave is out on the internet rather than on
a LAN.

**The round trip sets the pace, not `InpPollMs`.** A slave 200 ms from the relay
learns about a trade in 200 ms no matter how often it asks, so polling every
100 ms just triples the requests for nothing. The slave panel shows
`Relay: round trip 180 ms (polling every 100 ms)` and the web panel has a `Link`
column; set `InpPollMs` to roughly the round trip and leave it there. Anything
under about 250 ms is fine for copying — the brokers' own execution is larger
than that.

**A dead link must not stall the copier.** MT5's `WebRequest` is synchronous: it
blocks the EA until the reply arrives or `InpHttpTimeoutMs` expires. Left
unchecked, a slave on a dropped connection spends its entire life blocked and
stops reconciling — which means it stops processing the master's **closes** too,
the one thing you cannot afford to miss. So a failed request backs off, doubling
from 1 s to a 30 s ceiling and resetting the moment the relay answers. The feed
and the status report back off independently, so an unreachable panel never
costs the feed a timeout.

While backed off the slave **holds**: it keeps its positions and their stops and
copies nothing new. That is the safe failure — a silent relay is not evidence
that the master closed anything.

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

## Choosing which trades to publish

By default the master publishes **everything** on the account. `InpOnlyMagic`
narrows that to a list of magic numbers in `InpMagicList`, comma separated:

```
InpOnlyMagic = true
InpMagicList = 0,12345,990001
```

One account often runs several EAs, each stamping its own magic, alongside
trades placed by hand. **Manual trades carry magic 0**, so listing `0` beside an
EA's magic copies both — that is how you mirror your own trading and one robot
while leaving a second robot out of it.

Spaces and a trailing comma are tolerated, duplicates collapse, and up to 64
magics are accepted. Anything that is not a number is rejected **at init** with
the offending entry named, rather than being read as 0 and silently widening the
filter to include every manual trade — `StringToInteger` returns 0 for
unparseable text, and 0 is itself a legitimate magic, so the text has to be
validated rather than just converted. Turning the filter on with an empty list
refuses to start too, since it would publish nothing at all.

The master panel shows `Magics: 0,12345,990001 only`, or `all (no filter)` when
it is off — a filter excluding trades you expected to see copied is otherwise
invisible from the chart.

`InpSymbolFilter` narrows by instrument in the same way, and the two combine.

## Sizing

`InpLotMode` decides how master lots become slave lots:

| Mode | Behaviour |
|---|---|
| `LOT_SAME` *(default)* | identical to the master, lot for lot |
| `LOT_BALANCE_RATIO` | slave balance ÷ master balance × master lot |
| `LOT_EQUITY_RATIO` | same, on equity |
| `LOT_MULTIPLIER` | master lot × `InpMultiplier` |
| `LOT_FIXED` | always `InpFixedLot` |

Every result is clamped to the slave broker's own min, max and step, and rounded
to the **nearest** step rather than down — flooring quietly turned a requested
0.10 into 0.09 wherever the step did not divide it exactly.

The slave panel shows `master 0.10 -> this 0.10` for the last trade sized. Equal
numbers are the quickest confirmation that sizing is doing what you asked; when
they differ the row turns gold and names the broker limit responsible.

`LOT_SAME` copies risk in *lots*, not in proportion. On a smaller slave account
that is proportionally larger risk than the master is taking — which is usually
the point of asking for it, but it is worth saying plainly. The ratio modes exist
for the other intent. Either way the broker minimum is a hard floor: a $100
account following a $10,000 master trades 0.01 where the ratio asks for 0.001.
`InpMaxLot` caps the other direction.

## Partial closes and add-ons

`InpCopyVolume` *(default on)* follows the master's size changes after entry.
Scale out of half a position on the master and the slave closes the same
proportion; add to a runner and the slave adds too.

This is driven by the **change** in the master's volume since the slave last
matched it, never by comparing against what the slave currently holds. That
distinction is what keeps the re-entry protection intact: a copy that the slave's
own stop has partly closed must never read as the master having added, or the EA
would pile back in against its own stop. Concretely — if your stop takes 0.06 off
a 0.10 copy and the master then goes from 0.10 to 0.15, the slave adds 0.05, not
0.11.

Reductions only ever close and additions only ever open, so neither direction can
undo what a stop already did. On a hedging account an add-on becomes a second
position carrying the same master tag; every lookup treats the group as one copy,
and trailing stops are applied to all of them.

## Pending orders

Pending orders are copied as orders, not waited on and then chased as market
entries - a straddle or breakout master holds nothing but pendings until one
triggers.

Under the default `PRICE_ABSOLUTE` the order goes in at the master's exact
level — a pending order is the one case where that can always be honoured, since
nothing has to fill right now. It is still nudged if it lands the wrong side of
this broker's market, which would otherwise be rejected outright.

`PRICE_DISTANCE` instead sends the level as a **distance from the master's
market price** at the moment it published, applied to the slave broker's market
now — the right choice when two brokers quote far enough apart that the master's
absolute level means something different on your account.

When a master pending fills, its ticket carries over as the position id, so the
copy is recognised as the same trade and is not duplicated or closed. Reversed
copying is not applied to pendings: inverting a stop/limit straddle has no
single sensible meaning.

## Trailing stops and stop changes

Stops are **re-synced every cycle**, not just at entry. Whatever moves the
master's stop - a trailing EA, a manual drag, a break-even rule - the master
republishes within 100 ms and the slave follows: to the same price under
`PRICE_ABSOLUTE`, to the same distance under `PRICE_DISTANCE`.

`SyncStops` compares the master's current stop distance against the copy's and
modifies when they differ by more than 5 points, so a trailing stop follows
continuously without spamming the broker with identical modifications. It is
applied to **every** position belonging to a master trade, so a trailing stop
still reaches a copy the master has scaled into more than once.

## Symbols

Any broker on either side. Resolution runs in three steps: an explicit
`InpSymbolMap` entry, then the exact name, then a base-name match against
everything the broker lists.

Base matching strips decoration from **both ends**, so `XAUUSD` finds
`XAUUSD.m`, `XAUUSDm`, `XAUUSD_i`, `XAUUSD#`, `XAUUSD.raw`, `XAUUSD-5`,
`XAUUSDmicro` and `mXAUUSD` by itself, and `FX_EURUSD` resolves to `EURUSD`
rather than to `FX`. It leaves real names alone: a broker listing `Gold` or
`Silver` keeps them whole instead of being cut to `GOL` and `SILV`, and
`US30Cash` reduces to `US30` while `XAUUSDm` keeps its `D`.

Brokers also rename instruments outright, so an alias table folds the common ones
together — gold, silver, platinum, palladium, the major indices
(`US30`/`DJ30`/`WS30`/`DJIA`, `NAS100`/`USTEC`/`US100`, `SPX500`/`US500`,
`GER40`/`DAX40`, `UK100`/`FTSE`, `JP225`/`NIKKEI`, `FRA40`, `AUS200`, `EU50`,
`HK50`, `US2000`), energy (`USOIL`/`WTI`/`CRUDE`, `UKOIL`/`BRENT`, `NATGAS`) and
crypto (`BTCUSD`/`BITCOIN`/`XBTUSD`, `ETHUSD`, `LTCUSD`, `XRPUSD`). That is what
lets an FxPro master trading `GOLD` feed a slave trading `XAUUSDm` — or
`XAUUSD.m`, or `Gold`, at any broker.

Where a broker lists several variants of one instrument, the first **tradable**
one wins; a close-only or disabled leftover is used only if nothing better
exists, and the log says so. When resolution fails entirely the log names the
symbol, the base it looked for, and the `InpSymbolMap` line that would fix it:

```
XAUUSD=XAUUSD.m,US30=US30.cash
```

## Stops and prices

`InpPriceMode` decides what "the same" means.

| Mode | Stops and targets | Pending order level |
|---|---|---|
| `PRICE_ABSOLUTE` *(default)* | the master's exact price | the master's exact price |
| `PRICE_DISTANCE` | the master's distance from its own fill | the master's distance from its own market |

**`PRICE_ABSOLUTE` puts the stop on the master's number.** Master stop at
3395.00, slave stop at 3395.00. A trailing master stop is republished within
100 ms and the copy is moved to the same new price, so both accounts show the
same levels throughout the life of the trade.

Two things can still move a level, and both are the broker's doing rather than
the copier's:

- **The level has to sit on the correct side of this broker's market.** If the
  two brokers quote far enough apart that the master's stop is already through
  the slave's price, it cannot go there.
- **Every broker enforces a minimum distance** between the market and a stop
  (`SYMBOL_TRADE_STOPS_LEVEL`), and they do not all use the same one.

When either applies, the level moves the smallest amount that makes it legal — a
stop a few points from where you asked for it beats no stop at all — and the
slave panel says `SL moved N pts to clear this broker's minimum`, with an `adj`
count in the session line and a `⚠` on the web panel. No note means every level
went on exactly where the master had it.

A level pinned to the broker's minimum drifts with the market, so the re-sync
tolerance widens to that gap; otherwise a pinned stop would be rewritten on
every tick.

### What absolute prices cannot do

**A market entry fills at the market.** If the master bought at 3401.55 and this
broker shows 3401.80 by the time the copy goes in, it fills at 3401.80 — no
copier can buy at a price that has already gone. The gap is measured and shown
as `entry N pts off`. `InpMaxEntryDiffPts` skips a copy that would enter more
than N points from the master's fill; the default `0` never skips, because a
missing trade is usually worse than a slightly different one. Pending orders
have no such limit — nothing has to fill immediately, so they go in at the
master's exact level.

**Identical prices mean different risk when brokers disagree.** If this broker
quotes $2 away from the master's, copying the stop price exactly gives you a
stop $2 further from your entry than it was from the master's — same number on
the chart, different money at risk. `PRICE_DISTANCE` is the mode for that other
intent: it reproduces the master's risk rather than the master's numbers. A
reversed slave always uses distances regardless, since a mirrored trade needs
its stop on the opposite side of the market.

Watch `entry N pts off` for a few trades. Consistently near zero means the two
brokers agree and absolute prices cost you nothing.

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
