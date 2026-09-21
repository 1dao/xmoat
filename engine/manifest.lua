-- engine/manifest.lua — the engine's modules, in load order.
--
-- Every host loads the engine from this one list (main.lua, cli.lua,
-- test/unit.lua, and a phone host later), so adding a module is one line here
-- and no host can end up with a different engine.
--
-- Order is dependency order: a module may call an export of any module ABOVE
-- it at load time, and of any module at all once loading has finished.

return {
    'engine/cfg.lua',        -- cfg_*       config and logging
    'engine/util.lua',       -- util_*      files, JSON, numbers, dates
    'engine/sched.lua',      -- sched_*     waiting on a coroutine
    'engine/net.lua',        -- net_*       outbound HTTP
    'engine/source_em.lua',  -- source_em_* Eastmoney
    'engine/tdx.lua',        -- tdx_*       the 通达信 quote protocol
    'engine/source_tdx.lua', -- source_tdx_* 通达信 bars, forward-adjusted here
    'engine/fin.lua',        -- fin_*       report series, TTM, statistics
    'engine/valuation.lua',  -- valuation_* percentiles, reverse DCF, bands
    'engine/dividend.lua',   -- dividend_*
    'engine/quality.lua',    -- quality_*
    'engine/checks.lua',     -- checks_*    the checklist
    'engine/tech.lua',       -- tech_*      moving averages, bias, chip distribution
    'engine/levels.lua',     -- levels_*    a buy range, a stop and a target
    'engine/analysis.lua',   -- analysis_*  the object every client renders
    'engine/report.lua',     -- report_*    Markdown, for the CLI and push channels
    'engine/events.lua',     -- events_*    what changed between two refreshes
    'engine/store.lua',      -- store_*     JSON files under DATA_DIR
    'engine/quote.lua',      -- quote_*     daily prices, cached and extended
    'engine/calendar.lua',   -- calendar_*  when new daily data can exist
    'engine/notify.lua',     -- notify_*    push channels
    'engine/wxcrypt.lua',    -- wxcrypt_*   WeCom's callback envelope
    'engine/llm.lua',        -- llm_*       one chat call: Claude or OpenAI-compatible
    'engine/alerts.lua',     -- alerts_*    the alert log, pushing, the check
    'engine/watch.lua',      -- watch_*     the watchlist
    'engine/stock.lua',      -- stock_*     refresh and read one stock
    'engine/market.lua',     -- market_*    the whole market, and screening it
    'engine/review.lua',     -- review_*    the market's day: 大盘、结构、自选
    'engine/backtest.lua',   -- backtest_*  replay the engine's own signals
    'engine/groups.lua',     -- groups_*    region and board membership
    'engine/strategy.lua',   -- strategy_*  one rule across many stocks
    'engine/signals.lua',    -- signals_*   the built-in rule's finds, kept and pushed
    'engine/insight.lua',    -- insight_*   facts in, a checked reading out
    'engine/schedule.lua',   -- schedule_*  the daily check (started by a host)
    'engine/api.lua',        -- api_*       the command registry
    'engine/commands.lua',   -- commands_*  every command
    'engine/engine.lua',     -- engine_*    start and stop
}
