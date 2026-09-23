-- engine/subnew.lua — 次新股: a stock recently listed and already beaten down.
--
-- Exports: subnew_params, subnew_axes, subnew_def_version, subnew_signals,
--          subnew_state, subnew_scan, subnew_backtest
--
-- THE RULE. A newly listed stock (within `list_window` trading days of its
-- first day) whose close has fallen `drop`% below its FIRST DAY'S OPEN. The
-- idea being tested is the folk one — a 次新股 that has given back the listing
-- pop is worth buying — and the only honest way to know is to replay it: fire
-- on the day the close first crosses under the line, then measure what the
-- forward return was, against the plain baseline of buying any young stock on
-- any day of the same window.
--
-- WHERE THE FIRST DAY COMES FROM, AND ITS ONE ASSUMPTION. The listing day is
-- px[1] and the reference price is px[1].open — but only when the cached
-- series is the WHOLE history, not a window cut at QUOTE_MAX_DAYS. A stock
-- older than the cap has a px[1] that is a truncation, not an IPO, so this
-- module skips any series that reaches the cap (subnew_state returns
-- truncated). That is also why the look-back is bounded by QUOTE_MAX_DAYS
-- (1200 ≈ 4.8 years): to see listings further back, raise it. Prices are
-- 前复权, so px[1].open is the listing open adjusted for later dividends — the
-- same basis as every close, which is what keeps the ratio consistent.
--
-- NO LOOKAHEAD. An entry on day i reads px[1].open and px[i].close, both known
-- on day i; the forward return is the measured outcome and nothing about it
-- feeds the decision to enter.

-- Which definition of the rule an entry (engine/signals.lua) was found by:
-- bump this if the rule's meaning changes (what "first day" means, what
-- counts as a cross), the same guard backtest_breakout_version gives that
-- rule. Entries of another definition are dropped on load.
g_exports.subnew_def_version = 1

-- The rule's numbers, in one place, from config.
function g_exports.subnew_params()
    return {
        list_window = cfg_int('SUBNEW_LIST_WINDOW', 240),  -- trading days ≈ 1 year
        drop_pct = cfg_num('SUBNEW_DROP_PCT', 50),         -- below the first-day open
        horizon = cfg_int('SUBNEW_HORIZON', 60),           -- holding period, trading days
        cooldown = cfg_int('SUBNEW_COOLDOWN', 60),         -- one plunge-below counts once for ~3 months
    }
end

-- The grid's default axes, shared by the backtest command's validation and its
-- defaults so they cannot drift apart.
local AXIS_WINDOW = { 120, 180, 240, 300 }   -- ≈ 6mo, 9mo, 1yr, 15mo
local AXIS_DROP = { 30, 40, 50, 60 }         -- %
g_exports.subnew_axes = { list_window = AXIS_WINDOW, drop_pct = AXIS_DROP }

-- Is this series the stock's whole history (px[1] its listing day), or a window
-- cut at the fetch cap? Anything at or near the cap is treated as truncated.
local function truncated(px)
    local cap = cfg_int('QUOTE_MAX_DAYS', 1200)
    return #px >= cap - 5
end

-- The days the rule fired on one stock's bars, and why. Pure. px[1] is taken as
-- the listing day (the caller is responsible for not passing a truncated
-- series). opts = { list_window, drop_pct, cooldown }; anything left out comes
-- from config.
--
-- A CROSS, not a level: the entry is the first day the close is at or below the
-- line after being above it, so a stock that sits under the line for weeks is
-- one entry, not one a day. `cooldown` then keeps a price wobbling across the
-- line from counting each wobble.
function g_exports.subnew_signals(px, opts)
    opts = opts or {}
    px = px or {}
    local d = subnew_params()
    local window = opts.list_window or d.list_window
    local drop = (opts.drop_pct or d.drop_pct) / 100
    local cooldown = opts.cooldown or d.cooldown

    local first_open = px[1] and util_num(px[1].open)
    if not first_open or first_open <= 0 then return { entries = {}, tested = 0 } end
    local line = first_open * (1 - drop)

    local entries, tested, below, last_fire = {}, 0, false, nil
    -- age = i - 1 trading days after the listing day; the whole first year is
    -- i from 2 to window + 1.
    for i = 2, math.min(#px, window + 1) do
        local close = util_num(px[i].close)
        if close then
            tested = tested + 1
            local now_below = close <= line
            local crossed = now_below and not below
            if crossed and (not last_fire or (i - last_fire) >= cooldown) then
                last_fire = i
                entries[#entries + 1] = {
                    date = px[i].date, index = i, close = close,
                    age = i - 1, first_open = first_open, line = line,
                    drop_pct = (close / first_open - 1) * 100,
                }
            end
            below = now_below
        end
    end
    return { entries = entries, tested = tested, first_open = first_open, line = line }
end

-- The stock's state as of its last bar: is it a 次新股 that is down enough
-- right now? Pure. Returns nil when the series is truncated (px[1] is not the
-- listing) or has no usable first open.
function g_exports.subnew_state(px, opts)
    opts = opts or {}
    px = px or {}
    if #px == 0 or truncated(px) then return nil end
    local d = subnew_params()
    local window = opts.list_window or d.list_window
    local drop = (opts.drop_pct or d.drop_pct) / 100
    local first_open = util_num(px[1].open)
    if not first_open or first_open <= 0 then return nil end

    local age = #px - 1                     -- trading days since listing
    if age > window then return nil end     -- no longer a 次新股 by this window
    local last = px[#px]
    local close = util_num(last.close)
    if not close then return nil end
    local line = first_open * (1 - drop)
    if close > line then return nil end     -- listed recently, but not down enough

    -- The lowest it has traded relative to the listing open, for the reader.
    local low = nil
    for i = 1, #px do
        local l = util_num(px[i].low) or util_num(px[i].close)
        if l and (not low or l < low) then low = l end
    end
    return {
        list_date = px[1].date, last_date = last.date, days_listed = age,
        first_open = first_open, last_close = close, line = line,
        drop_pct = (close / first_open - 1) * 100,
        low_pct = low and (low / first_open - 1) * 100 or nil,
    }
end

-- ── the scan: who is a beaten-down 次新股 right now ──────────────────────────

local PACE_DEFAULT = 1500
local function scan_source(opts) return opts.price_source or cfg_get('STRATEGY_PRICE_SOURCE', 'tdx') end

-- COROUTINE-ONLY. Bars for one code from the cache; a miss is fetched one at a
-- time and paced (it means Eastmoney). Mirrors strategy.lua's bars_for.
local function bars_for(code, opts)
    local doc = quote_load(code)
    if doc and type(doc.rows) == 'table' and #doc.rows > 0 then return doc.rows end
    if opts.offline then return nil, doc and '缓存为空' or '没有行情缓存' end
    local pace = opts.pace_ms or cfg_int('STRATEGY_PACE_MS', PACE_DEFAULT)
    local fresh, ecode = quote_refresh(code, { source = scan_source(opts) })
    sched_sleep(pace)
    if not fresh or type(fresh.rows) ~= 'table' or #fresh.rows == 0 then
        return nil, ecode == 'not_found' and '代码不存在' or '没有行情数据'
    end
    return fresh.rows
end

-- COROUTINE-ONLY. Fill the cache for the whole universe in one parallel pass.
local function prefetch(list, opts)
    local codes = {}
    for _, item in ipairs(list) do codes[#codes + 1] = item.code end
    if opts.offline then return { total = #codes, cached = 0, fetched = 0, failed = util_json_array({}) } end
    local t0 = util_now_ms()
    local res = quote_prefetch(codes, { source = scan_source(opts), force = opts.force,
                                        max_days = opts.bars_days })
    res.ms = util_now_ms() - t0
    return res
end

-- COROUTINE-ONLY. The 次新股 that are down `drop`% or more, now — and, when
-- `days` is given, who just CROSSED that line within the last `days` trading
-- days (`events`), the unit the daily push records: "down enough right now"
-- and "just became down enough" are different questions, computed together
-- off the same bars read rather than scanning the market twice.
-- opts: the usual universe options, plus { list_window, drop_pct, days? }.
function g_exports.subnew_scan(opts)
    opts = util_copy(opts)
    local d = subnew_params()
    local window = opts.list_window or d.list_window
    local drop = opts.drop_pct or d.drop_pct
    local cooldown = opts.cooldown or d.cooldown
    local days = opts.days and math.max(1, math.min(opts.days, 20)) or nil

    local list, kind = strategy_universe(opts)
    if #list == 0 then return nil, 'bad_request', '没有可用的股票（自选为空，或筛选没有结果）' end
    local fetch = prefetch(list, opts)

    local hits, events, checked, skipped = {}, {}, 0, {}
    for i, item in ipairs(list) do
        if i % 200 == 0 then sched_sleep(1) end
        local px, why = bars_for(item.code, opts)
        if not px then
            skipped[#skipped + 1] = { code = item.code, reason = tostring(why) }
        else
            checked = checked + 1
            local st = subnew_state(px, { list_window = window, drop_pct = drop })
            if st then
                st.code, st.name, st.industry = item.code, item.name, item.industry
                st.pe_ttm, st.pb, st.roe, st.market_cap = item.pe_ttm, item.pb, item.roe, item.market_cap
                hits[#hits + 1] = st
            end
            -- subnew_signals trusts px[1].open as the listing day; subnew_state
            -- already guards that internally, this loop must guard it itself.
            if days and not truncated(px) then
                local found = subnew_signals(px, { list_window = window, drop_pct = drop, cooldown = cooldown })
                local newest
                for _, e in ipairs(found.entries) do
                    if e.index > #px - days and (not newest or e.index > newest.index) then newest = e end
                end
                if newest then
                    local last = px[#px]
                    events[#events + 1] = {
                        code = item.code, name = item.name, industry = item.industry,
                        date = newest.date, close = newest.close, age = newest.age,
                        first_open = newest.first_open, line = newest.line, drop_pct = newest.drop_pct,
                        bars_ago = #px - newest.index,
                        last_date = last.date, last_close = util_num(last.close),
                        pe_ttm = item.pe_ttm, pb = item.pb, roe = item.roe, market_cap = item.market_cap,
                    }
                end
            end
        end
    end
    -- Deepest fall first: the ones that gave back the most of the listing pop.
    table.sort(hits, function(a, b) return (a.drop_pct or 0) < (b.drop_pct or 0) end)
    table.sort(events, function(a, b)
        if a.bars_ago ~= b.bars_ago then return a.bars_ago < b.bars_ago end
        return (a.drop_pct or 0) < (b.drop_pct or 0)
    end)
    for _, hit in ipairs(hits) do
        if not hit.name then
            local rec = stock_load(hit.code)
            hit.name = rec and rec.name or nil
        end
    end
    for _, e in ipairs(events) do
        if not e.name then
            local rec = stock_load(e.code)
            e.name = rec and rec.name or nil
        end
    end

    -- The rule as configured, rather than a variation being tried out: only
    -- that is worth keeping a record of (engine/signals.lua).
    local configured = window == d.list_window and drop == d.drop_pct and cooldown == d.cooldown

    return {
        universe = kind, checked = checked, fetch = fetch,
        params = { list_window = window, drop_pct = drop,
                   list_weeks = window / 5, days = days },
        configured = configured,
        hits = util_json_array(hits),
        events = days and util_json_array(events) or nil,
        skipped = util_json_array(skipped),
        note = '这是筛选，不是结论：上市一年内、相对首日开盘价跌了这么多，只说明它便宜过发行时的热度，' ..
               '公司值不值得买仍要看财报、估值和检查清单。跌幅相对的是前复权后的首日开盘价。',
    }
end

-- ── the backtest: did buying such a stock win? ──────────────────────────────

local function stats(rets)
    if #rets == 0 then return { n = 0 } end
    local wins, sum = 0, 0
    for _, r in ipairs(rets) do
        if r > 0 then wins = wins + 1 end
        sum = sum + r
    end
    local sorted = {}
    for i, r in ipairs(rets) do sorted[i] = r end
    table.sort(sorted)
    return { n = #rets, win_rate = wins / #rets * 100, avg = sum / #rets,
             median = fin_median(sorted), best = sorted[#sorted], worst = sorted[1] }
end

local function cell_key(window, drop) return string.format('%d|%g', window, drop) end

-- One stock's contribution to every cell: the forward returns of its entries
-- and how the take-profit / stop-loss barriers went. Pure.
local function collect(px, opts)
    local horizon = opts.horizon or 60
    local windows = opts.list_window or AXIS_WINDOW
    local drops = opts.drop_pct or AXIS_DROP
    local out = {}
    for _, window in ipairs(windows) do
        for _, drop in ipairs(drops) do
            local found = subnew_signals(px, { list_window = window, drop_pct = drop,
                                               cooldown = opts.cooldown })
            local rets = {}
            for _, e in ipairs(found.entries) do
                local to = px[e.index + horizon]
                local a, b = e.close, to and util_num(to.close)
                if a and b and a > 0 then rets[#rets + 1] = (b / a - 1) * 100 end
            end
            local barrier = backtest_barrier(found.entries, px, {
                take_profit = opts.take_profit, stop_loss = opts.stop_loss,
                horizon = opts.barrier_horizon or horizon,
            })
            out[cell_key(window, drop)] = {
                list_window = window, drop_pct = drop,
                entries = #found.entries, rets = rets,
                hit_tp = barrier.hit_tp, hit_sl = barrier.hit_sl, neither = barrier.neither,
            }
        end
    end
    return out
end

-- Merge what several stocks collected into one row per cell. Pure.
local function pool(stocks)
    local cells = {}
    for _, per_stock in ipairs(stocks) do
        for key, c in pairs(per_stock) do
            local acc = cells[key]
            if not acc then
                acc = { list_window = c.list_window, drop_pct = c.drop_pct,
                        entries = 0, rets = {}, hit_tp = 0, hit_sl = 0, neither = 0, stocks = 0 }
                cells[key] = acc
            end
            acc.entries = acc.entries + c.entries
            if c.entries > 0 then acc.stocks = acc.stocks + 1 end
            for _, r in ipairs(c.rets) do acc.rets[#acc.rets + 1] = r end
            acc.hit_tp = acc.hit_tp + (c.hit_tp or 0)
            acc.hit_sl = acc.hit_sl + (c.hit_sl or 0)
            acc.neither = acc.neither + (c.neither or 0)
        end
    end
    local rows = {}
    for _, acc in pairs(cells) do
        local st = stats(acc.rets)
        local decided = acc.hit_tp + acc.hit_sl
        rows[#rows + 1] = {
            list_window = acc.list_window, drop_pct = acc.drop_pct,
            list_weeks = acc.list_window / 5,
            entries = acc.entries, stocks = acc.stocks,
            n = st.n, win_rate = st.win_rate, avg = st.avg, median = st.median,
            best = st.best, worst = st.worst,
            hit_tp = acc.hit_tp, hit_sl = acc.hit_sl,
            barrier_win_rate = decided > 0 and acc.hit_tp / decided * 100 or nil,
        }
    end
    table.sort(rows, function(a, b)
        if a.list_window ~= b.list_window then return a.list_window < b.list_window end
        return a.drop_pct < b.drop_pct
    end)
    return rows
end

-- COROUTINE-ONLY. The grid over (list_window × drop) across a universe, pooled.
-- opts: universe options, the two axes as lists, plus
--   horizon = 60, cooldown, take_profit, stop_loss,
--   objective = 'median' | 'avg' | 'win_rate', min_entries = 10
function g_exports.subnew_backtest(opts)
    opts = util_copy(opts)
    local horizon = opts.horizon or 60
    local windows = opts.list_window or AXIS_WINDOW
    local drops = opts.drop_pct or AXIS_DROP
    local max_window = 0
    for _, w in ipairs(windows) do if w > max_window then max_window = w end end

    local list, kind = strategy_universe(opts)
    if #list == 0 then return nil, 'bad_request', '没有可用的股票（自选为空，或筛选没有结果）' end
    local fetch = prefetch(list, opts)

    local collected, used, skipped, truncated_n = {}, {}, {}, 0
    local base_rets = {}
    for _, item in ipairs(list) do
        local px, why = bars_for(item.code, opts)
        if not px then
            skipped[#skipped + 1] = { code = item.code, reason = tostring(why) }
        elseif truncated(px) then
            -- px[1] is a window edge, not a listing: this is not a 次新股 series.
            truncated_n = truncated_n + 1
        elseif not (px[1] and util_num(px[1].open)) then
            skipped[#skipped + 1] = { code = item.code, reason = '没有首日开盘价' }
        else
            collected[#collected + 1] = collect(px, opts)
            used[#used + 1] = { code = item.code, name = item.name, days = #px,
                                from = px[1].date, to = px[#px].date }
            -- The like-for-like baseline: buy this same young stock on ANY day
            -- inside the widest first-year window, held the same horizon. It is
            -- "a 次新股, without asking that it be down" — so the grid says what
            -- the drop condition adds, not merely that young stocks did a thing.
            for i = 2, math.min(#px - horizon, max_window + 1) do
                local a, b = util_num(px[i].close), util_num(px[i + horizon].close)
                if a and b and a > 0 then base_rets[#base_rets + 1] = (b / a - 1) * 100 end
            end
        end
    end
    if #collected == 0 then
        return nil, 'bad_request',
            '没有一只是完整历史的次新股（多为上市已久、日线在 QUOTE_MAX_DAYS 处被截断）'
    end

    local rows = pool(collected)
    local objective = (opts.objective == 'avg' or opts.objective == 'win_rate') and opts.objective or 'median'
    local min_entries = opts.min_entries or 10
    local ranked = {}
    for _, r in ipairs(rows) do
        if (r.n or 0) >= min_entries and r[objective] ~= nil then ranked[#ranked + 1] = r end
    end
    table.sort(ranked, function(a, b)
        if a[objective] == b[objective] then return (a.n or 0) > (b.n or 0) end
        return a[objective] > b[objective]
    end)

    local from, to, lengths, starts = nil, nil, {}, {}
    for _, u in ipairs(used) do
        if not from or u.from < from then from = u.from end
        if not to or u.to > to then to = u.to end
        lengths[#lengths + 1] = u.days
        starts[#starts + 1] = u.from
    end
    table.sort(lengths); table.sort(starts)
    local mid = (#used + 1) // 2
    local span = { median_days = lengths[mid], typical_from = starts[mid],
                   earliest_from = from, to = to }

    return {
        universe = kind, stocks = #used, truncated = truncated_n,
        skipped = util_json_array(skipped), used = util_json_array(used), fetch = fetch,
        from = from, to = to, span = span,
        signal = 'subnew', horizon = horizon, objective = objective,
        cooldown = opts.cooldown or subnew_params().cooldown,
        require_ = { min_entries = min_entries },
        grid = util_json_array(rows),
        ranked = util_json_array((function()
            local out = {}
            for i = 1, math.min(10, #ranked) do out[#out + 1] = ranked[i] end
            return out
        end)()),
        best = ranked[1],
        baseline = stats(base_rets),
        notes = util_json_array({
            string.format('%d 只完整历史的次新股汇总在一起算；另有 %d 只上市已久、日线被截断，' ..
                          '首日开盘价无从谈起，已排除。', #used, truncated_n),
            '基准是同样这些次新股、同一年窗口里随便哪天买的收益——也就是"买次新股但不要求它跌"。' ..
            '规则跑不赢它，就说明"跌 50%"这个条件没有加东西。',
            '同一段行情（比如一次全市场的次新股杀跌）会让很多只同时触发，样本数看着大，实际信息量没那么大。',
            '能看多远由 QUOTE_MAX_DAYS 决定（默认 1200 个交易日 ≈ 4.8 年）；要看更早的上市，调大它。',
            '不含交易成本、滑点和停牌；价格用前复权，跌幅相对复权后的首日开盘价。',
        }),
    }
end
