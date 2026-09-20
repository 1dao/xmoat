-- engine/strategy.lua — a price rule applied across many stocks: fitting its
-- numbers on a pooled history, and scanning for the ones firing now.
--
-- Exports: strategy_universe, strategy_collect, strategy_pool,
--          strategy_sweep, strategy_scan
--
-- WHY THIS EXISTS SEPARATELY FROM backtest.lua. That file answers "what would
-- this rule have done to this stock". Useful, and not enough to choose the
-- rule's numbers: one stock's history is one path, and twenty signals on it
-- are a handful of episodes. Choosing "10 weeks and 6%" from that is fitting a
-- curve to noise with confidence.
--
-- So the sweep here pools every signal from every stock in a universe into one
-- sample per parameter cell. Two hundred signals across forty companies are
-- still not two hundred independent experiments — market-wide moves make them
-- overlap — but they are far better than twenty on one name, and the pooled
-- baseline (buying any day of the same window, across the same stocks) is
-- reported beside them so the comparison is like for like.
--
-- WHAT IT COSTS. Every stock needs its daily bars. Cached ones are free; the
-- rest are a request each, paced, and about 200 KB apiece. A universe of fifty
-- is a minute of fetching the first time and instant afterwards.

-- A stock the cache has never seen needs its WHOLE history, half a megabyte
-- of it, and the quote server starts dropping connections when those arrive
-- back to back — measured, not guessed: forty in a row lost nineteen. So this
-- path paces itself far more slowly than a single refresh does, and gives a
-- dropped connection one more chance after a longer pause.
local PACE_DEFAULT = 1500
local RETRY_PAUSE_MS = 3000

-- Codes to work on. `codes` wins; otherwise the watchlist, or a screen of the
-- market snapshot when filters are given.
--
-- opts = { codes = {...}, universe = 'watchlist' | 'screen', filters, limit }
-- COROUTINE-FREE: the screen reads the stored snapshot.
function g_exports.strategy_universe(opts)
    opts = opts or {}
    local limit = math.max(1, math.min(opts.limit or 30, 200))
    local out = {}
    if type(opts.codes) == 'table' and #opts.codes > 0 then
        for _, c in ipairs(opts.codes) do
            local sec = source_em_security(c)
            if sec then out[#out + 1] = { code = sec.code } end
            if #out >= limit then break end
        end
        return out, 'codes'
    end
    if opts.universe == 'screen' then
        local filters = util_copy(opts.filters)
        filters.limit = limit
        local res = market_screen(filters)
        if not res or not res.rows then return {}, 'screen' end
        for _, r in ipairs(res.rows) do
            out[#out + 1] = { code = r.code, name = r.name, industry = r.industry,
                              pe_ttm = r.pe_ttm, pb = r.pb, roe = r.roe,
                              market_cap = r.market_cap }
        end
        return out, 'screen'
    end
    for _, e in ipairs(watch_list()) do
        out[#out + 1] = { code = e.code }
        if #out >= limit then break end
    end
    return out, 'watchlist'
end

-- COROUTINE-ONLY. The bars for one code, from the cache when they are there.
-- Returns rows, or nil plus a reason. `pace` is slept AFTER a fetch, not after
-- a cache hit, so a warm universe costs nothing.
local function bars_for(code, opts)
    local doc = quote_load(code)
    if doc and type(doc.rows) == 'table' and #doc.rows > 0 and
       (opts.offline or not quote_is_stale(doc)) then
        return doc.rows, doc
    end
    if opts.offline then
        return nil, doc and '缓存过旧' or '没有行情缓存'
    end
    local pace = opts.pace_ms or cfg_int('STRATEGY_PACE_MS', PACE_DEFAULT)
    local fresh, ecode, err = quote_refresh(code)
    sched_sleep(pace)
    if not fresh and ecode ~= 'not_found' then
        sched_sleep(RETRY_PAUSE_MS)
        fresh, ecode, err = quote_refresh(code)
        sched_sleep(pace)
    end
    if not fresh or type(fresh.rows) ~= 'table' or #fresh.rows == 0 then
        return nil, tostring(err or '没有行情数据')
    end
    return fresh.rows, fresh
end

local function cell_key(n, flat, above)
    return string.format('%d|%g|%g', n, flat, above)
end

-- One stock's contribution: for every parameter cell, the forward returns of
-- its signals and how the barriers went. Pure.
function g_exports.strategy_collect(px, opts)
    opts = opts or {}
    local horizon = opts.horizon or 60
    local mas = opts.ma_days or { 30, 40, 50, 60, 70 }
    local aboves = opts.above_pct or { 3, 4, 5, 6, 7, 8, 10 }
    local flats = opts.flat_max or { 1, 2, 3 }
    local out = {}
    for _, n in ipairs(mas) do
        local ma = backtest_ma_series(px, n)
        for _, flat in ipairs(flats) do
            for _, above in ipairs(aboves) do
                local found = backtest_breakout(px, {
                    ma = ma, ma_days = n, flat_lookback = opts.flat_lookback,
                    flat_max = flat, above_pct = above,
                    min_day_gain = opts.min_day_gain, cooldown = opts.cooldown,
                })
                local rets = {}
                for _, e in ipairs(found.entries) do
                    local from, to = px[e.index], px[e.index + horizon]
                    local a, b = from and util_num(from.close), to and util_num(to.close)
                    if a and b and a > 0 then rets[#rets + 1] = (b / a - 1) * 100 end
                end
                local barrier = backtest_barrier(found.entries, px, {
                    take_profit = opts.take_profit, stop_loss = opts.stop_loss,
                    horizon = opts.barrier_horizon or horizon,
                })
                out[cell_key(n, flat, above)] = {
                    ma_days = n, flat_max = flat, above_pct = above,
                    entries = #found.entries, rets = rets,
                    hit_tp = barrier.hit_tp, hit_sl = barrier.hit_sl,
                    neither = barrier.neither,
                }
            end
        end
    end
    return out
end

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

-- Merge what several stocks collected into one row per cell. `stocks` is a
-- list of the tables strategy_collect returns. Pure.
function g_exports.strategy_pool(stocks)
    local cells = {}
    for _, per_stock in ipairs(stocks) do
        for key, c in pairs(per_stock) do
            local acc = cells[key]
            if not acc then
                acc = { ma_days = c.ma_days, flat_max = c.flat_max, above_pct = c.above_pct,
                        entries = 0, rets = {}, hit_tp = 0, hit_sl = 0, neither = 0,
                        stocks = 0 }
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
            ma_days = acc.ma_days, flat_max = acc.flat_max, above_pct = acc.above_pct,
            entries = acc.entries, stocks = acc.stocks,
            n = st.n, win_rate = st.win_rate, avg = st.avg, median = st.median,
            best = st.best, worst = st.worst,
            hit_tp = acc.hit_tp, hit_sl = acc.hit_sl,
            barrier_win_rate = decided > 0 and acc.hit_tp / decided * 100 or nil,
        }
    end
    return rows
end

-- COROUTINE-ONLY. The sweep across a universe.
function g_exports.strategy_sweep(opts)
    opts = util_copy(opts)
    local horizon = opts.horizon or 60
    local list, kind = strategy_universe(opts)
    if #list == 0 then return nil, 'bad_request', '没有可用的股票（自选为空，或筛选没有结果）' end

    local collected, used, skipped = {}, {}, {}
    local base_rets = {}
    local first_offset = (opts.ma_days and math.max(table.unpack(opts.ma_days)) or 70) +
                         (opts.flat_lookback or 25)
    for _, item in ipairs(list) do
        local px, why = bars_for(item.code, opts)
        if not px or #px < horizon + first_offset then
            skipped[#skipped + 1] = { code = item.code,
                                      reason = px and '日线太短' or tostring(why) }
        else
            collected[#collected + 1] = strategy_collect(px, opts)
            used[#used + 1] = { code = item.code, name = item.name, days = #px,
                                from = px[1].date, to = px[#px].date }
            -- The pooled baseline: any day of the same window, same stocks.
            for i = first_offset, #px - horizon do
                local a, b = util_num(px[i].close), util_num(px[i + horizon].close)
                if a and b and a > 0 then base_rets[#base_rets + 1] = (b / a - 1) * 100 end
            end
        end
    end
    if #collected == 0 then
        return nil, 'bad_request', '没有一只股票有足够的日线（先抓行情，或放宽 limit）'
    end

    local rows = strategy_pool(collected)
    local kept, objective = backtest_sweep_rank(rows, opts)
    local best = kept[1]
    table.sort(rows, function(a, b)
        if a.ma_days ~= b.ma_days then return a.ma_days < b.ma_days end
        if a.flat_max ~= b.flat_max then return a.flat_max < b.flat_max end
        return a.above_pct < b.above_pct
    end)

    local from, to, bars = nil, nil, 0
    for _, u in ipairs(used) do
        if not from or u.from < from then from = u.from end
        if not to or u.to > to then to = u.to end
        bars = bars + u.days
    end

    return {
        universe = kind, stocks = #used, skipped = util_json_array(skipped),
        used = util_json_array(used),
        from = from, to = to, days = bars,
        signal = 'breakout', signal_note = backtest_signal_list.breakout,
        horizon = horizon, objective = objective,
        flat_lookback = opts.flat_lookback or 25,
        min_day_gain = opts.min_day_gain or 0,
        cooldown = opts.cooldown or 20,
        require_ = { min_entries = opts.min_entries or 10, min_win_rate = opts.min_win_rate,
                     max_worst = opts.max_worst, max_sl = opts.max_sl },
        grid = util_json_array(rows),
        ranked = util_json_array((function()
            local out = {}
            for i = 1, math.min(10, #kept) do out[#out + 1] = kept[i] end
            return out
        end)()),
        best = best,
        neighbours = backtest_sweep_neighbours(rows, best, objective),
        baseline = stats(base_rets),
        notes = util_json_array({
            string.format('%d 只股票的信号汇总在一起算，而不是一只一只看——一只票的历史只是一条路径，' ..
                          '在上面挑参数是在拟合噪声。', #used),
            '汇总也不等于独立实验：同一波行情会让不同股票同时出信号，所以样本数看着大，实际信息量没那么大。',
            '基准是同样这些股票、同一窗口里随便哪天买的收益分布。跑不赢它的参数没有意义。',
            '没有哪组参数能保证不亏损。每行都带最差的一笔，约束是你自己设的"够安全"，它是对过去的筛选。',
            '不含交易成本、滑点和停牌；价格用前复权。',
        }),
    }
end

-- COROUTINE-ONLY. Which stocks are firing the rule right now.
--
-- opts adds { days = 1 }: how many of the most recent bars count as "now", so
-- a signal from two days ago is still findable on a Wednesday morning.
function g_exports.strategy_scan(opts)
    opts = util_copy(opts)
    local days = math.max(1, math.min(opts.days or 1, 20))
    local list, kind = strategy_universe(opts)
    if #list == 0 then return nil, 'bad_request', '没有可用的股票（自选为空，或筛选没有结果）' end

    local hits, checked, skipped = {}, 0, {}
    for _, item in ipairs(list) do
        local px, why = bars_for(item.code, opts)
        if not px or #px < (opts.ma_days or 50) + (opts.flat_lookback or 25) + 1 then
            skipped[#skipped + 1] = { code = item.code,
                                      reason = px and '日线太短' or tostring(why) }
        else
            checked = checked + 1
            -- cooldown 1: a scan asks "is it firing", not "how often has it".
            local found = backtest_breakout(px, {
                ma_days = opts.ma_days or 50, flat_lookback = opts.flat_lookback,
                flat_max = opts.flat_max or 2, above_pct = opts.above_pct or 6,
                min_day_gain = opts.min_day_gain, cooldown = 1,
            })
            for _, e in ipairs(found.entries) do
                if e.index > #px - days then
                    hits[#hits + 1] = {
                        code = item.code, name = item.name, industry = item.industry,
                        date = e.date, close = e.close, ma = e.ma,
                        above = e.above, slope = e.slope, day_gain = e.day_gain,
                        bars_ago = #px - e.index,
                        pe_ttm = item.pe_ttm, pb = item.pb, roe = item.roe,
                        market_cap = item.market_cap,
                    }
                end
            end
        end
    end
    table.sort(hits, function(a, b)
        if a.bars_ago ~= b.bars_ago then return a.bars_ago < b.bars_ago end
        return (a.above or 0) > (b.above or 0)
    end)
    -- Names, for a universe that did not come with them.
    for _, hit in ipairs(hits) do
        if not hit.name then
            local rec = stock_load(hit.code)
            hit.name = rec and rec.name or nil
        end
    end
    return {
        universe = kind, checked = checked, days = days,
        params = { ma_days = opts.ma_days or 50, above_pct = opts.above_pct or 6,
                   flat_max = opts.flat_max or 2, flat_lookback = opts.flat_lookback or 25,
                   min_day_gain = opts.min_day_gain or 0 },
        hits = util_json_array(hits), skipped = util_json_array(skipped),
        note = '这是信号，不是结论：它只说价格从一个平台上走了出来，' ..
               '这家公司值不值得买仍然要看财报、估值和检查清单。',
    }
end
