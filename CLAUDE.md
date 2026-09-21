# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

xmoat is a fundamental / value-investing analysis tool written in Lua on the
**xnet2lua** runtime. `README.md` is the product surface, `docs/API.md` the
contract between the engine and every client, `docs/METRICS.md` how each number
is defined.

## Commands

No build step for the application; the only compiled artefact is the runtime,
built in `../xnet2lua` and copied to `bin/` (not tracked).

```bash
bin/xnet.exe test/unit.lua                 # offline, seconds; exit 0 = all pass
bin/xnet.exe main.lua                      # HTTP host on 127.0.0.1:8688 (start.bat / start.sh)
bin/xnet.exe cli.lua report 600519         # Markdown report; `cli.lua` alone lists subcommands
bin/xnet.exe cli.lua call stock.get code=600519
bin/xnet.exe cli.lua check                 # refresh the watchlist, record changes, push
```

Any config key can be overridden as a `KEY=VAL` argument; precedence is
command line > `xmoat.local.cfg` > `xmoat.cfg`. `VERBOSE=1` keeps runtime logs on
the CLI. `print()` goes to `logs/`, not stdout — scripts that talk to a terminal
use `io.write`.

## Architecture: three layers, and the rule between them

- **engine/** fetches, stores and computes. It must stay embeddable in a phone
  app: no listening sockets, no HTML, no `os.execute`/`io.popen`, no assumption
  about the working directory beyond `DATA_DIR`. Every capability is a command
  in `engine/commands.lua`, registered through `engine/api.lua`.
- **host/** adapts transport to commands and owns no logic. `/api/v1` routes are
  generated from the command registry.
- **web/** is a pure client of `/api/v1`. It computes no financial number and
  inserts API strings only with `textContent` (the `h()` helper refuses a `style`
  attribute because the CSP forbids inline styles).

The **analysis object** (`engine/analysis.lua`) is what every client renders. It
is recomputed on read from stored source data. Changing its shape means updating
`docs/API.md`, and bumping `analysis_schema` if an existing field changes meaning.

`engine/manifest.lua` lists engine modules in load order; `main.lua`, `cli.lua`
and `test/unit.lua` all load from it. Add a module there, not in a host.

## Module convention (from gitloom)

`engine/boot.lua` loads each file into its own environment. Exports are declared
as `function g_exports.<module>_<name>()` where `<module>` is the filename; call
sites use the short name. Entry points run twice (loader detour) — see the top of
`main.lua`. Load order matters: a module may call earlier exports at load time.

## Coroutines and timers

- Anything that reaches the network yields: `net_*`, `source_em_fetch_*`,
  `stock_refresh`, and so every command. Hosts call `api_call` on a coroutine
  (`sched_spawn`).
- **Never call `xtimer.add` from a coroutine**, and never pass `timeout_ms` to
  `xhttp_client` from one: xtimer calls back into the state that armed it, which
  is a crash once that coroutine is suspended. Use `sched_after` /
  `sched_wait_until` / `sched_sleep`; the one ticker is armed in `engine_start`
  on the main state. Socket callbacks are safe (xnet stores the main state).

## Alerts

- `stock_refresh` records events itself (`events_diff` of the stored copy
  against the new one, watched stocks only). Every refresh path must go through
  it: a refresh that skipped recording would consume the difference and the
  next check would find nothing.
- Recording and pushing are separate. `alerts_flush` sends everything pending
  as one digest; with no channel configured it marks events `skipped` so a
  channel added later does not replay old alerts.
- `schedule_start` arms an xtimer, so only a host calls it, from the main state
  (`main.lua` does; `cli.lua` and tests do not).
- Tests replace the network with `__net_set_transport` and the channel list
  with `__notify_set_channels`; config cannot be changed after startup.
- Signing vectors for DingTalk and Feishu in `test/unit.lua` were computed
  independently (Python hmac); keep them when touching `notify_build`.
- `engine/wxcrypt.lua` + `host/wecom.lua` are the WeCom callback, and exist
  only so the console will let a trusted IP be declared (the app channel is
  refused with `errcode 60020` from outside mainland China). It is the one
  route NOT behind `API_TOKEN` — WeCom sends no header, so the signature and
  the AES key are the credential — and it drops every event it receives. The
  vector in `test/unit.lua` is Tencent's own WXBizMsgCrypt sample.

## Positions, and the alerts they unlock

- A watchlist entry may carry `position = { shares?, cost?, since }`. It means
  "I own this" and it is the SWITCH for the `level` and `trend` events: with
  no position those two kinds are never produced, not produced and filtered.
  A price alert on something merely watched is noise; on something owned a
  broken stop is the one message worth a buzz.
- `events_diff` builds both sides with the same watch entry AND the bars up to
  each side's own day (`quotes_upto`). Judging yesterday's close against
  today's moving average invents crossings that never happened. The old
  side's day is `quotes_as_of`, the last bar that record was actually judged
  on — not its valuation day, which differs when a refresh got no prices;
  cutting there would treat that day's crossing as already known.
- The engine never writes a position itself: no broker connection, no way to
  know what was bought.
- `alerts_flush(opts)` takes `{ review, review_alone, problems }`. The daily
  check hands in the market review so it rides along at the end of the digest
  rather than arriving as a second message; `PUSH_REVIEW` (digest | always |
  off) picks whether a quiet day still sends one. `report_review_brief` is the
  few-line form — a WeCom app message is 2,000 bytes for everything.
- `problems` is what the check could not fetch (a failed refresh, no bars from
  either source — `stock_refresh`'s fourth return — or an index the review
  served from cache — `quote_series` returns `doc, 'stale', why`). It is pushed
  even on a quiet day, ahead of the review: a check that could not look and a
  check that found nothing both say "0 alerts" otherwise.

## The trading calendar

- `engine/calendar.lua` answers "could there be new data yet" BEFORE any TTL
  is consulted (`quote_is_stale`, `review_sectors`). No holiday table: a bar
  for day D exists only after D's close, weekends are skipped outright, and a
  holiday is discovered — a check after that close that finds the same last
  day moves the next check on, so a week-long holiday costs one request.
- A bar dated today before today's close is still moving, so the age limit
  decides; one taken mid-session is refetched after the close.
- The days that DID trade are the dates in the cached index series, not a
  weekday guess: `calendar_is_trading_day` returns nil outside that range.

## Prices, technicals, levels, backtest

- `engine/quote.lua` caches daily bars per security (`data/quotes/<code>.json`,
  `idx-<code>.json` for an index — 000001 is both the Shanghai Composite and
  平安银行). A refresh asks only for the days after the last one kept, with ten
  days of overlap: the series is FORWARD-ADJUSTED, so a dividend rewrites all
  of it, and a disagreeing close in the overlap means refetch everything
  rather than splice two bases together. `QUOTE_MAX_DAYS` (1200) caps it.
- `engine/tech.lua` and `engine/levels.lua` are pure. Levels turn a multiple
  into a price (`close × m ÷ today's multiple`) and take the nearest support
  below the price for the stop; every output carries the rule that made it,
  and the notes say what invalidates it. Do not add a number here without one.
- The chip distribution is a MODEL (turnover-decay, triangular within the
  day's range). Its assumptions are in docs/METRICS.md; an index has no
  turnover, so it has no chips.
- `engine/backtest.lua` replays those rules. The percentile on day t uses only
  days before t, and today's value joins the window after the comparison. Keep
  it that way: a lookahead here would make every number meaningless. A day
  touching both barriers counts as the stop, and the baseline (buying on any
  day of the same window) is part of the result, not a nicety.
- `engine/review.lua` is the daily review: indices from the quote cache, the
  board table from the quote server (100 rows per page, so it is paged; the
  live host 502s from some networks and the delayed one is the fallback), and
  the watchlist out of what is already stored. Breadth counts BOARDS — the
  fine industry boards overlap, so summing their stock counts double-counts.

## The 通达信 price source, and wide scans

- `engine/tdx.lua` speaks the 通达信 quote protocol over raw TCP: framed
  request/response, zlib bodies (`xcompress`), prices as a sign-and-continue
  varint of thousandths, volumes in TDX's own float. A frame that is not the
  answer to the request is skipped, never mistaken for it. Connections are
  pooled (`TDX_CONNECTIONS`), and `engine_stop` closes them.
- `engine/source_tdx.lua` turns those raw bars into xmoat records and does the
  forward adjustment itself from the ex-rights records. Verified against
  Eastmoney's own 前复权: 0.0036% mean difference over 1,200 days.
- TDX carries NO turnover rate, so no chip distribution. A watched stock is
  therefore asked of Eastmoney (`stock_refresh` asks for `em`), and the cache
  records its `source`; asking for the other one refetches the whole series
  rather than splicing two bases together.
- When Eastmoney's kline fetch fails, `quote_refresh` retries on TDX
  (`FALLBACK`, one direction only) — its quote server blocks an address for
  hours at a time, and a check judging today on last week's bars says nothing.
  The next request asks Eastmoney again. Never TDX → Eastmoney: a scan that
  lost TDX would become hundreds of Eastmoney requests in a row.
- An index over TDX is the same request with 4 more bytes a row and volume in
  hundreds of 手 (`tdx_parse_bars(body, true)`); its market comes from
  `sec.market`, never the code (000001). Tests stand in for the servers with
  `__tdx_set_transport`.
- `quote_prefetch` fetches a whole universe in parallel over the pool —
  Eastmoney stays serial, because parallel HTTPS is what makes it refuse.
- `engine/strategy.lua` is one rule across many stocks: `strategy_sweep` pools
  every signal into one sample per parameter cell (one stock's history is one
  path), `strategy_scan` asks who is firing now. Both prefetch first.

## Screening

- `engine/market.lua` keeps its own snapshot (`data/market.json`): two
  market-wide Eastmoney tables joined by code — today's valuation and the
  latest ANNUAL report's figures. Annual on purpose: every company has the
  same period, and an interim ROE is not annualised.
- A filter never keeps a row that lacks the figure it asks about, and a
  `pe_max` implies profitability (a negative PE undercuts any ceiling).
- What the snapshot cannot carry — dividend yield, valuation percentiles, the
  checklist — is per-stock work; the screen narrows, `stock.refresh` judges.

## Language model (optional)

- `engine/llm.lua` speaks two wire formats and nothing else: Claude's Messages
  API (raw HTTP — there is no Lua SDK) and OpenAI-compatible chat completions.
  Claude requests carry `fallbacks: "default"` with its beta header, and JSON
  answers use `output_config.format`; the OpenAI path asks for `json_object`
  and `engine/insight.lua` re-checks the shape.
- `engine/insight.lua` decides what to ask. It hands the model FACTS rendered
  from the analysis object plus the company's own review text, forbids new
  numbers, and then verifies: `insight_unverified` extracts every figure from
  the answer and reports the ones absent from the facts. Clients must show
  that list — the web card and the CLI both do.
- `__llm_set_config` replaces the configuration in tests; `false` means "not
  configured", `nil` restores the real one.
- Nothing calls the model on its own except a new annual report during a
  scheduled check (`INSIGHT_ON_ANNUAL_REPORT`). Every other call is a button.

## Data and numbers

- `engine/source_em.lua` is the only file that knows Eastmoney field names.
  `parse_*` is separate from `fetch_*` so recorded responses in
  `test/fixtures/` can test parsing; a new source produces the same records.
- Units: money in yuan; ROE, margins, ratios-in-percent as percent (15.2);
  `ocf_to_np` a plain ratio; `dps` yuan per share (source is per 10 shares).
- Q1/H1/Q3 flow items are year-to-date cumulative. TTM goes through `fin_ttm`.
- JSON: missing values in lists are `util_null`, never nil (a hole turns an
  array into an object). A list that may be empty is marked with
  `util_json_array` so it encodes as `[]`. `util_num` is the gate for every
  computed number (rejects NaN, inf, null, numeric strings).
- Checks return `pass` / `warn` / `na`; `na` means missing data, not a pass.
  Thresholds live in one table at the top of `engine/checks.lua`.

## Working in this tree

- `scripts/core/share/` is a **copied** subset of xnet2lua (`xhttp_codec`,
  `xhttp_client`, `xfs`), not a submodule. A fix there must be copied back.
- `.gitattributes` pins LF; `data/`, `tmp/`, `logs/`, `bin/`, `xmoat.local.cfg`
  are gitignored. `tmp/unit-data` is the test's scratch store.
- Be gentle with the data source while developing: a full refresh pulls over a
  megabyte and repeated full refreshes have been throttled to ~1 minute each.
  Prefer the fixtures and the stored `data/` copy.
- New behaviour lands with a check in `test/unit.lua`. Comments explain why —
  the trade-off and what it costs — not what the code does.
