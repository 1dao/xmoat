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

-- old, new: stored records (engine/stock.lua). watch: the watchlist entry.
-- opts: { dcf = {...}, percentile_low = 10, percentile_high = 90 }
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
    local aopts = { dcf = opts.dcf }
    local old_a = analysis_build(old, watch, aopts)
    local new_a = analysis_build(new, watch, aopts)
    diff_band(old_a, new_a, out, new)
    diff_percentile(old_a, new_a, out, new, opts)
    diff_checks(old_a, new_a, out, new)
    return out
end
