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
