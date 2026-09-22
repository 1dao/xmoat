-- engine/strategy.lua — a price rule applied across many stocks: fitting its
-- numbers on a pooled history, and scanning for the ones firing now.
--
-- Exports: strategy_universe, strategy_collect, strategy_pool,
--          strategy_sweep, strategy_scan, strategy_attribute, strategy_rules
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
-- WHAT IT COSTS. Every stock needs its daily bars, and they are fetched
-- before any analysis starts — the whole universe, in parallel, over the
-- 通达信 connections (engine/quote.lua's quote_prefetch). Cached ones cost
-- nothing. That is the difference between a scan of a few hundred stocks
-- taking a couple of minutes and taking half an hour of HTTPS handshakes that
-- the server eventually refuses.

-- A stock the cache has never seen needs its WHOLE history, half a megabyte
-- of it, and the quote server starts dropping connections when those arrive
-- back to back — measured, not guessed: forty in a row lost nineteen. So this
-- path paces itself far more slowly than a single refresh does, and gives a
-- dropped connection one more chance after a longer pause.
local PACE_DEFAULT = 1500
local RETRY_PAUSE_MS = 3000

-- Which source a wide scan pulls from. TDX by default: it is the one that can
-- answer hundreds of stocks without falling over. STRATEGY_PRICE_SOURCE=em
-- goes back to Eastmoney, slowly.
local function scan_source(opts)
    return opts.price_source or cfg_get('STRATEGY_PRICE_SOURCE', 'tdx')
end

-- COROUTINE-ONLY. Fill the cache for the whole universe before anything is
-- computed: one pass, in parallel, with the failures listed rather than
-- retried forever.
local function prefetch(list, opts)
    local codes = {}
    for _, item in ipairs(list) do codes[#codes + 1] = item.code end
    if opts.offline then return { total = #codes, cached = 0, fetched = 0,
                                  failed = util_json_array({}) } end
    local t0 = util_now_ms()
    local res = quote_prefetch(codes, { source = scan_source(opts), force = opts.force,
                                        max_days = opts.bars_days })
    res.ms = util_now_ms() - t0
    return res
end

-- Codes to work on. `codes` wins; otherwise the watchlist, or the market
-- snapshot — every row of it with `universe = 'market'`, or the ones that pass
-- the filters with `universe = 'screen'`.
--
-- opts = { codes = {...}, universe = 'watchlist' | 'screen' | 'market',
--          filters, limit }
-- COROUTINE-FREE: it reads the stored snapshot.
function g_exports.strategy_universe(opts)
    opts = opts or {}
    -- The whole market is allowed: 5,500 stocks is twenty minutes of fetching
    -- the first time and seconds afterwards. The default stays small because a
    -- scan is usually a question about a shortlist.
    local limit = math.max(1, math.min(opts.limit or 30, 6000))
    local out = {}
    if type(opts.codes) == 'table' and #opts.codes > 0 then
        for _, c in ipairs(opts.codes) do
            local sec = source_em_security(c)
            if sec then out[#out + 1] = { code = sec.code } end
            if #out >= limit then break end
        end
        return out, 'codes'
    end
    if opts.universe == 'screen' or opts.universe == 'market' then
        -- 'market' is 'screen' with nothing asked of the rows.
        local filters = opts.universe == 'market' and {} or util_copy(opts.filters)
        filters.limit = limit
        filters.sort = filters.sort or 'market_cap'
        local res = market_screen(filters)
        if not res or not res.rows then return {}, opts.universe end
        for _, r in ipairs(res.rows) do
            out[#out + 1] = { code = r.code, name = r.name, industry = r.industry,
                              pe_ttm = r.pe_ttm, pb = r.pb, roe = r.roe,
                              market_cap = r.market_cap }
        end
        return out, opts.universe
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
    if doc and type(doc.rows) == 'table' and #doc.rows > 0 then return doc.rows, doc end
    if opts.offline then return nil, doc and '缓存为空' or '没有行情缓存' end
    -- The prefetch already tried; this is the one-at-a-time fallback for a
    -- code it could not get, and it is paced because it means Eastmoney.
    local pace = opts.pace_ms or cfg_int('STRATEGY_PACE_MS', PACE_DEFAULT)
    local fresh, ecode, err = quote_refresh(code, { source = scan_source(opts) })
    sched_sleep(pace)
    if not fresh and ecode ~= 'not_found' then
        sched_sleep(RETRY_PAUSE_MS)
        fresh, ecode, err = quote_refresh(code, { source = scan_source(opts) })
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
    local axes = backtest_sweep_axes
    local mas = opts.ma_days or axes.ma_days
    local aboves = opts.above_pct or axes.above_pct
    local flats = opts.flat_max or axes.flat_max
    local d = backtest_breakout_params()
    local out = {}
    local trend = backtest_month_trend(px)
    for _, n in ipairs(mas) do
        local ma = backtest_ma_series(px, n)
        for _, flat in ipairs(flats) do
            for _, above in ipairs(aboves) do
                local found = backtest_breakout(px, {
                    ma = ma, ma_days = n, flat_lookback = opts.flat_lookback or d.flat_lookback,
                    flat_max = flat, above_pct = above,
                    min_day_gain = opts.min_day_gain, cooldown = opts.cooldown,
                    month_up = opts.month_up, month_trend = trend,
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

    local fetch = prefetch(list, opts)
    local collected, used, skipped = {}, {}, {}
    local base_rets = {}
    local look = opts.flat_lookback or backtest_breakout_params().flat_lookback
    local first_offset = math.max(table.unpack(opts.ma_days or backtest_sweep_axes.ma_days)) + look
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
    local lengths, starts = {}, {}
    for _, u in ipairs(used) do
        if not from or u.from < from then from = u.from end
        if not to or u.to > to then to = u.to end
        bars = bars + u.days
        lengths[#lengths + 1] = u.days
        starts[#starts + 1] = u.from
    end
    -- What a typical stock contributed. The earliest first day alone reads as
    -- "five years" when one stock in a thousand has them and the rest have
    -- eighteen months — which is how a grid on a short cache once passed for
    -- a five-year result.
    table.sort(lengths)
    table.sort(starts)
    local mid = (#used + 1) // 2
    local span = { median_days = lengths[mid], typical_from = starts[mid], earliest_from = from, to = to }

    return {
        universe = kind, stocks = #used, skipped = util_json_array(skipped),
        used = util_json_array(used), fetch = fetch,
        from = from, to = to, days = bars, span = span,
        signal = 'breakout', signal_note = backtest_signal_list.breakout,
        horizon = horizon, objective = objective,
        flat_lookback = look,
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

-- A length in trading days, said in weeks: 40 is 8, 42 is 8.4.
local function weeks(days)
    local wk = backtest_week_days
    if days % wk == 0 then return days // wk end
    return days / wk
end

-- The rules a client can offer ready-made, with their numbers as configured.
-- A client lists these instead of knowing them: the defaults are the grid's
-- answer and live in xmoat.cfg, and a phone app should not carry its own copy.
-- The fields are in weeks where the rule is said in weeks ("8 周均线");
-- strategy.scan takes them as they are and turns them into trading days.
function g_exports.strategy_rules()
    local d = backtest_breakout_params()
    return util_json_array({
        {
            id = 'breakout',
            version = backtest_breakout_version,
            title = '突破横盘周线',
            summary = '股价横盘一段时间（这段时间的最高价和最低价相差不超过一定幅度），' ..
                      '然后收盘上穿均线：从一个窄平台里走了出来；而且个股自己的月线向上。',
            -- What the backtest measured for the default numbers, which stays
            -- true whatever the config now says; the fields carry the values.
            basis = '5 年回测（2021–2026 全市场，持有 60 个交易日，和同期随便哪天买比胜率）：' ..
                    '只看横盘突破是 +0.2；加上个股月线向上是 +3.2，2021–23 年 +5.4、2024–26 年 +0.7，' ..
                    '优势在变小，持有 120 天时不成立。沪深300 多头时的信号 +4.1，但这种日子只出现在 2024–26 年' ..
                    '这一段。追周线强势（多头排列、创 26/52 周新高）两段都跑输 4–5.5。' ..
                    '这些都还不能说是可靠的优势，下面的信号记录是往后的检验。',
            fields = util_json_array({
                { name = 'ma_weeks', label = '均线', unit = '周', default = weeks(d.ma_days),
                  min = 1, max = 100, step = 1 },
                { name = 'above_pct', label = '上穿时高出均线', unit = '%', default = d.above_pct,
                  min = 0, max = 50, step = 0.5 },
                { name = 'flat_weeks', label = '横盘', unit = '周',
                  default = weeks(d.flat_lookback), min = 1, max = 52, step = 1 },
                { name = 'flat_max', label = '横盘振幅不超过', unit = '%', default = d.flat_max,
                  min = 1, max = 50, step = 1 },
                { name = 'min_day_gain', label = '当天至少涨', unit = '%', default = d.min_day_gain,
                  min = 0, max = 20, step = 0.5 },
                { name = 'month_up', type = 'boolean', default = d.month_up,
                  label = '个股月线向上（收盘在上升的 10 个月均线之上）' },
                { name = 'bull_only', type = 'boolean', default = d.bull_only,
                  label = '沪深300 不在多头时不推送（信号照常列出和记录）' },
                { name = 'days', label = '首次突破在最近', unit = '个交易日内', default = 1,
                  min = 1, max = 20, step = 1 },
            }),
        },
    })
end

-- COROUTINE-ONLY. Which stocks broke out just now.
--
-- A signal is the day the close crosses the line out of a base (see
-- backtest_breakout), the same unit the backtest counts: a stock that crossed
-- last week and has run 40% since is not breaking out today, and listing it
-- would put a chase at the top of the list.
--
-- opts adds { days = 1 }: how many of the most recent bars count as "now", so
-- a breakout from two days ago is still findable on a Wednesday morning, with
-- how far it has gone since; { ma_weeks, flat_weeks }, the same two windows
-- said in weeks; { cooldown }, 1 to count a stock crossing back and forth
-- every time it does; and
-- { on_bars = fn(code, bars) }, called with each stock's bars as they are read,
-- for a caller keeping its own prices current without reading them again.
function g_exports.strategy_scan(opts)
    opts = util_copy(opts)
    local days = math.max(1, math.min(opts.days or 1, 20))
    local d = backtest_breakout_params()
    local wk = backtest_week_days
    if not opts.ma_days and opts.ma_weeks then
        opts.ma_days = math.floor(opts.ma_weeks * wk + 0.5)
    end
    if not opts.flat_lookback and opts.flat_weeks then
        opts.flat_lookback = math.floor(opts.flat_weeks * wk + 0.5)
    end
    local p = {
        ma_days = opts.ma_days or d.ma_days, above_pct = opts.above_pct or d.above_pct,
        flat_max = opts.flat_max or d.flat_max, flat_lookback = opts.flat_lookback or d.flat_lookback,
        min_day_gain = opts.min_day_gain or d.min_day_gain, cooldown = opts.cooldown or d.cooldown,
    }
    -- Booleans, so `or` would turn an explicit false into the default.
    if opts.month_up == nil then p.month_up = d.month_up else p.month_up = opts.month_up end
    if opts.bull_only == nil then p.bull_only = d.bull_only else p.bull_only = opts.bull_only end
    -- The rule as configured, rather than a variation of it being tried out:
    -- only that is worth keeping a record of (engine/signals.lua).
    local configured = true
    for k, v in pairs(p) do
        if v ~= d[k] then configured = false end
    end
    local list, kind = strategy_universe(opts)
    if #list == 0 then return nil, 'bad_request', '没有可用的股票（自选为空，或筛选没有结果）' end

    local fetch = prefetch(list, opts)

    -- The market's state on each signal day, from the index the review reads
    -- and by the review's own definition of 多头. A signal on a day that was
    -- not 多头 is still listed, and kept in the record, but marked `held`:
    -- only 2024-2026 had such days at all, and in them the rule beat buying any
    -- stock on the same days by 4 points of win rate — one market episode, not
    -- a law, so the day's state is shown rather than the stock hidden.
    local regime_code = cfg_get('REVIEW_REGIME_INDEX', '000300')
    local index = quote_series('idx:' .. regime_code, { offline = opts.offline })
    local index_rows = index and type(index.rows) == 'table' and index.rows or {}
    local regimes = {}
    local function regime_on(date)
        if regimes[date] then return regimes[date] end
        local upto = {}
        for _, r in ipairs(index_rows) do
            if r.date > date then break end
            upto[#upto + 1] = r
        end
        regimes[date] = review_regime(upto).state
        return regimes[date]
    end

    local hits, checked, skipped = {}, 0, {}
    for i, item in ipairs(list) do
        -- Five thousand stocks read from disk is ten seconds of work, and the
        -- host serves every other request from this same thread: hand it back
        -- now and then, so the rest of the page still answers meanwhile.
        if i % 200 == 0 then sched_sleep(1) end
        local px, why = bars_for(item.code, opts)
        if px and opts.on_bars then opts.on_bars(item.code, px) end
        if not px or #px < p.ma_days + p.flat_lookback + 1 then
            skipped[#skipped + 1] = { code = item.code,
                                      reason = px and '日线太短' or tostring(why) }
        else
            checked = checked + 1
            local found = backtest_breakout(px, {
                ma_days = p.ma_days, flat_lookback = p.flat_lookback, flat_max = p.flat_max,
                above_pct = p.above_pct, min_day_gain = p.min_day_gain, cooldown = p.cooldown,
                month_up = p.month_up,
            })
            -- The newest signal per stock and no more. With a cooldown of one
            -- and a window of several days, the same breakout would otherwise
            -- appear once a day, which reads as several opportunities and is one.
            local newest
            for _, e in ipairs(found.entries) do
                if e.index > #px - days and (not newest or e.index > newest.index) then
                    newest = e
                end
            end
            if newest then
                local last = px[#px]
                local now = util_num(last.close)
                hits[#hits + 1] = {
                    code = item.code, name = item.name, industry = item.industry,
                    date = newest.date, close = newest.close, ma = newest.ma,
                    above = newest.above, width = newest.width, box_high = newest.box_high,
                    day_gain = newest.day_gain,
                    bars_ago = #px - newest.index,
                    last_date = last.date, last_close = now,
                    regime = regime_on(newest.date),
                    month_ma10 = newest.month_ma10,
                    since_pct = (now and newest.close > 0) and (now / newest.close - 1) * 100 or nil,
                    pe_ttm = item.pe_ttm, pb = item.pb, roe = item.roe,
                    market_cap = item.market_cap,
                }
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
    for _, hit in ipairs(hits) do
        if p.bull_only and hit.regime ~= 'bull' then hit.held = true end
    end
    local last_index = index_rows[#index_rows]
    p.ma_weeks, p.flat_weeks = weeks(p.ma_days), weeks(p.flat_lookback)
    return {
        regime = { index = regime_code, date = last_index and last_index.date,
                   state = last_index and regime_on(last_index.date) or 'unknown' },
        universe = kind, checked = checked, days = days, fetch = fetch,
        params = p, configured = configured,
        hits = util_json_array(hits), skipped = util_json_array(skipped),
        note = '这是信号，不是结论：它只说价格从一个平台上走了出来，' ..
               '这家公司值不值得买仍然要看财报、估值和检查清单。',
    }
end

-- ---------------------------------------------------------------------------
-- Attribution: where does the rule work better?
--
-- The tempting version of this question answers itself wrongly. Group the
-- signals by industry, sort by return, and the top of the list is whichever
-- industry rose over the window — semiconductors did, so signals in
-- semiconductors made money whether or not the signal meant anything.
--
-- So every group is compared against ITS OWN baseline: the same stocks, the
-- same window, bought on any day. What is reported is the difference. And
-- because a hundred groups are being asked the same question, the summary
-- says how many of them beat their own baseline — if it is about half, the
-- list is noise sorted by luck.
--
-- Returns are accumulated as histograms rather than kept: two million daily
-- returns across three groupings is a lot of numbers to hold, and half a
-- percent of resolution on a median is plenty.
-- ---------------------------------------------------------------------------

local HIST_LOW, HIST_STEP, HIST_BINS = -100, 0.5, 1000

local function hist_new()
    return { n = 0, sum = 0, wins = 0, bins = {}, min = nil, max = nil }
end

local function hist_add(h, v)
    h.n = h.n + 1
    h.sum = h.sum + v
    if v > 0 then h.wins = h.wins + 1 end
    if not h.min or v < h.min then h.min = v end
    if not h.max or v > h.max then h.max = v end
    local i = math.floor((v - HIST_LOW) / HIST_STEP)
    if i < 0 then i = 0 elseif i > HIST_BINS then i = HIST_BINS end
    h.bins[i] = (h.bins[i] or 0) + 1
end

local function hist_stats(h)
    if h.n == 0 then return { n = 0 } end
    local want, acc, median = h.n / 2, 0, nil
    for i = 0, HIST_BINS do
        local c = h.bins[i]
        if c then
            acc = acc + c
            if not median and acc >= want then
                median = HIST_LOW + (i + 0.5) * HIST_STEP
            end
        end
    end
    return { n = h.n, win_rate = h.wins / h.n * 100, avg = h.sum / h.n,
             median = median, best = h.max, worst = h.min }
end

-- COROUTINE-ONLY. One parameter set across a universe, grouped by industry,
-- listing board and region.
--
-- opts: the usual universe options, plus the rule's own parameters and
--   horizon      = 60
--   min_signals  = 30    -- fewer than this and a group is counted, not ranked
--   group        = 'industry' | 'board' | 'region', or nil for all three
function g_exports.strategy_attribute(opts)
    opts = util_copy(opts)
    local horizon = opts.horizon or 60
    local min_signals = opts.min_signals or 30
    local d = backtest_breakout_params()
    local list, kind = strategy_universe(opts)
    if #list == 0 then return nil, 'bad_request', '没有可用的股票（自选为空，或筛选没有结果）' end

    local fetch = prefetch(list, opts)
    local regions = groups_regions({ offline = opts.offline })
    if not regions then cfg_log_warn('没有地域映射，只能按行业和板块分组') end

    local kinds = opts.group and { opts.group } or { 'industry', 'board', 'region' }

    -- cells[kind][value] = { signal = hist, base = hist, stocks, fired }
    local cells, used, skipped = {}, 0, {}
    for _, k in ipairs(kinds) do cells[k] = {} end

    for _, item in ipairs(list) do
        local px, why = bars_for(item.code, opts)
        if not px or #px < horizon + (opts.ma_days or d.ma_days) + (opts.flat_lookback or d.flat_lookback) then
            skipped[#skipped + 1] = { code = item.code, reason = px and '日线太短' or tostring(why) }
        else
            used = used + 1
            local g = groups_of({ code = item.code, industry = item.industry,
                                  board = item.board }, regions)
            local found = backtest_breakout(px, {
                ma_days = opts.ma_days or d.ma_days,
                flat_lookback = opts.flat_lookback or d.flat_lookback,
                flat_max = opts.flat_max or d.flat_max,
                above_pct = opts.above_pct or d.above_pct,
                min_day_gain = opts.min_day_gain, cooldown = opts.cooldown,
                month_up = opts.month_up,
            })
            for _, k in ipairs(kinds) do
                local value = g[k]
                if value then
                    local cell = cells[k][value]
                    if not cell then
                        cell = { signal = hist_new(), base = hist_new(), stocks = 0, fired = 0 }
                        cells[k][value] = cell
                    end
                    cell.stocks = cell.stocks + 1
                    if #found.entries > 0 then cell.fired = cell.fired + 1 end
                    for _, e in ipairs(found.entries) do
                        local to = px[e.index + horizon]
                        if to and e.close and e.close > 0 and to.close then
                            hist_add(cell.signal, (to.close / e.close - 1) * 100)
                        end
                    end
                    -- The group's own baseline: every day of every one of its
                    -- stocks, held the same number of days.
                    for i = 1, #px - horizon do
                        local a, b = util_num(px[i].close), util_num(px[i + horizon].close)
                        if a and b and a > 0 then hist_add(cell.base, (b / a - 1) * 100) end
                    end
                end
            end
        end
    end

    local out, beat, ranked_total = {}, 0, 0
    for _, k in ipairs(kinds) do
        local rows, thin = {}, 0
        for value, cell in pairs(cells[k]) do
            local sig, base = hist_stats(cell.signal), hist_stats(cell.base)
            local row = {
                group = k, value = value, label = groups_label(k, value),
                stocks = cell.stocks, fired = cell.fired, signals = sig.n,
                win_rate = sig.win_rate, median = sig.median, avg = sig.avg, worst = sig.worst,
                base_win_rate = base.win_rate, base_median = base.median, base_avg = base.avg,
                edge = (sig.median and base.median) and (sig.median - base.median) or nil,
                edge_win = (sig.win_rate and base.win_rate) and (sig.win_rate - base.win_rate) or nil,
            }
            if sig.n >= min_signals then
                rows[#rows + 1] = row
                ranked_total = ranked_total + 1
                if (row.edge or 0) > 0 then beat = beat + 1 end
            else
                thin = thin + 1
            end
        end
        table.sort(rows, function(a, b) return (a.edge or -1e9) > (b.edge or -1e9) end)
        out[#out + 1] = { group = k, rows = util_json_array(rows), thin = thin }
    end

    return {
        universe = kind, stocks = used, skipped = util_json_array(skipped), fetch = fetch,
        horizon = horizon, min_signals = min_signals,
        params = { ma_days = opts.ma_days or d.ma_days, above_pct = opts.above_pct or d.above_pct,
                   flat_max = opts.flat_max or d.flat_max,
                   flat_lookback = opts.flat_lookback or d.flat_lookback,
                   min_day_gain = opts.min_day_gain or d.min_day_gain,
                   cooldown = opts.cooldown or d.cooldown },
        regions = regions and { fetched_at = regions.fetched_at, stocks = regions.stocks } or nil,
        groups = util_json_array(out),
        summary = { ranked = ranked_total, beat_own_baseline = beat },
        notes = util_json_array({
            '每一组都和它自己的基准比：同样这些股票、同一窗口里随便哪天买。' ..
            '不这么比的话，排在前面的只会是这五年本来就涨的行业，和信号有没有用无关。',
            string.format('一共排了 %d 组，其中 %d 组的信号中位数高于自己的基准；' ..
                          '这个比例接近一半的话，这张表就是按运气排序的噪声。',
                          ranked_total, beat),
            '同一波行情会让一个行业里的股票同时出信号，所以组内的样本远不如数量看上去那么独立。',
            '不含交易成本、滑点和停牌；价格用前复权。',
        }),
    }
end
