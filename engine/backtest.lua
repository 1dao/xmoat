-- engine/backtest.lua — what would have happened, on this stock's own history.
--
-- Exports: backtest_signals, backtest_horizons, backtest_barrier,
--          backtest_evaluate, backtest_run, backtest_breakout,
--          backtest_ma_series, backtest_sweep, backtest_sweep_grid,
--          backtest_sweep_rank, backtest_sweep_neighbours
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
    breakout = '横盘之后上穿均线：前 8 周最高价与最低价相差不超过 10%，当天收盘上穿 10 周线（默认值）',
}

g_exports.backtest_signal_list = SIGNALS

-- A breakout rule reads prices and nothing else, so it needs no valuation
-- history and is scanned over the bars directly.
local PRICE_ONLY = { breakout = true }

-- The rule's numbers, in one place, from config.
--
-- NOT A FITTED EDGE. These are the rule as it is meant (a base of eight weeks
-- within 10%, then a cross of the 10-week average), not a grid's pick. On the
-- whole market, 2021 to 2026, held 60 trading days and compared with buying on
-- any day of the same year, it came out 0.4 points ahead with the same win
-- rate: positive in three years of five, and -2.0 in 2025, the year with the
-- most signals. Held 20 days it was slightly behind. The variants beside it
-- (ten weeks, 3% above the line, closing over the top of the base) all landed
-- between 0 and +0.4, so there is nothing to tune here on the same data.
function g_exports.backtest_breakout_params()
    return {
        ma_days = cfg_int('BREAKOUT_MA_DAYS', 50),
        above_pct = cfg_num('BREAKOUT_ABOVE_PCT', 0),
        flat_max = cfg_num('BREAKOUT_FLAT_MAX', 10),
        flat_lookback = cfg_int('BREAKOUT_FLAT_LOOKBACK', 40),
        min_day_gain = cfg_num('BREAKOUT_MIN_DAY_GAIN', 0),
        cooldown = cfg_int('BACKTEST_COOLDOWN', 20),
    }
end

-- Ten weeks of trading days. A "10 周均线" on daily bars is this many closes;
-- computing it on weekly bars instead would move the signal to Friday and lose
-- four days of it, which is not what the rule means.
g_exports.backtest_week_days = 5

-- The moving average at every index, in one pass. The sweep asks for the same
-- window again and again, so this is computed once per window length rather
-- than per parameter combination.
function g_exports.backtest_ma_series(px, n)
    local out, sum = {}, 0
    for i = 1, #px do
        local c = util_num(px[i].close)
        sum = sum + (c or 0)
        if i > n then sum = sum - (util_num(px[i - n].close) or 0) end
        if i >= n then out[i] = sum / n end
    end
    return out
end

-- The days the breakout rule fired, and why. Separate from backtest_signals
-- because it is a different shape of question: no valuation, no expanding
-- window, just the bars.
--
-- THE RULE: the price has gone sideways — the highest high and the lowest low
-- of the `flat_lookback` days before today are within `flat_max`% of each
-- other — and today the close crosses above the `ma_days` average (by
-- `above_pct`%; 0 means crossing it at all).
--
-- The base is measured on the PRICE. The first version asked only that the
-- AVERAGE end where it had started five weeks earlier, and an average does
-- that just as well when the price swings 20% either side of it: 海安集团 on
-- 2026-09-21 had moved 0.4% on its 40-day average and 22% top to bottom on its
-- price, and was signalled. On five years of the whole market that version
-- ran 1.6 points behind buying on any day of the same year.
--
-- A CROSS, not a level: yesterday's close was at or under the line and
-- today's is over it. A stock that has sat above its average for a week is not breaking
-- out today. `cooldown` then keeps a stock that crosses back and forth from
-- counting as several breakouts in a month.
--
-- opts = {
--   ma_days,               -- the average's window in trading days (50 = 10 weeks)
--   flat_lookback,         -- how many days before today make the base
--   flat_max,              -- how wide the base may be, top to bottom, %
--   above_pct,             -- how far above the average the close must cross, %
--   min_day_gain,          -- and how much the day itself must have risen, %
--   cooldown,
--   ma = <a prepared series>,
-- }
-- Anything left out comes from backtest_breakout_params (config).
local function price_range(px, from, to)
    local hi, lo
    for k = from, to do
        local h, l = util_num(px[k].high), util_num(px[k].low)
        if not h or not l then return nil end
        if not hi or h > hi then hi = h end
        if not lo or l < lo then lo = l end
    end
    return hi, lo
end

function g_exports.backtest_breakout(px, opts)
    opts = opts or {}
    px = px or {}
    -- Anything the caller did not name falls back to the configured rule.
    local d = backtest_breakout_params()
    local n = opts.ma_days or d.ma_days
    local look = opts.flat_lookback or d.flat_lookback
    local flat_max = opts.flat_max or d.flat_max
    local above = (opts.above_pct or d.above_pct) / 100
    local day_gain = opts.min_day_gain or d.min_day_gain
    local cooldown = opts.cooldown or d.cooldown

    local ma = opts.ma or backtest_ma_series(px, n)
    local entries, tested, last_fire = {}, 0, nil
    for i = math.max(n, look) + 1, #px do
        local line, pline = ma[i], ma[i - 1]
        local close, prev = util_num(px[i].close), util_num(px[i - 1].close)
        if line and pline and close and prev then
            tested = tested + 1
            local gain = util_num(px[i].change_pct) or 0
            -- The cheap tests first: a cross is a few days a year, and only
            -- then is the base worth measuring.
            if close > line * (1 + above) and prev <= pline * (1 + above) and gain >= day_gain
                and (not last_fire or (i - last_fire) >= cooldown) then
                local hi, lo = price_range(px, i - look, i - 1)
                local width = (hi and lo and lo > 0) and (hi / lo - 1) * 100 or nil
                if width and width <= flat_max then
                    last_fire = i
                    entries[#entries + 1] = { date = px[i].date, index = i, close = close,
                                              ma = line, width = width, box_high = hi, box_low = lo,
                                              above = (close - line) / line * 100,
                                              day_gain = gain }
                end
            end
        end
    end
    return { entries = entries, tested = tested }
end

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
    if PRICE_ONLY[signal] then return backtest_breakout(px, opts) end
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

-- ---------------------------------------------------------------------------
-- The parameter sweep
--
-- "Which window and which distance work best" is a fair question and a
-- dangerous one. Run enough combinations over one stock's history and one of
-- them will look excellent by accident — that is arithmetic, not insight. So
-- this reports the whole grid rather than only its winner, and for the winner
-- it also reports how its NEIGHBOURS did: a cell that is good while everything
-- around it is bad was luck, and a plateau is a finding.
--
-- It also cannot promise "no losses". Every row carries its worst single
-- outcome, and the constraint you set (`max_worst`, `min_win_rate`,
-- `min_entries`) is what "safe enough" means here — a filter over the past,
-- not a guarantee about the future.
-- ---------------------------------------------------------------------------

-- The grid's default axes: the average, how far above it the close crosses,
-- and how wide the base may be. Shared with strategy.lua's pooled sweep.
local SWEEP_MA = { 30, 40, 50, 60, 70 }
local SWEEP_ABOVE = { 0, 1, 2, 3, 5 }
local SWEEP_FLAT = { 8, 10, 12, 15, 20 }
g_exports.backtest_sweep_axes = { ma_days = SWEEP_MA, above_pct = SWEEP_ABOVE, flat_max = SWEEP_FLAT }

local OBJECTIVES = { median = true, avg = true, win_rate = true }

local function list_or(v, default)
    if type(v) ~= 'table' or #v == 0 then return default end
    return v
end

-- px: the daily bars. opts:
--   horizon = 60,           -- the holding period every row is ranked on
--   ma_days / above_pct / flat_max = lists to try
--   flat_lookback, min_day_gain, cooldown, take_profit, stop_loss
-- Pure.
function g_exports.backtest_sweep_grid(px, opts)
    opts = opts or {}
    local horizon = opts.horizon or 60
    local mas = list_or(opts.ma_days, SWEEP_MA)
    local aboves = list_or(opts.above_pct, SWEEP_ABOVE)
    local flats = list_or(opts.flat_max, SWEEP_FLAT)
    local look = opts.flat_lookback or backtest_breakout_params().flat_lookback

    local rows = {}
    for _, n in ipairs(mas) do
        -- One pass per window, reused by every distance and flatness on it.
        local ma = backtest_ma_series(px, n)
        for _, flat in ipairs(flats) do
            for _, above in ipairs(aboves) do
                local found = backtest_breakout(px, {
                    ma = ma, ma_days = n, flat_lookback = look, flat_max = flat,
                    above_pct = above, min_day_gain = opts.min_day_gain,
                    cooldown = opts.cooldown,
                })
                local hz = backtest_horizons(found.entries, px, { horizon })[1]
                local barrier = backtest_barrier(found.entries, px, {
                    take_profit = opts.take_profit, stop_loss = opts.stop_loss,
                    horizon = opts.barrier_horizon or horizon,
                })
                rows[#rows + 1] = {
                    ma_days = n, flat_max = flat, above_pct = above,
                    entries = #found.entries,
                    n = hz.n or 0, win_rate = hz.win_rate, avg = hz.avg,
                    median = hz.median, best = hz.best, worst = hz.worst,
                    hit_tp = barrier.hit_tp, hit_sl = barrier.hit_sl,
                    barrier_win_rate = barrier.win_rate,
                }
            end
        end
    end
    return rows
end

-- The rows that satisfy the constraints, best first.
function g_exports.backtest_sweep_rank(rows, opts)
    opts = opts or {}
    local objective = OBJECTIVES[opts.objective or ''] and opts.objective or 'median'
    local min_entries = opts.min_entries or 10
    local kept = {}
    for _, r in ipairs(rows) do
        local ok = (r.n or 0) >= min_entries and r[objective] ~= nil
        if ok and opts.min_win_rate and (r.win_rate or -1) < opts.min_win_rate then ok = false end
        -- max_worst is a negative number: "no single signal lost more than".
        if ok and opts.max_worst and (r.worst or -1e9) < opts.max_worst then ok = false end
        if ok and opts.max_sl and (r.hit_sl or 0) > opts.max_sl then ok = false end
        if ok then kept[#kept + 1] = r end
    end
    table.sort(kept, function(a, b)
        if a[objective] == b[objective] then return (a.n or 0) > (b.n or 0) end
        return a[objective] > b[objective]
    end)
    return kept, objective
end

-- How the cells around `best` did, on the same objective. The number that
-- matters when deciding whether a result is real.
function g_exports.backtest_sweep_neighbours(rows, best, objective)
    if not best then return nil end
    local mas, aboves, flats = {}, {}, {}
    for _, r in ipairs(rows) do
        mas[r.ma_days] = true; aboves[r.above_pct] = true; flats[r.flat_max] = true
    end
    local function sorted_keys(t)
        local out = {}
        for k in pairs(t) do out[#out + 1] = k end
        table.sort(out)
        return out
    end
    local function neighbours_of(values, v)
        local keys, out = sorted_keys(values), {}
        for i, k in ipairs(keys) do
            if k == v then
                if keys[i - 1] then out[#out + 1] = keys[i - 1] end
                if keys[i + 1] then out[#out + 1] = keys[i + 1] end
            end
        end
        return out
    end
    local want = {}
    for _, n in ipairs(neighbours_of(mas, best.ma_days)) do
        want[#want + 1] = { ma_days = n, above_pct = best.above_pct, flat_max = best.flat_max }
    end
    for _, a in ipairs(neighbours_of(aboves, best.above_pct)) do
        want[#want + 1] = { ma_days = best.ma_days, above_pct = a, flat_max = best.flat_max }
    end
    for _, f in ipairs(neighbours_of(flats, best.flat_max)) do
        want[#want + 1] = { ma_days = best.ma_days, above_pct = best.above_pct, flat_max = f }
    end
    local found, sum, count, worst = {}, 0, 0, nil
    for _, w in ipairs(want) do
        for _, r in ipairs(rows) do
            if r.ma_days == w.ma_days and r.above_pct == w.above_pct and r.flat_max == w.flat_max then
                found[#found + 1] = r
                local v = r[objective]
                if v then
                    sum, count = sum + v, count + 1
                    if not worst or v < worst then worst = v end
                end
            end
        end
    end
    return { n = count, mean = count > 0 and sum / count or nil, worst = worst,
             cells = util_json_array(found) }
end

-- COROUTINE-ONLY (it may fetch the bars). The whole sweep for one stock.
function g_exports.backtest_sweep(code, opts)
    opts = util_copy(opts)
    local q, ecode, emsg = quote_series(code, { offline = opts.offline })
    if not q or type(q.rows) ~= 'table' or #q.rows == 0 then
        return nil, ecode or 'not_fetched', emsg or '没有日线数据，先调用 quote.refresh'
    end
    local px = q.rows
    local horizon = opts.horizon or 60
    if #px < horizon + 120 then
        return nil, 'bad_request', string.format('日线只有 %d 个交易日，不够跑 %d 日持有期的网格',
            #px, horizon)
    end

    local rows = backtest_sweep_grid(px, opts)
    local kept, objective = backtest_sweep_rank(rows, opts)
    local best = kept[1]

    -- The same statistics for buying on any day of the same window, so a row
    -- can be read as better or worse than doing nothing clever.
    local first = (opts.ma_days and opts.ma_days[#opts.ma_days] or SWEEP_MA[#SWEEP_MA]) +
                  (opts.flat_lookback or backtest_breakout_params().flat_lookback)
    local base_entries = {}
    for i = math.min(first, #px), #px do
        base_entries[#base_entries + 1] = { index = i, date = px[i].date,
                                            close = util_num(px[i].close) }
    end
    local bh = backtest_horizons(base_entries, px, { horizon })[1]

    table.sort(rows, function(a, b)
        if a.ma_days ~= b.ma_days then return a.ma_days < b.ma_days end
        if a.flat_max ~= b.flat_max then return a.flat_max < b.flat_max end
        return a.above_pct < b.above_pct
    end)

    return {
        code = q.code, name = q.name,
        signal = 'breakout', signal_note = SIGNALS.breakout,
        from = px[1] and px[1].date, to = px[#px] and px[#px].date, days = #px,
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
        baseline = { n = bh.n or 0, win_rate = bh.win_rate, avg = bh.avg,
                     median = bh.median, worst = bh.worst },
        notes = util_json_array({
            '网格是在这一只股票的历史上跑的。跑得足够多，总有一组参数碰巧好看——所以这里给的是整张表，' ..
            '以及最优那格周围几格的表现：邻居也好才说明是一片高地，孤峰就是运气。',
            '没有哪组参数能"保证不亏损"。每一行都带着它最差的一笔，' ..
            '你设的约束（最少触发次数、最低胜率、最差一笔的下限）就是这里"够安全"的定义——它是对过去的筛选，不是对未来的承诺。',
            '基准是同一窗口里随便哪天买的同样统计；跑不赢它的参数，再好看也没有意义。',
            '不含交易成本、滑点和停牌；价格用前复权。',
        }),
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
    if not PRICE_ONLY[opts.signal or 'value'] and #val < MIN_SAMPLE then
        return nil, 'bad_request', string.format('估值历史只有 %d 个交易日，不足以回测', #val)
    end

    local q, ecode, emsg = quote_series(code, { offline = opts.offline })
    if not q or type(q.rows) ~= 'table' or #q.rows == 0 then
        return nil, ecode or 'not_fetched', emsg or '没有日线数据，先调用 quote.refresh'
    end

    local watch = watch_get(code)
    opts.metric = opts.metric or levels_metric_for(rec.org_type or 'general', watch and watch.band)
    if PRICE_ONLY[opts.signal or ''] then opts.metric = nil end
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
