-- engine/backtest.lua — what would have happened, on this stock's own history.
--
-- Exports: backtest_signals, backtest_horizons, backtest_barrier,
--          backtest_evaluate, backtest_run
--
-- WHAT IS BEING TESTED. Not a model's opinion and not a story: the engine's
-- own rules, the ones that produce the levels. "The multiple is in the cheapest
-- quarter of its own history", "the averages are in bull order", or both. Each
-- is a function of data that existed on the day it fired, which is the only
-- reason this is a backtest and not a drawing.
--
-- NO LOOKAHEAD, and it takes one specific piece of care. The percentile on day
-- t is computed over days up to t and nothing after it — an expanding window,
-- not the percentile shown today. That is why the daily valuation series is
-- stored as the source published it, day by day, rather than recomputed from
-- the reports as they stand now: a single restatement would otherwise leak a
-- number backwards into a date before anyone knew it.
--
-- WHAT IT CANNOT TELL YOU. One stock's history is one path. Two hundred
-- signals on 600519 are not two hundred independent experiments — they are a
-- few episodes, sampled daily, of a company that happened to do well. A win
-- rate here is a description of that path, not a probability about the next
-- one, and the baseline is printed next to it for exactly this reason: if
-- buying on any random day of the same window did as well, the rule added
-- nothing.

local DEFAULT_HORIZONS = { 20, 60, 120, 250 }
local MIN_SAMPLE = 240          -- as in valuation_percentile: a year of days

local SIGNALS = {
    value = '估值分位：锚指标处于自身历史最便宜的一段',
    trend = '技术面：均线多头排列',
    value_trend = '两者同时满足：便宜，而且已经不再下跌',
    band = '你设置的合理区间：锚指标低于区间下沿',
}

g_exports.backtest_signal_list = SIGNALS

-- Insert into a sorted array, keeping it sorted. The expanding percentile is
-- the whole cost of this file, and rebuilding it each day would be quadratic
-- with a sort inside; this is quadratic with a memmove inside, which for a few
-- thousand days is nothing.
local function insert_sorted(arr, v)
    local lo, hi = 1, #arr + 1
    while lo < hi do
        local mid = (lo + hi) // 2
        if arr[mid] < v then lo = mid + 1 else hi = mid end
    end
    table.insert(arr, lo, v)
end

local function quantile_sorted(arr, p)
    local n = #arr
    if n == 0 then return nil end
    local pos = math.max(0, math.min(100, p)) / 100 * (n - 1) + 1
    local lo = math.floor(pos)
    local hi = math.min(n, lo + 1)
    return arr[lo] + (arr[hi] - arr[lo]) * (pos - lo)
end

-- The days a signal fired.
--
-- val: the daily valuation rows (oldest first), px: the daily bars, opts:
--   { signal, metric, percentile = 25, band_low, cooldown = 20,
--     min_sample = 240 }
--
-- Returns { entries = { { date, index, close, metric_value, threshold } },
--           tested = how many days were eligible to fire at all }.
function g_exports.backtest_signals(val, px, opts)
    opts = opts or {}
    local signal = opts.signal or 'value'
    local metric = opts.metric or 'pe_ttm'
    local pctl = opts.percentile or 25
    local cooldown = opts.cooldown or 20
    local min_sample = opts.min_sample or MIN_SAMPLE

    -- Price bars by date, so a valuation day can find its own bar. The two
    -- series come from different endpoints and one of them can be a day behind.
    local index_of = {}
    for i, r in ipairs(px or {}) do index_of[r.date] = i end

    local sorted, entries, tested = {}, {}, 0
    local last_fire = nil
    for _, row in ipairs(val or {}) do
        local v = util_num(row[metric])
        local i = index_of[row.date]
        -- The threshold is computed BEFORE today's value joins the window, so
        -- a day is never compared against a percentile it helped define.
        local threshold = #sorted >= min_sample and quantile_sorted(sorted, pctl) or nil
        if v and v > 0 then insert_sorted(sorted, v) end

        -- A percentile rule needs its window before it can say anything; a
        -- rule that only reads prices does not.
        if i and (threshold or signal == 'trend' or signal == 'band') then
            tested = tested + 1
            local cheap = v ~= nil and v > 0 and threshold ~= nil and v <= threshold
            local fires
            if signal == 'value' then
                fires = cheap
            elseif signal == 'band' then
                fires = v ~= nil and v > 0 and opts.band_low ~= nil and v <= opts.band_low
            elseif signal == 'trend' or signal == 'value_trend' then
                -- Alignment on the bars up to i, and nothing after it.
                local ma5 = tech_ma(px, 5, i)
                local ma10 = tech_ma(px, 10, i)
                local ma20 = tech_ma(px, 20, i)
                local ma60 = tech_ma(px, 60, i)
                local close = util_num(px[i].close)
                local aligned = ma5 and ma10 and ma20 and ma60 and close and
                    close > ma5 and ma5 > ma10 and ma10 > ma20 and ma20 > ma60
                if signal == 'trend' then
                    fires = aligned
                else
                    fires = aligned and cheap
                end
            end
            if fires and (not last_fire or (i - last_fire) >= cooldown) then
                last_fire = i
                entries[#entries + 1] = { date = row.date, index = i,
                                          close = util_num(px[i].close),
                                          metric_value = v, threshold = threshold }
            end
        end
    end
    return { entries = entries, tested = tested }
end

local function stats_of(returns)
    if #returns == 0 then return nil end
    local wins, sum = 0, 0
    for _, r in ipairs(returns) do
        if r > 0 then wins = wins + 1 end
        sum = sum + r
    end
    local sorted = {}
    for i, r in ipairs(returns) do sorted[i] = r end
    table.sort(sorted)
    return {
        n = #returns,
        win_rate = wins / #returns * 100,
        avg = sum / #returns * 100,
        median = fin_median(sorted) * 100,
        best = sorted[#sorted] * 100,
        worst = sorted[1] * 100,
    }
end

-- Forward returns from each entry, per horizon. An entry too close to the end
-- of the data simply has no result for the longer horizons, and the count says
-- so rather than the sample quietly shrinking.
function g_exports.backtest_horizons(entries, px, horizons)
    local out = {}
    for _, h in ipairs(horizons) do
        local rets = {}
        for _, e in ipairs(entries) do
            local from, to = px[e.index], px[e.index + h]
            local a, b = from and util_num(from.close), to and util_num(to.close)
            if a and b and a > 0 then rets[#rets + 1] = b / a - 1 end
        end
        local st = stats_of(rets) or { n = 0 }
        st.days = h
        out[#out + 1] = st
    end
    return out
end

-- Take profit and stop loss, walked day by day on the bars themselves: which
-- level the price touched first, using each day's high and low.
--
-- A day whose range covers both is counted as the stop. Without intraday data
-- there is no way to know which came first, and calling it a win would be the
-- flattering assumption — the one that makes every backtest look good.
function g_exports.backtest_barrier(entries, px, opts)
    opts = opts or {}
    local tp = (opts.take_profit or 20) / 100
    local sl = (opts.stop_loss or 10) / 100
    local limit = opts.horizon or 250

    local hit_tp, hit_sl, neither, both_same_day = 0, 0, 0, 0
    local days_tp, days_sl = 0, 0
    for _, e in ipairs(entries) do
        local entry = e.close
        local done = false
        if entry and entry > 0 then
            local up, down = entry * (1 + tp), entry * (1 - sl)
            for i = e.index + 1, math.min(#px, e.index + limit) do
                local hi = util_num(px[i].high) or util_num(px[i].close)
                local lo = util_num(px[i].low) or util_num(px[i].close)
                local touched_up = hi and hi >= up
                local touched_down = lo and lo <= down
                if touched_up and touched_down then
                    both_same_day = both_same_day + 1
                    hit_sl = hit_sl + 1
                    days_sl = days_sl + (i - e.index)
                    done = true
                elseif touched_up then
                    hit_tp = hit_tp + 1
                    days_tp = days_tp + (i - e.index)
                    done = true
                elseif touched_down then
                    hit_sl = hit_sl + 1
                    days_sl = days_sl + (i - e.index)
                    done = true
                end
                if done then break end
            end
        end
        if not done then neither = neither + 1 end
    end
    local decided = hit_tp + hit_sl
    return {
        take_profit = tp * 100, stop_loss = sl * 100, horizon = limit,
        n = #entries,
        hit_tp = hit_tp, hit_sl = hit_sl, neither = neither,
        both_same_day = both_same_day,
        win_rate = decided > 0 and hit_tp / decided * 100 or nil,
        tp_rate = #entries > 0 and hit_tp / #entries * 100 or nil,
        sl_rate = #entries > 0 and hit_sl / #entries * 100 or nil,
        avg_days_tp = hit_tp > 0 and days_tp / hit_tp or nil,
        avg_days_sl = hit_sl > 0 and days_sl / hit_sl or nil,
    }
end

-- Every day in the same window, as the comparison. Without it a win rate is
-- unreadable: on a stock that tripled, buying on any day at all wins most of
-- the time.
local function baseline_entries(px, from_index)
    local out = {}
    for i = from_index or 1, #px do
        out[#out + 1] = { index = i, date = px[i].date, close = util_num(px[i].close) }
    end
    return out
end

-- Put the pieces together. Pure: everything it needs is passed in.
function g_exports.backtest_evaluate(val, px, opts)
    opts = opts or {}
    local horizons = opts.horizons or DEFAULT_HORIZONS
    local found = backtest_signals(val, px, opts)
    local entries = found.entries
    if #entries == 0 then
        return { signal = opts.signal or 'value', entries = 0, tested = found.tested,
                 note = '这段历史里这个信号一次都没有出现过' }
    end
    local first = entries[1].index
    local base = baseline_entries(px, first)
    return {
        signal = opts.signal or 'value',
        signal_note = SIGNALS[opts.signal or 'value'],
        metric = opts.metric, percentile = opts.percentile,
        entries = #entries, tested = found.tested,
        cooldown = opts.cooldown or 20,
        from = entries[1].date, to = entries[#entries].date,
        price_from = px[1] and px[1].date, price_to = px[#px] and px[#px].date,
        horizons = util_json_array(backtest_horizons(entries, px, horizons)),
        barrier = backtest_barrier(entries, px, opts),
        baseline = {
            n = #base,
            from = px[first] and px[first].date,
            horizons = util_json_array(backtest_horizons(base, px, horizons)),
            barrier = backtest_barrier(base, px, opts),
        },
        dates = util_json_array((function()
            -- The last few entry dates, so a reader can go and look at them.
            local out = {}
            for i = math.max(1, #entries - 19), #entries do
                out[#out + 1] = { date = entries[i].date, close = entries[i].close,
                                  value = entries[i].metric_value,
                                  threshold = entries[i].threshold }
            end
            return out
        end)()),
    }
end

-- COROUTINE-ONLY (it may fetch the price series). Returns the result, or nil
-- plus (error code, message).
function g_exports.backtest_run(code, opts)
    opts = util_copy(opts)
    local rec, lerr = stock_load(code)
    if lerr then return nil, 'internal', lerr end
    if not rec then return nil, 'not_fetched', tostring(code) .. ' 还没有获取过数据，先刷新' end
    local val = rec.valuation or {}
    if #val < MIN_SAMPLE then
        return nil, 'bad_request', string.format('估值历史只有 %d 个交易日，不足以回测', #val)
    end

    local q, ecode, emsg = quote_series(code, { offline = opts.offline })
    if not q or type(q.rows) ~= 'table' or #q.rows == 0 then
        return nil, ecode or 'not_fetched', emsg or '没有日线数据，先调用 quote.refresh'
    end

    local watch = watch_get(code)
    opts.metric = opts.metric or levels_metric_for(rec.org_type or 'general', watch and watch.band)
    if opts.signal == 'band' then
        local band = watch and watch.band
        if not band or band.metric ~= opts.metric or not util_num(band.low) then
            return nil, 'bad_request', '这只股票没有设置该指标的区间下沿'
        end
        opts.band_low = util_num(band.low)
    end

    local res = backtest_evaluate(val, q.rows, opts)
    res.code = rec.code
    res.name = rec.name
    res.template = rec.org_type or 'general'
    res.notes = util_json_array({
        '回测的是规则，不是预测：信号在每一天只用当天之前的数据判断，分位是扩张窗口算的。',
        '一只股票的历史只是一条路径。同一段行情里的多次信号不是多次独立实验，' ..
        '胜率是对这条路径的描述，不是下一次的概率。',
        '基准是同一窗口里「随便哪天买」的同样统计。信号的胜率没有明显高过基准，就说明这条规则没有加东西。',
        '不含交易成本、滑点和停牌；价格用前复权。',
    })
    return res
end
