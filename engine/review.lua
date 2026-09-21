-- engine/review.lua — the market's day, in three parts.
--
-- Exports: review_regime, review_stance, review_sectors, review_build
--
-- THREE PARTS, in this order, because that is the order the questions come in:
--
--   1. 大盘   where the indices are, and which regime that adds up to
--   2. 结构   who rose and who fell: breadth, and the boards at both ends
--   3. 自选   what any of it did to the stocks actually being followed
--
-- The first two are about the market, and xmoat has no opinion about the
-- market; they are description, computed the same way every day so that two
-- days can be compared. The third is the only part that is about the user, and
-- it says nothing the analysis object has not already said — it just says it
-- for every watched stock at once.
--
-- THE REGIME is a label over the long moving average: above a rising 250-day
-- average is one market, below a falling one is another, and everything else
-- is the third. It is deliberately crude. A finer rule would fit the past
-- better and say no more about tomorrow, and the label exists to frame the
-- reading ("cheap in a falling market is different from cheap in a rising
-- one"), not to time anything.

local DEFAULT_INDEXES = '000001,399001,399006,000300'

-- Mechanical, and labelled as such wherever it is shown. The point is not the
-- percentages — it is that the three states imply different things about what
-- a screen full of cheap stocks MEANS.
local STANCE = {
    bull = { position = '70–100%',
             text = '指数在上升的长期均线之上。这种时候筛出来的低估值公司通常更少，' ..
                    '而且更可能是真有问题的公司，值得多花时间在检查清单上。' },
    range = { position = '50–80%',
              text = '指数在长期均线附近来回。估值分位比指数点位有用：按自己的区间分批，' ..
                     '不必对指数方向下判断。' },
    bear = { position = '30–60%',
             text = '指数在下降的长期均线之下。低估值会同时出现很多，' ..
                    '这时候的风险不是买贵了，而是一次买满——留出继续下跌时的加仓余地。' },
    unknown = { position = '—', text = '指数数据不足，无法判断。' },
}

-- rows: an index's daily bars, oldest first. Pure.
--
-- Returns { state, close, ma20, ma60, ma250, ma250_slope, drawdown,
--           volatility, reasons } — state is 'bull', 'bear', 'range' or
-- 'unknown', and `reasons` says in words what produced it.
function g_exports.review_regime(rows)
    rows = rows or {}
    local close = util_num(rows[#rows] and rows[#rows].close)
    if #rows < 250 or not close then
        return { state = 'unknown', close = close,
                 reasons = util_json_array({ '日线不足 250 个交易日' }) }
    end
    local ma20, ma60, ma250 = tech_ma(rows, 20), tech_ma(rows, 60), tech_ma(rows, 250)
    -- The slope of the long average over the last quarter, in percent. A flat
    -- average is the whole point of the third state.
    local past = tech_ma(rows, 250, #rows - 60)
    local slope = (ma250 and past and past > 0) and (ma250 - past) / past * 100 or nil

    -- Annualised standard deviation of the last twenty daily returns.
    local rets = {}
    for i = math.max(2, #rows - 19), #rows do
        local a, b = util_num(rows[i - 1].close), util_num(rows[i].close)
        if a and b and a > 0 then rets[#rets + 1] = b / a - 1 end
    end
    local vol
    if #rets >= 10 then
        local mean = 0
        for _, r in ipairs(rets) do mean = mean + r end
        mean = mean / #rets
        local ss = 0
        for _, r in ipairs(rets) do ss = ss + (r - mean) ^ 2 end
        vol = math.sqrt(ss / (#rets - 1)) * math.sqrt(250) * 100
    end

    local hi = nil
    for i = math.max(1, #rows - 249), #rows do
        local h = util_num(rows[i].high) or util_num(rows[i].close)
        if h and (not hi or h > hi) then hi = h end
    end
    local drawdown = (hi and hi > 0) and (close - hi) / hi * 100 or nil

    local state, reasons = 'range', {}
    if ma250 and slope then
        if close > ma250 and slope > 0 and ma60 and close > ma60 then
            state = 'bull'
            reasons[#reasons + 1] = string.format('收盘 %s 在 MA250 %s 之上，MA250 近 60 日上行 %.1f%%',
                util_round(close, 2), util_round(ma250, 2), slope)
        elseif close < ma250 and slope < 0 then
            state = 'bear'
            reasons[#reasons + 1] = string.format('收盘 %s 在 MA250 %s 之下，MA250 近 60 日下行 %.1f%%',
                util_round(close, 2), util_round(ma250, 2), slope)
        else
            reasons[#reasons + 1] = string.format('收盘 %s 与 MA250 %s 的关系和 MA250 的方向（%.1f%%）不一致',
                util_round(close, 2), util_round(ma250, 2), slope)
        end
    end
    if drawdown then
        reasons[#reasons + 1] = string.format('距近 250 日最高 %.1f%%', drawdown)
    end
    if vol then
        reasons[#reasons + 1] = string.format('近 20 日年化波动率 %.1f%%', vol)
    end

    return { state = state, close = close, ma20 = ma20, ma60 = ma60, ma250 = ma250,
             ma250_slope = slope, drawdown = drawdown, volatility = vol,
             reasons = util_json_array(reasons) }
end

function g_exports.review_stance(state)
    local s = STANCE[state] or STANCE.unknown
    return { position = s.position, text = s.text,
             note = '这是把三种状态机械地映射成仓位区间，不是建议，也没有任何预测成分。' }
end

-- COROUTINE-ONLY. The board table, from the store when it is recent enough.
-- `kind` is 'industry' or 'concept'.
function g_exports.review_sectors(opts)
    opts = opts or {}
    local kind = opts.kind or 'industry'
    local name = 'sectors'
    local doc, lerr = store_load(name)
    if lerr then cfg_log_warn('%s', lerr) end
    if doc and doc.kind ~= kind then doc = nil end

    local ttl = opts.max_age_min or cfg_int('REVIEW_SECTOR_TTL_MIN', 30)
    if opts.offline then return doc end
    -- The board table is a market number like any other: outside trading hours
    -- it cannot have changed since the last close, so the calendar answers
    -- first and the age limit only decides during a session.
    if not opts.force and doc and calendar_quiet(calendar_last_trading_day(), doc.fetched_at) then
        return doc
    end
    if not opts.force and doc and not quote_is_stale(doc, ttl) then return doc end

    local got, err = source_em_fetch_sectors(kind)
    if not got then
        if doc then
            cfg_log_warn('板块行情获取失败，沿用 %s 的缓存：%s', tostring(doc.fetched_at), tostring(err))
            return doc
        end
        return nil, 'upstream', '板块行情获取失败：' .. tostring(err)
    end
    local fresh = { version = 1, kind = kind, fetched_at = util_now_iso(),
                    source = got.host, count = got.count,
                    rows = util_json_array(got.rows) }
    local ok, serr = store_save(name, fresh)
    if not ok then cfg_log_warn('板块行情保存失败：%s', tostring(serr)) end
    return fresh
end

local function index_codes()
    local out = {}
    for c in cfg_get('REVIEW_INDEXES', DEFAULT_INDEXES):gmatch('[^,%s]+') do
        if c:match('^%d%d%d%d%d%d$') then out[#out + 1] = c end
    end
    return out
end

-- One index's line in the first part.
local function index_row(code, opts)
    local doc, why, err = quote_series('idx:' .. code, opts)
    if not doc or type(doc.rows) ~= 'table' or #doc.rows == 0 then return nil end
    local rows = doc.rows
    local t = tech_build(rows)
    local last = rows[#rows]
    return {
        code = code, name = doc.name,
        date = last.date, close = util_num(last.close), change_pct = util_num(last.change_pct),
        ma20 = t and t.ma['20'], ma60 = t and t.ma['60'], ma250 = t and t.ma['250'],
        position_250 = t and t.range_250 and t.range_250.position,
        from_high = t and t.range_250 and t.range_250.from_high,
        volume_ratio = t and t.volume_ratio,
        -- The fetch failed and this is the cached day. Without it a review
        -- of last Friday reads like a review of today.
        error = why == 'stale' and tostring(err) or nil,
    }, rows
end

-- The watchlist part: one line per watched stock, out of what is already
-- stored. Nothing here fetches — a review is a read, and refreshing the
-- watchlist is what the daily check is for.
local function watchlist_rows()
    local out = {}
    for _, e in ipairs(watch_list()) do
        local a = stock_analysis(e.code)
        if a then
            local q = quote_series(e.code, { offline = true })
            local last = q and type(q.rows) == 'table' and q.rows[#q.rows] or nil
            local flags = {}
            local lv, close = a.levels, last and util_num(last.close)
            if lv and not lv.note and close then
                if lv.buy and lv.buy.high and close <= lv.buy.high then
                    flags[#flags + 1] = '已进入买入区间'
                end
                if lv.stop and lv.stop.price and close <= lv.stop.price then
                    flags[#flags + 1] = '跌破止损价'
                end
                if lv.target and lv.target.price and close >= lv.target.price then
                    flags[#flags + 1] = '达到目标价'
                end
            end
            local pe
            for _, m in ipairs((a.valuation and a.valuation.metrics) or {}) do
                if m.key == (lv and lv.metric or 'pe_ttm') then pe = m.all and m.all.percentile end
            end
            local pos = a.watch and a.watch.position
            out[#out + 1] = {
                code = e.code, name = a.name,
                held = pos ~= nil or nil,
                cost = pos and util_num(pos.cost) or nil,
                profit_pct = pos and util_num(pos.profit_pct) or nil,
                date = last and last.date, close = close,
                change_pct = last and util_num(last.change_pct),
                percentile = pe,
                warnings = (function()
                    local n = 0
                    for _, c in ipairs(a.checks or {}) do if c.status == 'warn' then n = n + 1 end end
                    return n
                end)(),
                flags = util_json_array(flags),
            }
        end
    end
    table.sort(out, function(a, b)
        return (a.change_pct or -1e9) > (b.change_pct or -1e9)
    end)
    return out
end

-- COROUTINE-ONLY. opts = { offline = true, force = true, top = 5 }
function g_exports.review_build(opts)
    opts = opts or {}
    local top = opts.top or 5

    local indexes, regime_rows = {}, nil
    local regime_code = cfg_get('REVIEW_REGIME_INDEX', '000300')
    for _, code in ipairs(index_codes()) do
        local row, rows = index_row(code, { offline = opts.offline, force = opts.force })
        if row then
            indexes[#indexes + 1] = row
            if code == regime_code then regime_rows = rows end
        end
    end
    if not regime_rows and indexes[1] then
        -- The configured regime index is not in the list: use the first one
        -- that is, rather than silently having no regime at all.
        local _, rows = index_row(indexes[1].code, { offline = true })
        regime_rows = rows
        regime_code = indexes[1].code
    end
    local regime = review_regime(regime_rows or {})

    local sectors = review_sectors({ offline = opts.offline, force = opts.force })
    local structure = { note = sectors and nil or '没有板块行情' }
    if sectors then
        local rows = sectors.rows or {}
        -- Breadth at the BOARD level, not the stock level. Eastmoney's fine
        -- industry boards overlap — a chip maker sits in several of them — so
        -- adding up each board's own advancing and declining counts would
        -- count the same company more than once. How many boards rose is a
        -- number that is exactly what it says, and it costs no extra request.
        local up, down, flat = 0, 0, 0
        for _, r in ipairs(rows) do
            local c = util_num(r.change_pct)
            if c and c > 0 then up = up + 1
            elseif c and c < 0 then down = down + 1
            else flat = flat + 1 end
        end
        local leaders, laggards = {}, {}
        for i = 1, math.min(top, #rows) do leaders[#leaders + 1] = rows[i] end
        for i = #rows, math.max(1, #rows - top + 1), -1 do laggards[#laggards + 1] = rows[i] end
        structure = {
            fetched_at = sectors.fetched_at, source = sectors.source,
            sector_count = #rows,
            breadth = { up = up, down = down, flat = flat, total = #rows,
                        ratio = #rows > 0 and up / #rows * 100 or nil },
            leaders = util_json_array(leaders),
            laggards = util_json_array(laggards),
        }
    end

    local watch = watchlist_rows()
    return {
        generated_at = util_now_iso(),
        as_of = indexes[1] and indexes[1].date,
        market = {
            indexes = util_json_array(indexes),
            regime = regime, regime_index = regime_code,
            stance = review_stance(regime.state),
        },
        structure = structure,
        watchlist = { count = #watch, rows = util_json_array(watch) },
    }
end
