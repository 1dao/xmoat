-- engine/events.lua — what changed between two refreshes of one stock.
--
-- Exports: events_diff, events_id
--
-- A pure comparison of the stored record before a refresh with the record
-- after it. Both sides go through analysis_build with the SAME watchlist entry
-- and options, so the only differences are ones in the data: editing your band
-- between refreshes never reads as the price having crossed it.
--
-- Kinds, and why each is worth interrupting someone for:
--   report      a periodic report nobody had seen before
--   dividend    a cash dividend plan appeared, or moved on (approved, ex-date set)
--   band        the price left or re-entered the user's own fair-value band
--   percentile  the valuation dropped into its historical low zone or rose into
--               its high zone — crossing into the zone only, so a stock sitting
--               at the 8th percentile does not announce itself every day
--   check       a checklist item turned from pass to warn, or back
--   level       the price crossed into the buy range, through the stop, or up
--               to the target — HELD STOCKS ONLY (see below)
--   trend       the moving averages turned into bull or bear order — held
--               stocks only as well
--
-- WHY THOSE TWO NEED A POSITION. A price alert on something you merely watch
-- is noise: there is nothing to do about it and it arrives every time the
-- market moves. On something you own it is the opposite — a stop broken is the
-- one message worth a phone buzzing. So `watch.position` is the switch, and
-- with no position configured these two are never produced at all, not
-- produced and filtered later.
--
-- An event's id is derived from the stock and what happened (the report
-- period, the dividend plan's stage, the date a band was crossed), so recording
-- the same change twice — a re-fetch after restoring a backup — is a no-op.

local xutils = require('xutils')

local PERIOD_NAMES = { Q1 = '一季报', H1 = '中报', Q3 = '三季报', FY = '年报' }
local METRIC_LABEL = { pe_ttm = 'PE（TTM）', pb = 'PB', ps_ttm = 'PS（TTM）', pcf_ttm = 'PCF（TTM）' }

function g_exports.events_id(code, key)
    return xutils.sha1_hex(tostring(code) .. '|' .. tostring(key)):sub(1, 16)
end

local function event(rec, kind, key, fields)
    local e = { id = events_id(rec.code, kind .. '|' .. key), code = rec.code,
                name = rec.name, kind = kind }
    for k, v in pairs(fields) do e[k] = v end
    return e
end

local function report_name(r)
    return r.report_name or (tostring(r.period):sub(1, 4) .. (PERIOD_NAMES[r.period_type or ''] or ''))
end

local function signed_pct(v)
    if not util_num(v) then return nil end
    return string.format('%+.1f%%', v)
end

-- The figures a reader wants first when a report lands. Flow items in an
-- interim report are year-to-date, and the label says so.
local function report_detail(r, template)
    local cum = r.period_type ~= 'FY' and '累计' or ''
    local parts = {}
    local function add(s) if s then parts[#parts + 1] = s end end
    if util_num(r.revenue) then
        add(string.format('%s营收 %s%s', cum, report_money(r.revenue),
            r.revenue_yoy and ('（同比 ' .. signed_pct(r.revenue_yoy) .. '）') or ''))
    end
    if util_num(r.np_parent) then
        add(string.format('%s归母净利润 %s%s', cum, report_money(r.np_parent),
            r.np_parent_yoy and ('（同比 ' .. signed_pct(r.np_parent_yoy) .. '）') or ''))
    end
    if template == 'general' and util_num(r.np_deducted) then
        add(string.format('扣非净利润 %s%s', report_money(r.np_deducted),
            r.np_deducted_yoy and ('（同比 ' .. signed_pct(r.np_deducted_yoy) .. '）') or ''))
    end
    if util_num(r.roe) then add(string.format('ROE（加权）%.2f%%', r.roe)) end
    if template == 'bank' and util_num(r.npl_ratio) then
        add(string.format('不良贷款率 %.2f%%', r.npl_ratio))
    end
    return table.concat(parts, '；')
end

local function diff_reports(old, new, out)
    local seen = {}
    for _, r in ipairs(old.reports or {}) do seen[r.period] = true end
    local fresh = {}
    for _, r in ipairs(new.reports or {}) do
        if not seen[r.period] then fresh[#fresh + 1] = r end
    end
    table.sort(fresh, function(a, b) return a.period < b.period end)
    for _, r in ipairs(fresh) do
        out[#out + 1] = event(new, 'report', r.period, {
            title = '发布' .. report_name(r),
            detail = report_detail(r, new.org_type or 'general'),
            period = r.period, date = r.notice_date,
        })
    end
end

local function diff_dividends(old, new, out)
    local seen = {}
    for _, d in ipairs(old.dividends or {}) do
        seen[tostring(d.period) .. '|' .. tostring(d.progress)] = true
    end
    local fresh = {}
    for _, d in ipairs(new.dividends or {}) do
        if dividend_counts(d) and not seen[tostring(d.period) .. '|' .. tostring(d.progress)] then
            fresh[#fresh + 1] = d
        end
    end
    table.sort(fresh, function(a, b) return a.period < b.period end)
    for _, d in ipairs(fresh) do
        local ptype = ({ ['03-31'] = 'Q1', ['06-30'] = 'H1', ['09-30'] = 'Q3', ['12-31'] = 'FY' })[d.period:sub(6)]
        local what = d.period:sub(1, 4) .. (PERIOD_NAMES[ptype or ''] or '')
        local detail = string.format('%s，每股派现 %.4g 元（含税）', d.plan or '分红方案', d.dps)
        if d.ex_date then detail = detail .. '，除息日 ' .. d.ex_date end
        out[#out + 1] = event(new, 'dividend', d.period .. '|' .. tostring(d.progress), {
            title = string.format('%s分红：%s', what, d.progress or '新方案'),
            detail = detail, period = d.period, date = d.notice_date,
        })
    end
end

local BAND_TITLE = { below = '%s 低于你的区间', inside = '%s 回到你的区间内', above = '%s 高于你的区间' }

local function diff_band(old_a, new_a, out, rec)
    local ob = old_a.valuation and old_a.valuation.band
    local nb = new_a.valuation and new_a.valuation.band
    if not ob or not nb or ob.metric ~= nb.metric or ob.position == nb.position then return end
    local label = METRIC_LABEL[nb.metric] or nb.metric
    local range = string.format('%s – %s',
        nb.low and string.format('%.2f', nb.low) or '不限',
        nb.high and string.format('%.2f', nb.high) or '不限')
    out[#out + 1] = event(rec, 'band', nb.metric .. '|' .. nb.position .. '|' .. tostring(new_a.valuation.date), {
        title = string.format(BAND_TITLE[nb.position], label),
        detail = string.format('当前 %.2f，你的区间 %s（上次 %.2f，%s）', nb.value, range, ob.value,
            tostring(old_a.valuation.date)),
        date = new_a.valuation.date,
    })
end

local function all_percentile(a, key)
    for _, m in ipairs(a.valuation and a.valuation.metrics or {}) do
        if m.key == key then return m.all and m.all.percentile, m end
    end
    return nil
end

local function diff_percentile(old_a, new_a, out, rec, opts)
    -- A bank's earnings swing with provisioning; its book is what the market
    -- prices, so the zone alert watches PB there.
    local key = new_a.template == 'bank' and 'pb' or 'pe_ttm'
    local op = all_percentile(old_a, key)
    local np, m = all_percentile(new_a, key)
    if not op or not np then return end
    local low, high = opts.percentile_low or 10, opts.percentile_high or 90
    local zone
    if op >= low and np < low then zone = 'low'
    elseif op <= high and np > high then zone = 'high' end
    if not zone then return end
    local label = METRIC_LABEL[key]
    out[#out + 1] = event(rec, 'percentile', key .. '|' .. zone .. '|' .. tostring(new_a.valuation.date), {
        title = zone == 'low'
            and string.format('%s 进入历史低位（低于 %d%% 分位）', label, low)
            or string.format('%s 进入历史高位（高于 %d%% 分位）', label, high),
        detail = string.format('当前 %.2f，处于 %s 以来 %.0f%% 分位（上次 %.0f%%），历史中位数 %.2f',
            m.value, m.all.from, np, op, m.all.median),
        date = new_a.valuation.date,
    })
end

-- Which price zone a close sits in. The stop is checked first: when the price
-- is under both the buy range and the stop, the thing worth saying is the one
-- about getting out, not the one about buying more.
local function level_zone(a)
    local lv, v = a.levels, a.valuation
    if not lv or lv.note or not v then return nil end
    local close = util_num(v.close)
    if not close then return nil end
    if lv.stop and util_num(lv.stop.price) and close <= lv.stop.price then return 'stop' end
    if lv.target and util_num(lv.target.price) and close >= lv.target.price then return 'target' end
    if lv.buy and util_num(lv.buy.high) and close <= lv.buy.high then return 'buy' end
    return 'none'
end

local ZONE_TITLE = { buy = '跌进买入区间', stop = '跌破止损价', target = '涨到目标价' }

local function diff_levels(old_a, new_a, out, rec)
    local was, now = level_zone(old_a), level_zone(new_a)
    -- Crossing IN only, as with the band: sitting in the zone is not news.
    if not was or not now or was == now or now == 'none' then return end
    local lv = new_a.levels
    local date = new_a.valuation and new_a.valuation.date
    local close = new_a.valuation and util_num(new_a.valuation.close)
    local detail
    if now == 'buy' then
        detail = string.format('收盘 %.2f，买入%s（%s）', close,
            lv.buy.low and string.format('区间 %.2f – %.2f', lv.buy.low, lv.buy.high)
                or string.format('价 %.2f 以下', lv.buy.high),
            lv.buy.basis or '')
    elseif now == 'stop' then
        detail = string.format('收盘 %.2f，止损价 %.2f（%s）', close, lv.stop.price, lv.stop.basis or '')
    else
        detail = string.format('收盘 %.2f，目标价 %.2f（%s）', close, lv.target.price, lv.target.basis or '')
    end
    local pos = new_a.watch and new_a.watch.position
    if pos and util_num(pos.profit_pct) then
        detail = detail .. string.format('；持仓成本 %.2f，浮动盈亏 %+.1f%%', pos.cost, pos.profit_pct)
    end
    out[#out + 1] = event(rec, 'level', now .. '|' .. tostring(date), {
        title = ZONE_TITLE[now], detail = detail, date = date,
        status = now == 'stop' and 'warn' or nil,
    })
end

local TREND_TITLE = { bull = '均线转为多头排列', bear = '均线转为空头排列' }

local function diff_trend(old_a, new_a, out, rec)
    local ot = old_a.technical
    local nt = new_a.technical
    if not ot or not nt or ot.note or nt.note then return end
    local was = ot.trend and ot.trend.alignment
    local now = nt.trend and nt.trend.alignment
    if not was or not now or was == now or not TREND_TITLE[now] then return end
    out[#out + 1] = event(rec, 'trend', now .. '|' .. tostring(nt.as_of), {
        title = TREND_TITLE[now],
        detail = string.format('%s 收盘 %.2f，MA5 %.2f / MA10 %.2f / MA20 %.2f / MA60 %.2f',
            nt.as_of, nt.close, nt.ma['5'] or 0, nt.ma['10'] or 0, nt.ma['20'] or 0, nt.ma['60'] or 0),
        date = nt.as_of,
        status = now == 'bear' and 'warn' or nil,
    })
end

local function diff_checks(old_a, new_a, out, rec)
    local before = {}
    for _, c in ipairs(old_a.checks or {}) do before[c.key] = c.status end
    for _, c in ipairs(new_a.checks or {}) do
        local was = before[c.key]
        local turned = (was == 'pass' and c.status == 'warn') or (was == 'warn' and c.status == 'pass')
        if turned then
            local as_of = c.period or (new_a.latest_report and new_a.latest_report.period) or ''
            out[#out + 1] = event(rec, 'check', c.key .. '|' .. c.status .. '|' .. as_of, {
                title = (c.status == 'warn' and '新提示：' or '提示解除：') .. c.title,
                detail = c.detail, status = c.status, period = c.period,
            })
        end
    end
end

-- The last day the record has a price for, which is the day its analysis
-- speaks about.
local function as_of(rec)
    local rows = type(rec.valuation) == 'table' and rec.valuation or {}
    return rows[#rows] and rows[#rows].date or nil
end

-- The day the old record's price alerts were judged on: the last bar it had.
-- Usually its valuation day, but not when that refresh could not get prices —
-- then it judged on older bars, and cutting at the valuation day now would
-- hand it bars it never saw. A crossing on the day the prices failed would be
-- counted as already known, and never announced. Records written before the
-- field existed fall back to the valuation day.
local function judged_on(rec)
    if type(rec.quotes_as_of) == 'string' then return rec.quotes_as_of end
    return as_of(rec)
end

-- The bars up to `date`. The old side of the comparison has to see the market
-- as it was on its own day: judging yesterday's close against today's moving
-- average would invent crossings that never happened.
local function quotes_upto(quotes, date)
    if type(quotes) ~= 'table' or type(quotes.rows) ~= 'table' or not date then return nil end
    local rows = {}
    for _, r in ipairs(quotes.rows) do
        if r.date <= date then rows[#rows + 1] = r end
    end
    if #rows == 0 then return nil end
    return { rows = rows, last_date = rows[#rows].date, fetched_at = quotes.fetched_at,
             code = quotes.code, name = quotes.name }
end

-- old, new: stored records (engine/stock.lua). watch: the watchlist entry.
-- opts: { dcf = {...}, levels = {...}, quotes = the cached bars,
--         percentile_low = 10, percentile_high = 90 }
-- Returns a list of events, oldest-first within each kind. A first fetch (no
-- old record, or one without reports) has nothing to compare and returns none.
function g_exports.events_diff(old, new, watch, opts)
    opts = opts or {}
    local out = {}
    if type(old) ~= 'table' or type(old.reports) ~= 'table' or #old.reports == 0 then
        return out
    end
    diff_reports(old, new, out)
    diff_dividends(old, new, out)
    local old_a = analysis_build(old, watch, { dcf = opts.dcf, levels = opts.levels,
                                               quotes = quotes_upto(opts.quotes, judged_on(old)) })
    local new_a = analysis_build(new, watch, { dcf = opts.dcf, levels = opts.levels,
                                               quotes = opts.quotes })
    diff_band(old_a, new_a, out, new)
    diff_percentile(old_a, new_a, out, new, opts)
    diff_checks(old_a, new_a, out, new)
    -- Price alerts are for what is owned. Nothing above depends on this, so a
    -- watchlist entry with no position produces exactly what it did before.
    if watch and type(watch.position) == 'table' then
        diff_levels(old_a, new_a, out, new)
        diff_trend(old_a, new_a, out, new)
    end
    return out
end
