-- engine/tech.lua — what the price series says, on its own terms.
--
-- Exports: tech_ma, tech_bias, tech_chips, tech_build, tech_periods
--
-- WHAT THIS IS FOR IN A VALUE TOOL. Nothing here says whether a company is
-- worth owning; the reports and the valuation do that. What it answers is the
-- other half of the question a holder actually asks — where is the price
-- relative to where it has been, and where did the people holding it buy —
-- which is what turns "cheap" into "cheap and not still falling". It is a
-- timing aid on top of a judgement, never the judgement.
--
-- Pure: bars in, numbers out, no network and no store. Everything is computed
-- from forward-adjusted daily bars (engine/quote.lua), oldest first.
--
-- THE CHIP DISTRIBUTION (筹码分布) is the one non-obvious computation here.
-- Nobody publishes who owns a stock at what price, so it is modelled: each
-- day, the fraction of the float that changed hands (the turnover rate) is
-- re-priced into that day's range, and everything held from before is faded by
-- the same fraction. What comes out is an estimate of holders' cost, and its
-- three readings are the useful ones — the average cost, how much of the float
-- is sitting on a profit, and how tightly the two are packed. The model is
-- standard and its assumptions are listed in docs/METRICS.md; it is worth
-- exactly as much as those assumptions are.

local MA_PERIODS = { 5, 10, 20, 60, 120, 250 }
local BIAS_PERIODS = { 6, 12, 24, 60 }

g_exports.tech_periods = { ma = MA_PERIODS, bias = BIAS_PERIODS }

-- The simple moving average of `n` closes ending at index `at` (the last row
-- by default), or nil when there are not n bars before it.
function g_exports.tech_ma(rows, n, at)
    at = at or #rows
    if n < 1 or at < n then return nil end
    local sum = 0
    for i = at - n + 1, at do
        local c = util_num(rows[i] and rows[i].close)
        if not c then return nil end
        sum = sum + c
    end
    return sum / n
end

-- 乖离率: how far the close sits above or below its own average, in percent.
-- The point of it is that the distance itself mean-reverts — a large positive
-- bias is a stretched price whatever the story.
function g_exports.tech_bias(rows, n, at)
    at = at or #rows
    local ma = tech_ma(rows, n, at)
    local close = util_num(rows[at] and rows[at].close)
    if not ma or not close or ma == 0 then return nil end
    return (close - ma) / ma * 100
end

-- One day's average traded price: the money divided by the shares when both
-- are there (volume is in 手, a hundred shares), and the bar's own middle when
-- they are not.
local function day_vwap(r)
    local amount, volume = util_num(r.amount), util_num(r.volume)
    if amount and volume and volume > 0 then
        local p = amount / (volume * 100)
        local low, high = util_num(r.low), util_num(r.high)
        -- A vwap outside the day's range means one of the two fields is in
        -- units we did not expect; the middle is the safe answer.
        if low and high and p >= low * 0.9 and p <= high * 1.1 then return p end
    end
    local high, low, close = util_num(r.high), util_num(r.low), util_num(r.close)
    if high and low and close then return (high + low + close * 2) / 4 end
    return close
end

-- The modelled distribution of holders' cost.
--
-- opts = { days = 500, decay = 1, buckets = 200 }
--   days    how far back to model. Chips older than two years have been faded
--           to almost nothing by turnover anyway.
--   decay   multiplies the turnover rate. 1 means a day's turnover replaces
--           exactly that fraction of the float's cost; below 1 assumes some of
--           the volume is the same shares changing hands repeatedly.
--
-- Returns nil plus a reason when the bars cannot support it.
function g_exports.tech_chips(rows, opts)
    opts = opts or {}
    local days = opts.days or 500
    local decay = opts.decay or 1
    local nb = opts.buckets or 200

    local from = math.max(1, #rows - days + 1)
    local pmin, pmax, usable = nil, nil, 0
    for i = from, #rows do
        local r = rows[i]
        local low, high, t = util_num(r.low), util_num(r.high), util_num(r.turnover)
        if low and high and t and t > 0 then
            usable = usable + 1
            if not pmin or low < pmin then pmin = low end
            if not pmax or high > pmax then pmax = high end
        end
    end
    -- Turnover is the whole model. Without it (an index, a suspended stock, a
    -- source that omits the field) there is nothing to distribute.
    if usable < 60 or not pmin or not pmax or pmax <= pmin then
        return nil, '可用的换手率数据不足'
    end

    local step = (pmax - pmin) / nb
    local w = {}
    for i = 0, nb do w[i] = 0 end

    for i = from, #rows do
        local r = rows[i]
        local low, high, t = util_num(r.low), util_num(r.high), util_num(r.turnover)
        if low and high and t and t > 0 then
            local frac = math.min(1, math.max(0, t / 100 * decay))
            local keep = 1 - frac
            for b = 0, nb do w[b] = w[b] * keep end
            -- Spread the day's turnover over its range as a triangle peaking
            -- at the average traded price: more shares changed hands near it
            -- than at the extremes of the day.
            local peak = math.min(high, math.max(low, day_vwap(r) or (high + low) / 2))
            local b0 = math.max(0, math.floor((low - pmin) / step))
            local b1 = math.min(nb, math.ceil((high - pmin) / step))
            local shape, total = {}, 0
            for b = b0, b1 do
                local p = pmin + b * step
                local v
                if high == low then v = 1
                elseif p <= peak then v = peak > low and (p - low) / (peak - low) or 1
                else v = high > peak and (high - p) / (high - peak) or 1 end
                if v < 0 then v = 0 end
                shape[b] = v
                total = total + v
            end
            if total > 0 then
                for b = b0, b1 do w[b] = w[b] + frac * shape[b] / total end
            end
        end
    end

    local sum, cost = 0, 0
    for b = 0, nb do
        sum = sum + w[b]
        cost = cost + w[b] * (pmin + b * step)
    end
    if sum <= 0 then return nil, '筹码权重为零' end

    local close = util_num(rows[#rows].close)
    -- The price below which a given share of the chips sits.
    local function at_share(share)
        local want, acc = sum * share, 0
        for b = 0, nb do
            acc = acc + w[b]
            if acc >= want then return pmin + b * step end
        end
        return pmax
    end
    local below = 0
    if close then
        for b = 0, nb do
            if pmin + b * step <= close then below = below + w[b] end
        end
    end

    local low90, high90 = at_share(0.05), at_share(0.95)
    local low70, high70 = at_share(0.15), at_share(0.85)
    -- 集中度: the width of a range over its middle. A small number means the
    -- float was accumulated within a narrow band of prices.
    local function concentration(lo, hi)
        if lo + hi <= 0 then return nil end
        return (hi - lo) / (hi + lo) * 100
    end
    return {
        days = usable,
        avg_cost = cost / sum,
        profit_ratio = close and below / sum * 100 or nil,
        low_90 = low90, high_90 = high90, concentration_90 = concentration(low90, high90),
        low_70 = low70, high_70 = high70, concentration_70 = concentration(low70, high70),
        decay = decay,
    }
end

-- The highest high and lowest low of the last `n` bars, and where the close
-- sits between them (0 at the low, 100 at the high).
local function range_of(rows, n)
    local from = math.max(1, #rows - n + 1)
    local hi, lo
    for i = from, #rows do
        local h, l = util_num(rows[i].high) or util_num(rows[i].close), util_num(rows[i].low) or util_num(rows[i].close)
        if h and (not hi or h > hi) then hi = h end
        if l and (not lo or l < lo) then lo = l end
    end
    local close = util_num(rows[#rows].close)
    local pos = (hi and lo and close and hi > lo) and (close - lo) / (hi - lo) * 100 or nil
    return { days = #rows - from + 1, high = hi, low = lo, position = pos,
             from_high = (hi and close and hi > 0) and (close - hi) / hi * 100 or nil }
end

local function avg_volume(rows, n)
    local from = math.max(1, #rows - n + 1)
    local sum, count = 0, 0
    for i = from, #rows do
        local v = util_num(rows[i].volume)
        if v then sum, count = sum + v, count + 1 end
    end
    if count == 0 then return nil end
    return sum / count
end

-- The technical block of the analysis object. `rows` are daily bars, oldest
-- first; returns nil plus a reason when there are too few to say anything.
--
-- opts = { chips = { days, decay } }
function g_exports.tech_build(rows, opts)
    opts = opts or {}
    rows = rows or {}
    if #rows < 20 then return nil, '日线数据不足（至少需要 20 个交易日）' end
    local last = rows[#rows]
    local close = util_num(last.close)
    if not close then return nil, '最后一个交易日没有收盘价' end

    local ma, bias = {}, {}
    for _, n in ipairs(MA_PERIODS) do
        local v = tech_ma(rows, n)
        if v then ma[tostring(n)] = v end
    end
    for _, n in ipairs(BIAS_PERIODS) do
        local v = tech_bias(rows, n)
        if v then bias[tostring(n)] = v end
    end

    -- 多头排列: each average above the next longer one, and the price above
    -- all of them. The reverse is 空头排列; anything else is neither, which is
    -- most of the time and is stated rather than rounded to a verdict.
    local ordered = { ma['5'], ma['10'], ma['20'], ma['60'] }
    local rising, falling = true, true
    for i = 1, #ordered - 1 do
        if not ordered[i] or not ordered[i + 1] then rising, falling = false, false; break end
        if ordered[i] <= ordered[i + 1] then rising = false end
        if ordered[i] >= ordered[i + 1] then falling = false end
    end
    local above = 0
    for _, n in ipairs(MA_PERIODS) do
        if ma[tostring(n)] and close > ma[tostring(n)] then above = above + 1 end
    end
    if rising then rising = ordered[1] ~= nil and close > ordered[1] end
    if falling then falling = ordered[1] ~= nil and close < ordered[1] end

    local trend = {
        alignment = rising and 'bull' or falling and 'bear' or 'none',
        above_ma = above,
        ma_count = (function() local n = 0; for _ in pairs(ma) do n = n + 1 end; return n end)(),
    }

    local v5, v60 = avg_volume(rows, 5), avg_volume(rows, 60)
    local chips, cerr = tech_chips(rows, opts.chips)

    return {
        as_of = last.date,
        days = #rows,
        close = close,
        change_pct = util_num(last.change_pct),
        ma = ma,
        bias = bias,
        trend = trend,
        range_250 = range_of(rows, 250),
        range_60 = range_of(rows, 60),
        volume_ratio = (v5 and v60 and v60 > 0) and v5 / v60 or nil,
        chips = chips,
        chips_note = (not chips) and cerr or nil,
    }
end
