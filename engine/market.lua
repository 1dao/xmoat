-- engine/market.lua — the whole market in one snapshot, and screening it.
--
-- Exports: market_load, market_status, market_refresh, market_screen,
--          market_board, market_is_st, market_annual_period
--
-- The watchlist answers "how is what I own doing". This answers the other
-- question: which companies are worth looking at in the first place. It is a
-- different shape of problem — one row per company, every company — so it has
-- its own snapshot rather than the per-stock records.
--
-- WHAT A SNAPSHOT IS. Two market-wide tables joined by stock code: today's
-- valuation (PE, PB, PS, PCF, market capitalisation, price) and the latest
-- ANNUAL report's headline figures (ROE, revenue, profit, their growth, gross
-- margin, per-share cash flow). Annual rather than the most recent quarter on
-- purpose: every company has one for the same period, so a screen compares
-- like with like, and an interim ROE is not annualised.
--
-- WHAT IT CANNOT DO, and why:
--   * no dividend yield — there is no market-wide dividend table to join
--   * no valuation percentiles — those need each stock's own history, which is
--     5,500 fetches, not one; a screen narrows the field, and the per-stock
--     analysis then says whether a survivor is cheap against its own past
--   * no checklist — same reason: it reads balance sheets stock by stock
--
-- So this finds candidates. Judging one is still stock.refresh and the
-- analysis object.

local PAGE_VALUATION, PAGE_REPORTS = 2000, 500
-- The whole market fits: 5,500-odd rows, and a strategy scan legitimately
-- wants all of them. A browser does not, which is why the command that serves
-- one keeps its own smaller ceiling.
local MAX_ROWS = 6000

local doc = nil          -- the snapshot, nil until loaded
local refreshing = false

-- Which board a code belongs to, by its prefix. The exchange listing rules
-- differ enough (profitability requirements, investor thresholds) that
-- screening usually wants to include or exclude a whole board.
function g_exports.market_board(code)
    local p2 = tostring(code):sub(1, 2)
    if p2 == '60' then return 'main'        -- 沪市主板
    elseif p2 == '00' then return 'main'    -- 深市主板
    elseif p2 == '30' then return 'gem'     -- 创业板
    elseif p2 == '68' then return 'star'    -- 科创板
    elseif p2 == '43' or p2 == '83' or p2 == '87' or p2 == '88' or p2 == '92' then return 'bj'
    end
    return 'other'
end

-- ST and *ST mark a company in trouble; the name is where the market says so.
function g_exports.market_is_st(name)
    return tostring(name or ''):upper():find('ST', 1, true) ~= nil
end

-- The annual period a snapshot should use, given today. Annual reports are
-- published from January to April, so before May the previous year's may not
-- be complete yet — the caller checks the row count and falls back.
function g_exports.market_annual_period(today)
    local year, month = tonumber(today:sub(1, 4)), tonumber(today:sub(6, 7))
    return string.format('%04d-12-31', month >= 5 and year - 1 or year - 2)
end

function g_exports.market_load()
    local loaded, err = store_load('market')
    if err then return nil, err end
    if loaded ~= nil and type(loaded) ~= 'table' then return nil, 'market.json is not an object' end
    doc = loaded
    return true
end

-- What a client shows before any screening: whether there is a snapshot, how
-- old it is, and what it covers.
function g_exports.market_status()
    if not doc then
        return { ready = false, refreshing = refreshing,
                 hint = '还没有全市场快照，先刷新（约 15 次请求，半分钟左右）' }
    end
    return {
        ready = true, refreshing = refreshing,
        trade_date = doc.trade_date, report_period = doc.report_period,
        fetched_at = doc.fetched_at, total = #(doc.rows or {}),
        with_reports = doc.with_reports,
    }
end

-- COROUTINE-ONLY. Fetch both tables and join them. Returns the status, or nil
-- plus (error code, message).
function g_exports.market_refresh()
    if refreshing then return nil, 'conflict', '全市场快照正在刷新' end
    refreshing = true
    local ok, result, ecode, emsg = pcall(function()
        local date, derr = source_em_fetch_trade_date()
        if not date then return nil, 'upstream', '无法确定最新交易日：' .. tostring(derr) end

        local by_code, order = {}, {}
        local page, pages = 1, 1
        while page <= pages do
            local got, err = source_em_fetch_market_valuation(date, page, PAGE_VALUATION)
            if not got then return nil, 'upstream', '估值快照获取失败：' .. tostring(err) end
            pages = math.max(1, math.ceil((got.count or 0) / PAGE_VALUATION))
            for _, r in ipairs(got.rows) do
                if not by_code[r.code] then order[#order + 1] = r.code end
                by_code[r.code] = r
            end
            page = page + 1
            if page <= pages then sched_sleep(cfg_int('NET_PACE_MS', 200)) end
        end
        if #order == 0 then return nil, 'upstream', '估值快照为空' end

        -- The annual figures, joined onto whatever the valuation table listed.
        -- A code with no report (a recent listing) keeps its valuation row and
        -- simply fails any screen that asks about profitability.
        local period = market_annual_period(util_today())
        local matched = 0
        page, pages = 1, 1
        while page <= pages do
            sched_sleep(cfg_int('NET_PACE_MS', 200))
            local got, err = source_em_fetch_market_reports(period, page, PAGE_REPORTS)
            if not got then return nil, 'upstream', '业绩快照获取失败：' .. tostring(err) end
            pages = math.max(1, math.ceil((got.count or 0) / PAGE_REPORTS))
            for _, r in ipairs(got.rows) do
                local row = by_code[r.code]
                if row then
                    matched = matched + 1
                    for k, v in pairs(r) do
                        if k ~= 'code' and k ~= 'name' then row[k] = v end
                    end
                end
            end
            page = page + 1
        end

        local rows = {}
        for _, code in ipairs(order) do
            local row = by_code[code]
            row.board = market_board(code)
            row.st = market_is_st(row.name) or nil
            rows[#rows + 1] = row
        end
        doc = { version = 1, trade_date = date, report_period = period,
                fetched_at = util_now_iso(), with_reports = matched,
                rows = util_json_array(rows) }
        local sok, serr = store_save('market', doc)
        if not sok then return nil, 'internal', '保存失败：' .. tostring(serr) end
        cfg_log_system('market snapshot: %d stocks at %s, %d with %s figures',
            #rows, date, matched, period)
        return market_status()
    end)
    refreshing = false
    if not ok then
        cfg_log_error('market refresh raised: %s', tostring(result))
        return nil, 'internal', '刷新全市场快照时出错'
    end
    return result, ecode, emsg
end

-- ---------------------------------------------------------------------------
-- Screening
--
-- Pure over the loaded snapshot. Every filter is optional and every one is a
-- plain comparison: a row survives when it has the figure AND the figure
-- passes. A row missing the figure never survives a filter that asks about it
-- — silently keeping it would put companies with no reported ROE in the
-- results of a screen for high ROE.
-- ---------------------------------------------------------------------------

local SORTS = {
    roe = 'roe', pe_ttm = 'pe_ttm', pb = 'pb', ps_ttm = 'ps_ttm',
    market_cap = 'market_cap', revenue_yoy = 'revenue_yoy', np_parent_yoy = 'np_parent_yoy',
    gross_margin = 'gross_margin', revenue = 'revenue', np_parent = 'np_parent',
}
g_exports.market_sort_keys = SORTS

-- filters: roe_min, roe_max, pe_min, pe_max, pb_max, ps_max, cap_min, cap_max
--          (in 亿元), revenue_yoy_min, np_yoy_min, gross_margin_min,
--          ocf_to_eps_min, industry, keyword, boards (list), include_st,
--          sort, order ('asc'|'desc'), limit
-- Returns { snapshot, matched, rows } or nil plus (code, message).
function g_exports.market_screen(filters)
    if not doc then return nil, 'not_fetched', market_status().hint end
    filters = filters or {}
    local limit = math.min(filters.limit or 50, MAX_ROWS)

    local boards = nil
    if filters.boards and #filters.boards > 0 then
        boards = {}
        for _, b in ipairs(filters.boards) do boards[b] = true end
    end
    local industry = filters.industry and filters.industry:lower() or nil
    local keyword = filters.keyword and filters.keyword:lower() or nil

    -- A filter is a field, a bound and a direction; this is the whole of it.
    local tests = {
        { 'roe', filters.roe_min, 'min' }, { 'roe', filters.roe_max, 'max' },
        { 'pe_ttm', filters.pe_min, 'min' }, { 'pe_ttm', filters.pe_max, 'max' },
        { 'pb', filters.pb_max, 'max' }, { 'ps_ttm', filters.ps_max, 'max' },
        { 'market_cap', filters.cap_min and filters.cap_min * 1e8, 'min' },
        { 'market_cap', filters.cap_max and filters.cap_max * 1e8, 'max' },
        { 'revenue_yoy', filters.revenue_yoy_min, 'min' },
        { 'np_parent_yoy', filters.np_yoy_min, 'min' },
        { 'gross_margin', filters.gross_margin_min, 'min' },
    }

    local matched, kept = 0, {}
    for _, row in ipairs(doc.rows or {}) do
        local ok = true
        if boards and not boards[row.board] then ok = false end
        if ok and row.st and not filters.include_st then ok = false end
        if ok and industry and not tostring(row.industry or ''):lower():find(industry, 1, true) then ok = false end
        if ok and keyword then
            local hay = (tostring(row.name or '') .. ' ' .. row.code):lower()
            if not hay:find(keyword, 1, true) then ok = false end
        end
        -- A PE ceiling implies a profitable company: a loss-making stock has a
        -- negative PE, which would otherwise sail under any ceiling.
        if ok and filters.pe_max and not ((util_num(row.pe_ttm) or -1) > 0) then ok = false end
        if ok then
            for _, t in ipairs(tests) do
                local bound = t[2]
                if bound then
                    local v = util_num(row[t[1]])
                    if not v or (t[3] == 'min' and v < bound) or (t[3] == 'max' and v > bound) then
                        ok = false
                        break
                    end
                end
            end
        end
        -- Per-share operating cash flow over EPS: the market-wide stand-in for
        -- "is the profit real", since the cash flow statement itself is not in
        -- either table. Needs a positive EPS to mean anything.
        if ok and filters.ocf_to_eps_min then
            local eps, ocfps = util_num(row.eps), util_num(row.ocfps)
            if not eps or not ocfps or eps <= 0 or ocfps / eps < filters.ocf_to_eps_min then ok = false end
        end
        if ok then
            matched = matched + 1
            kept[#kept + 1] = row
        end
    end

    local key = SORTS[filters.sort or ''] or 'roe'
    local desc = (filters.order or 'desc') ~= 'asc'
    table.sort(kept, function(a, b)
        local x, y = util_num(a[key]), util_num(b[key])
        if x == nil and y == nil then return a.code < b.code end
        if x == nil then return false end        -- rows without the value sort last
        if y == nil then return true end
        if x == y then return a.code < b.code end
        if desc then return x > y end
        return x < y
    end)

    local rows = {}
    for i = 1, math.min(limit, #kept) do
        local r = kept[i]
        rows[i] = {
            code = r.code, name = r.name, industry = r.industry, board = r.board, st = r.st,
            close = r.close, market_cap = r.market_cap,
            pe_ttm = r.pe_ttm, pb = r.pb, ps_ttm = r.ps_ttm, pcf_ttm = r.pcf_ttm,
            roe = r.roe, revenue = r.revenue, revenue_yoy = r.revenue_yoy,
            np_parent = r.np_parent, np_parent_yoy = r.np_parent_yoy,
            gross_margin = r.gross_margin, eps = r.eps, ocfps = r.ocfps,
            ocf_to_eps = (util_num(r.eps) or 0) > 0 and util_num(r.ocfps)
                and util_round(r.ocfps / r.eps, 2) or nil,
            notice_date = r.notice_date,
        }
    end
    return { snapshot = market_status(), matched = matched, sort = key,
             order = desc and 'desc' or 'asc', rows = util_json_array(rows) }
end
