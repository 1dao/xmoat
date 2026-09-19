-- engine/stock.lua — fetching a stock's source data and keeping it.
--
-- Exports: stock_refresh, stock_load, stock_analysis, stock_valuation_series,
--          stock_summary, stock_event_opts
--
-- The stored record is SOURCE data in xmoat's field names, never analysis:
--   { version, code, market, name, industry, org_type, fetched_at,
--     reports = {...}, valuation = {...}, balance = {...}, dividends = {...},
--     sources = {...} }
-- engine/analysis.lua derives everything else from it on read.
--
-- A refresh is incremental once a stock has been fetched: the newest few
-- reports and the last few months of daily valuation are asked for and merged
-- over what is kept. Reports are re-fetched rather than skipped because
-- companies restate them. On a phone this is the difference between a few KB
-- and 1.5 MB per stock per refresh.

local inflight = {}      -- code -> true while a refresh runs

local function merge_by(existing, fresh, key, newest_first)
    local map, out = {}, {}
    for _, r in ipairs(existing or {}) do map[r[key]] = r end
    for _, r in ipairs(fresh or {}) do map[r[key]] = r end
    for _, r in pairs(map) do out[#out + 1] = r end
    if newest_first then
        table.sort(out, function(a, b) return a[key] > b[key] end)
    else
        table.sort(out, function(a, b) return a[key] < b[key] end)
    end
    return out
end

-- The management review is only served for the latest report, so reviews are
-- accumulated here as they are seen: after a year of refreshes there are two
-- annual ones to compare. Capped, newest first; each text capped too, because
-- a runaway field should not grow a stock file without bound.
local MAX_REVIEWS, MAX_REVIEW_BYTES = 8, 30000

local function merge_business(old, fresh)
    local out = { scope = fresh.scope or old.scope }

    local reviews = {}
    for _, r in ipairs(type(old.reviews) == 'table' and old.reviews or {}) do reviews[#reviews + 1] = r end
    if fresh.review then
        local text = fresh.review.text
        if #text > MAX_REVIEW_BYTES then text = notify_truncate(text, MAX_REVIEW_BYTES) end
        local replaced = false
        for i, r in ipairs(reviews) do
            if r.period == fresh.review.period then reviews[i] = { period = r.period, text = text }; replaced = true end
        end
        if not replaced then reviews[#reviews + 1] = { period = fresh.review.period, text = text } end
    end
    table.sort(reviews, function(a, b) return a.period > b.period end)
    while #reviews > MAX_REVIEWS do table.remove(reviews) end
    out.reviews = util_json_array(reviews)

    local map = {}
    local function key(s) return s.period .. '|' .. s.kind .. '|' .. s.name end
    for _, s in ipairs(type(old.segments) == 'table' and old.segments or {}) do map[key(s)] = s end
    -- A period the fresh response covers replaces what was kept for it
    -- wholesale: a segment the company stopped reporting must not linger.
    local fresh_periods = {}
    for _, s in ipairs(fresh.segments or {}) do fresh_periods[s.period] = true end
    for k, s in pairs(map) do if fresh_periods[s.period] then map[k] = nil end end
    for _, s in ipairs(fresh.segments or {}) do map[key(s)] = s end
    local segments = {}
    for _, s in pairs(map) do segments[#segments + 1] = s end
    table.sort(segments, function(a, b)
        if a.period ~= b.period then return a.period > b.period end
        if a.kind ~= b.kind then return a.kind < b.kind end
        return (a.rank or 99) < (b.rank or 99)
    end)
    out.segments = util_json_array(segments)
    return out
end

-- Returns the stored record, nil when never fetched, or nil plus a message.
function g_exports.stock_load(code)
    return store_load('stock:' .. code)
end

local function pace()
    local ms = cfg_int('NET_PACE_MS', 200)
    if ms > 0 then sched_sleep(ms) end
end

-- The report periods whose balance sheets the checks need: the newest report
-- (goodwill, cash and debt are point-in-time) and the last three annual ones
-- (growth of receivables and inventory needs two in a row).
local function balance_periods(reports)
    local want, seen = {}, {}
    local function add(p) if p and not seen[p] then seen[p] = true; want[#want + 1] = p end end
    add(reports[1] and reports[1].period)
    local n = 0
    for _, r in ipairs(reports) do
        if r.period_type == 'FY' then add(r.period); n = n + 1 end
        if n >= 3 then break end
    end
    return want
end

-- COROUTINE-ONLY. Fetch and store. Returns the record, or nil plus
-- (error code, message). A second refresh of the same stock while one is
-- running waits for it instead of fetching twice.
function g_exports.stock_refresh(code)
    local sec, serr = source_em_security(code)
    if not sec then return nil, 'bad_request', serr end
    code = sec.code

    if inflight[code] then
        sched_wait_until(function() return not inflight[code] end, 120000)
        local rec = stock_load(code)
        if rec then return rec end
        return nil, 'upstream', '并发的刷新失败了'
    end
    inflight[code] = true
    local ok, rec, ecode, emsg = pcall(function()
        local old, lerr = stock_load(code)
        if lerr then cfg_log_warn('%s: stored data unreadable, refetching all: %s', code, lerr) end
        old = old or {}

        -- Reports. The first fetch takes the whole history (about 100 periods
        -- since 2000); later ones take the last three years, which covers any
        -- restatement worth caring about.
        local have_reports = type(old.reports) == 'table' and #old.reports >= 8
        local rep, err = source_em_fetch_reports(sec, have_reports and 12 or 200)
        if not rep then return nil, 'upstream', '财务指标获取失败：' .. tostring(err) end
        if #rep.reports == 0 and not have_reports then
            return nil, 'not_found', code .. ' 没有财务数据（代码不存在、未上市或已退市）'
        end
        pace()

        -- Daily valuation. Incremental when the stored series is recent
        -- enough that 120 trading days bridge the gap.
        local rows = type(old.valuation) == 'table' and old.valuation or {}
        local last = rows[#rows] and rows[#rows].date
        local gap = last and util_date_diff_days(last, util_today()) or nil
        local incremental = gap ~= nil and gap < 150
        local val, verr = source_em_fetch_valuation(sec, incremental and 120 or 5000)
        if not val then return nil, 'upstream', '估值数据获取失败：' .. tostring(verr) end
        pace()

        local divs, derr = source_em_fetch_dividends(sec)
        if not divs then return nil, 'upstream', '分红数据获取失败：' .. tostring(derr) end

        local reports = merge_by(have_reports and old.reports or {}, rep.reports, 'period', true)
        local org_type = rep.org_type or old.org_type or 'general'

        local balance = type(old.balance) == 'table' and old.balance or {}
        if org_type == 'general' then
            pace()
            local bal, berr = source_em_fetch_balance(sec, balance_periods(reports))
            if bal then
                balance = merge_by(balance, bal, 'period', true)
            else
                -- The checks that need it say 'na'; the rest of a refresh is
                -- still worth keeping.
                cfg_log_warn('%s: balance sheet fetch failed: %s', code, tostring(berr))
            end
        end

        -- Business breakdown and the management review. Not needed by any
        -- number above, so a failure keeps the previous copy and the refresh.
        pace()
        local business = type(old.business) == 'table' and old.business or {}
        local biz, zerr = source_em_fetch_business(sec)
        if biz then
            business = merge_business(business, biz)
        else
            cfg_log_warn('%s: business analysis fetch failed: %s', code, tostring(zerr))
        end

        local now = util_now_iso()
        local record = {
            version = 1,
            code = code, market = sec.market,
            name = rep.name or val.name or old.name,
            industry = val.industry or old.industry,
            org_type = org_type,
            fetched_at = now,
            reports = util_json_array(reports),
            valuation = util_json_array(merge_by(incremental and rows or {}, val.rows, 'date', false)),
            balance = util_json_array(balance),
            dividends = util_json_array(divs),
            business = business,
            sources = util_json_array({
                { name = '东方财富', dataset = 'RPT_F10_FINANCE_MAINFINADATA', item = '主要财务指标', fetched_at = now },
                { name = '东方财富', dataset = 'RPT_VALUEANALYSIS_DET', item = '每日估值', fetched_at = now },
                { name = '东方财富', dataset = 'RPT_SHAREBONUS_DET', item = '分红送配', fetched_at = now },
                { name = '东方财富', dataset = 'F10 zcfzbAjaxNew', item = '资产负债表', fetched_at = now },
                { name = '东方财富', dataset = 'F10 BusinessAnalysis', item = '主营构成与经营评述', fetched_at = now },
            }),
        }
        local sok, swerr = store_save('stock:' .. code, record)
        if not sok then return nil, 'internal', '保存失败：' .. tostring(swerr) end

        -- What changed, recorded here rather than by whoever asked for the
        -- refresh: see engine/alerts.lua for why every refresh must. Watched
        -- stocks only, and never allowed to fail the refresh that found it.
        local watch = watch_get(code)
        if watch then
            local eok, eerr = pcall(function()
                alerts_record(events_diff(old, record, watch, stock_event_opts()))
            end)
            if not eok then cfg_log_error('%s: event detection failed: %s', code, tostring(eerr)) end
        end
        cfg_log_info('%s %s refreshed: %d reports, %d valuation days, %d dividend events',
            code, tostring(record.name), #reports, #record.valuation, #divs)
        return record
    end)
    inflight[code] = nil
    if not ok then
        cfg_log_error('%s refresh raised: %s', code, tostring(rec))
        return nil, 'internal', '刷新时出错'
    end
    return rec, ecode, emsg
end

local function dcf_params()
    return {
        discount_rate = cfg_num('DCF_DISCOUNT_RATE', 10),
        terminal_growth = cfg_num('DCF_TERMINAL_GROWTH', 3),
        years = cfg_int('DCF_YEARS', 10),
    }
end

-- Options for events_diff, from config.
function g_exports.stock_event_opts()
    return {
        dcf = dcf_params(),
        percentile_low = cfg_num('ALERT_PERCENTILE_LOW', 10),
        percentile_high = cfg_num('ALERT_PERCENTILE_HIGH', 90),
    }
end

-- Returns the analysis, or nil plus (code, message).
function g_exports.stock_analysis(code)
    local rec, err = stock_load(code)
    if err then return nil, 'internal', err end
    if not rec then return nil, 'not_fetched', code .. ' 还没有获取过数据，先刷新' end
    return analysis_build(rec, watch_get(code), { dcf = dcf_params() })
end

-- The compact line a watchlist row shows. Built from the full analysis so the
-- two can never disagree.
function g_exports.stock_summary(code)
    local a = stock_analysis(code)
    if not a then return nil end
    local s = { name = a.name, industry = a.industry, template = a.template,
                fetched_at = a.fetched_at, latest_report = a.latest_report }
    local v = a.valuation
    if v then
        s.date, s.close, s.market_cap = v.date, v.close, v.market_cap
        s.dividend_yield = v.dividend and v.dividend.yield_ttm
        s.band = v.band
        for _, m in ipairs(v.metrics or {}) do
            if m.key == 'pe_ttm' or m.key == 'pb' then
                s[m.key] = { value = m.value,
                             percentile_all = m.all and m.all.percentile,
                             percentile_y5 = m.y5 and m.y5.percentile }
            end
        end
    end
    local warns = 0
    for _, c in ipairs(a.checks or {}) do
        if c.status == 'warn' then warns = warns + 1 end
    end
    s.warnings = warns
    return s
end

-- Daily history of one valuation metric for a chart, thinned to at most
-- `max_points` by keeping every k-th day and always the last. Returns
-- { metric, points = { {date, value|null}, ... }, from, to } or nil plus
-- (code, message).
function g_exports.stock_valuation_series(code, metric, years, max_points)
    local rec, err = stock_load(code)
    if err then return nil, 'internal', err end
    if not rec then return nil, 'not_fetched', code .. ' 还没有获取过数据，先刷新' end
    local rows = rec.valuation or {}
    local last = rows[#rows]
    if not last then
        return { metric = metric, points = util_json_array({}) }
    end
    local since = years and util_date_add_days(last.date, -math.floor(years * 365.25)) or nil
    local picked = {}
    for _, r in ipairs(rows) do
        if not since or r.date >= since then picked[#picked + 1] = r end
    end
    max_points = max_points or 800
    local step = math.max(1, math.ceil(#picked / max_points))
    local points = {}
    for i = 1, #picked, step do
        local r = picked[i]
        points[#points + 1] = { r.date, util_num(r[metric]) or util_null }
    end
    if #picked > 0 and (#picked - 1) % step ~= 0 then
        points[#points + 1] = { last.date, util_num(last[metric]) or util_null }
    end
    return { metric = metric, from = picked[1] and picked[1].date, to = last.date,
             points = util_json_array(points) }
end
