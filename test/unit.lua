-- test/unit.lua — offline checks for the engine and the HTTP host.
--
--   Run: bin/xnet.exe test/unit.lua        (bin/xnet on Linux)
--   Exit code 0 = every check passed.
--
-- No network. Data-source parsing runs against responses recorded from the
-- real endpoints (test/fixtures/em_*.json); the analysis runs against small
-- hand-built reports whose right answers can be worked out on paper, and are,
-- in the comments next to each check. A refresh goes through the real command
-- path with the transport replaced by those fixtures.
--
-- Runs twice, like main.lua: the first pass loads the loader and hands this
-- file back to it with the root _G, which cannot be recovered from inside a
-- module environment.

local boot, root_globals = ...
if type(boot) ~= 'table' then
    boot = dofile('engine/boot.lua')
    return boot.run_script('test/unit.lua', boot, _G)
end

for _, path in ipairs(boot.run_script('engine/manifest.lua')) do boot.load_script(path) end
boot.load_script('host/http.lua')
boot.load_script('host/web.lua')
boot.load_script('host/wecom.lua')

xthread.set_log_level(6)   -- WARN and above; the checks are the output

local fails, total = 0, 0
local function out(s) io.write(s); io.flush() end
local function check(name, cond, detail)
    total = total + 1
    if cond then out('PASS ' .. name .. '\n')
    else fails = fails + 1; out('FAIL ' .. name .. ' :: ' .. tostring(detail) .. '\n') end
end
local function eq(name, got, want)
    check(name, got == want, string.format('got %s want %s', tostring(got), tostring(want)))
end
local function near(name, got, want, tol)
    check(name, type(got) == 'number' and math.abs(got - want) <= (tol or 1e-9),
        string.format('got %s want %s', tostring(got), tostring(want)))
end
local function section(title) out('\n-- ' .. title .. '\n') end

local function fixture(name)
    local text = assert(util_file_read('test/fixtures/' .. name), 'missing fixture ' .. name)
    return assert(util_json_decode(text))
end

local PTYPE = { ['03-31'] = 'Q1', ['06-30'] = 'H1', ['09-30'] = 'Q3', ['12-31'] = 'FY' }
local function R(period, fields)
    fields.period, fields.period_type = period, PTYPE[period:sub(6)]
    return fields
end

-- ─────────────────────────────────────────────────────────────────────────────
local function test_modules()
    section('module isolation')
    check('g_exports is the one registry in root _G', rawget(root_globals, 'g_exports') == g_exports)
    check('an export is not copied onto root _G', rawget(root_globals, 'fin_ttm') == nil)
    local ok = pcall(function() g_exports.fin_ttm = function() end end)
    check('an export cannot be replaced', not ok)
end

local function test_json()
    section('JSON')
    local text = util_json_encode({ a = util_json_array({}), b = util_null, c = { 1, util_null, 3 } })
    check('a marked empty list encodes as []', text and text:find('"a":[]', 1, true), text)
    check('util_null encodes as null', text and text:find('"b":null', 1, true), text)
    check('a hole marked with util_null stays an array', text and text:find('[1,null,3]', 1, true), text)
    eq('an unmarked empty table is still an object', util_json_encode({ x = {} }), '{"x":{}}')
    local doc = util_json_decode('{"v":null}')
    eq('null decodes to util_null', doc.v, util_null)
    eq('util_num refuses util_null', util_num(util_null), nil)
    eq('util_num refuses NaN', util_num(0 / 0), nil)
    eq('util_num refuses a numeric string', util_num('12'), nil)
    eq('util_json_decode never raises on garbage', (util_json_decode('{nope')), nil)
end

local function test_security()
    section('security codes')
    eq('600519 is Shanghai', source_em_security('600519').secucode, '600519.SH')
    eq('sz000001 is Shenzhen', source_em_security('sz000001').f10, 'SZ000001')
    eq('300750.SZ keeps its code', source_em_security('300750.SZ').code, '300750')
    eq('830799 is Beijing', source_em_security('830799').market, 'BJ')
    eq('a fund code is refused', (source_em_security('510300')), nil)
    eq('a wrong exchange suffix is refused', (source_em_security('600519.SZ')), nil)
    eq('five digits are refused', (source_em_security('60051')), nil)
    eq('a path is refused', (source_em_security('../x')), nil)
end

local function test_parsers()
    section('Eastmoney parsers (recorded responses)')
    local rep = source_em_parse_reports(fixture('em_reports_600519.json'))
    eq('reports: three periods', #rep.reports, 3)
    eq('reports: newest first', rep.reports[1].period, '2026-06-30')
    eq('reports: H1 recognised', rep.reports[1].period_type, 'H1')
    eq('reports: annual recognised', rep.reports[3].period_type, 'FY')
    eq('reports: notice date kept', rep.reports[1].notice_date, '2026-08-15')
    eq('reports: weighted ROE mapped', rep.reports[1].roe, 16.75)
    eq('reports: name', rep.name, '贵州茅台')
    eq('reports: 通用 is general', rep.org_type, 'general')
    eq('reports: a null source field is absent', rep.reports[1].npl_ratio, nil)

    local bank = source_em_parse_reports(fixture('em_reports_000001.json'))
    eq('bank: 银行 is bank', bank.org_type, 'bank')
    eq('bank: NPL ratio mapped', bank.reports[1].npl_ratio, 1.05)
    eq('bank: provision coverage mapped', bank.reports[1].provision_coverage, 219.58)

    local val = source_em_parse_valuation(fixture('em_valuation_600519.json'))
    eq('valuation: two rows', #val.rows, 2)
    check('valuation: oldest first', val.rows[1].date < val.rows[2].date)
    check('valuation: PE is a number', type(val.rows[2].pe_ttm) == 'number')
    check('valuation: industry kept', type(val.industry) == 'string')

    local divs = source_em_parse_dividends(fixture('em_dividends_600519.json'))
    local final
    for _, d in ipairs(divs) do if d.period == '2025-12-31' then final = d end end
    near('dividends: per ten shares divided by ten', final and final.dps, 28.02423, 1e-9)
    eq('dividends: ex-date kept', final and final.ex_date, '2026-06-26')
    eq('dividends: a plan with no amount has no dps', divs[1].dps, nil)

    local bal = source_em_parse_balance(fixture('em_balance_600519.json'))
    eq('balance: two periods', #bal, 2)
    near('balance: cash mapped', bal[1].cash, 53518798979.08, 0.01)
    eq('balance: a null goodwill is absent', bal[1].goodwill, nil)

    local empty = fixture('em_empty.json')
    eq('empty result: no reports, no error', #source_em_parse_reports(empty).reports, 0)
    eq('empty result: no valuation rows', #source_em_parse_valuation(empty).rows, 0)
    eq('empty result: no dividends', #source_em_parse_dividends(empty), 0)
    eq('a wrong shape is an error', (source_em_parse_reports({ foo = 1 })), nil)
end

-- The general company used by the fin, quality and checks sections. Newest first.
local GENERAL = {
    R('2025-06-30', { np_parent = 50, revenue = 500, debt_ratio = 80 }),
    R('2024-12-31', { np_parent = 100, np_deducted = 50, revenue = 1000, revenue_yoy = 10,
                      gross_margin = 30, ocf_to_np = 0.5, roe = 12, eps = 1.0 }),
    R('2024-06-30', { np_parent = 40, revenue = 450 }),
    R('2023-12-31', { np_parent = 90, np_deducted = 85, revenue = 909, revenue_yoy = 5,
                      gross_margin = 40, ocf_to_np = 0.4, roe = 11, eps = 0.9 }),
    R('2022-12-31', { np_parent = 80, revenue = 865, gross_margin = 41, ocf_to_np = 0.6,
                      roe = 10, eps = 0.8 }),
}
local GENERAL_BALANCE = {
    { period = '2025-06-30', cash = 200, total_assets = 1000, short_loan = 150, long_loan = 50,
      goodwill = 150, equity_parent = 300 },
    { period = '2024-12-31', receivables = 200, inventory = 100 },
    { period = '2023-12-31', receivables = 100, inventory = 95 },
}

local function test_fin()
    section('report series')
    -- H1 2025 + FY 2024 - H1 2024 = 50 + 100 - 40
    local ttm, basis = fin_ttm(GENERAL, 'np_parent')
    eq('TTM from a half-year report', ttm, 110)
    eq('TTM basis names the arithmetic', fin_ttm_basis(basis),
        '2025-06-30 累计 + 2024-12-31 年报 − 2024-06-30 累计')
    eq('TTM of an annual report is the annual figure', fin_ttm({ GENERAL[2] }, 'np_parent'), 100)
    eq('TTM without the prior same period is nil', (fin_ttm({ GENERAL[1], GENERAL[2] }, 'np_parent')), nil)

    local annual = fin_annual(GENERAL)
    eq('annual: only full years', #annual, 3)
    eq('annual: oldest first', annual[1].period, '2022-12-31')
    eq('annual: capped', #fin_annual(GENERAL, 2), 2)

    near('CAGR 100 -> 161.051 over 5 years is 10%', fin_cagr(100, 161.051, 5), 10, 1e-9)
    eq('CAGR from a loss is undefined', fin_cagr(-10, 100, 3), nil)
    eq('median of an odd list', fin_median({ 3, 1, 2 }), 2)
    eq('median of an even list', fin_median({ 4, 1, 3, 2 }), 2.5)
    eq('mean skips nulls', fin_mean({ 1, util_null, 3 }), 2)
    eq('min of nothing is nil', fin_min({ util_null }), nil)
end

local function test_valuation()
    section('valuation')
    -- 300 days: PE 1..299, then 150.5 today. 150 values lie below 150.5 and
    -- one — today's own — equals it, counting half: (150 + 0.5) / 300.
    local rows, d = {}, '2020-01-01'
    for i = 1, 300 do
        rows[i] = { date = d, close = 10, pe_ttm = i < 300 and i or 150.5, market_cap = 1000 }
        d = util_date_add_days(d, 1)
    end
    local p = valuation_percentile(rows, 'pe_ttm')
    near('percentile of the middle value', p and p.percentile, 150.5 / 300 * 100, 1e-9)
    eq('percentile window size', p and p.n, 300)
    eq('percentile window start', p and p.from, '2020-01-01')

    local tie = {}
    for i = 1, 300 do tie[i] = { date = rows[i].date, close = 10, pe_ttm = 7 } end
    near('a value equal to every point is the 50th', valuation_percentile(tie, 'pe_ttm').percentile, 50)

    local since = rows[101].date
    local short, why = valuation_percentile(rows, 'pe_ttm', since)
    check('fewer than 240 points gives no percentile', short == nil and why:find('200', 1, true), why)

    rows[300].pe_ttm = -5
    eq('a negative current PE gives no percentile', (valuation_percentile(rows, 'pe_ttm')), nil)
    rows[300].pe_ttm = 150.5

    -- Independent statement of the model, to solve against.
    local function value(e, g, r, tg, n)
        local v, x, disc = 0, e, 1
        for _ = 1, n do x = x * (1 + g); disc = disc * (1 + r); v = v + x / disc end
        return v + x * (1 + tg) / (r - tg) / disc
    end
    local params = { discount_rate = 10, terminal_growth = 3, years = 10 }
    local dcf = valuation_reverse_dcf(100, value(100, 0.05, 0.10, 0.03, 10), params)
    near('reverse DCF recovers 5% growth', dcf and dcf.implied_growth, 5, 1e-4)
    eq('reverse DCF: a price below every growth is bounded', valuation_reverse_dcf(100, 1, params).bound, 'below')
    eq('reverse DCF: a price above every growth is bounded', valuation_reverse_dcf(100, 1e15, params).bound, 'above')
    eq('reverse DCF: a loss has no answer', (valuation_reverse_dcf(-1, 1000, params)), nil)
    eq('reverse DCF: discount rate must exceed terminal growth',
        (valuation_reverse_dcf(100, 1000, { discount_rate = 3, terminal_growth = 3 })), nil)

    local band = valuation_band(rows, { metric = 'pe_ttm', low = 10, high = 20 })
    eq('band: 150.5 is above 10-20', band.position, 'above')
    eq('band: open-ended low bound', valuation_band(rows, { metric = 'pe_ttm', low = 200 }).position, 'below')
    eq('band: no bounds is no band', valuation_band(rows, { metric = 'pe_ttm' }), nil)
end

local function test_dividends()
    section('dividends')
    local events = {
        { period = '2025-06-30', progress = '实施分配', dps = 1.0, ex_date = '2025-09-01' },
        { period = '2024-12-31', progress = '实施分配', dps = 2.0, ex_date = '2025-06-01' },
        { period = '2024-06-30', progress = '实施分配', dps = 0.5, ex_date = '2024-09-01' },
        { period = '2023-12-31', progress = '停止实施', dps = 9.0 },
        { period = '2022-12-31', progress = '实施分配', dps = 1.0, ex_date = '2023-06-01' },
    }
    -- Window (2024-12-31, 2025-12-31]: the 2025-09-01 and 2025-06-01 payments.
    local ttm = dividend_ttm(events, '2025-12-31', 50)
    eq('TTM dividend counts ex-dates inside the year', ttm.dps, 3.0)
    near('TTM yield', ttm.yield, 6)
    eq('TTM lists what it counted', #ttm.events, 2)

    local years = dividend_years(events, GENERAL)
    eq('latest fiscal year from the annual reports', years.latest_fy, 2024)
    eq('interim and final add up for 2024', years.years[1].dps, 2.5)
    near('payout ratio against that year\'s EPS', years.years[1].payout_ratio, 250)
    eq('a cancelled plan breaks the streak', years.consecutive_years, 1)
    eq('the cancelled year shows nothing paid', years.years[2].dps, 0)
end

local function status_of(list)
    local m = {}
    for _, c in ipairs(list) do m[c.key] = c.status end
    return m
end

local function test_checks()
    section('checklist: general')
    local s = status_of(checks_build(GENERAL, GENERAL_BALANCE, 'general'))
    eq('profitable year passes', s.profitable, 'pass')
    eq('OCF / profit averaging 0.5 warns', s.ocf_quality, 'warn')                 -- (0.6+0.4+0.5)/3
    eq('deducted profit at 50% warns', s.recurring_profit, 'warn')              -- 50 / 100
    eq('a 10pt gross margin fall warns', s.gross_margin_stable, 'warn')         -- 40 -> 30
    eq('receivables doubling on 10% revenue growth warns', s.receivables, 'warn') -- +100% vs +10%
    eq('inventory growing slower than revenue passes', s.inventory, 'pass')     -- +5.3% vs +10%
    eq('goodwill at half of equity warns', s.goodwill, 'warn')                  -- 150 / 300
    eq('20% cash and 20% debt warns', s.cash_and_debt, 'warn')
    eq('cash covering short debt 1.33x passes', s.short_debt_cover, 'pass')     -- 200 / 150
    eq('an 80% debt ratio warns', s.debt_ratio, 'warn')

    local bare = status_of(checks_build({ GENERAL[2] }, {}, 'general'))
    eq('missing history is na, not pass', bare.ocf_quality, 'na')
    eq('missing balance sheet is na', bare.goodwill, 'na')

    section('checklist: bank')
    local bank = {
        R('2025-12-31', { np_parent = 10, npl_ratio = 1.8, provision_coverage = 140, core_t1 = 9 }),
        R('2024-12-31', { np_parent = 9, npl_ratio = 1.6 }),
    }
    local b = status_of(checks_build(bank, {}, 'bank'))
    eq('NPL 1.8% passes', b.npl_ratio, 'pass')
    eq('NPL up 0.2pt warns', b.npl_trend, 'warn')
    eq('coverage 140% warns', b.provision_coverage, 'warn')
    eq('core tier 1 at 9% passes', b.core_t1, 'pass')
    eq('banks skip the gross margin check', b.gross_margin_stable, nil)
    -- An insurer runs its own checks, not a bank's, on the same reports.
    local as_insurer = status_of(checks_build(bank, {}, 'insurance'))
    eq('the shared profit check still runs', as_insurer.profitable, 'pass')
    eq('but not the bank ratios', as_insurer.npl_ratio, nil)
    eq('and its own are na without the data', as_insurer.solvency, 'na')
    eq('a type with no template gets the profit check only', #checks_build(bank, {}, 'other'), 1)
end

local function test_quality()
    section('quality')
    local q = quality_build(GENERAL, 'general')
    eq('periods are the annual reports', #q.periods, 3)
    local by = {}
    for _, s in ipairs(q.series) do by[s.key] = s end
    eq('ROE series oldest first', by.roe.values[1], 10)
    eq('a field never reported is null, not a hole', by.roic.values[2], util_null)
    local sm = {}
    for _, s in ipairs(q.summary) do sm[s.key] = s end
    near('ROE mean', sm.roe_avg_5y.value, 11)
    near('profit CAGR over the 2 years there are', sm.np_cagr.value, (100 / 80) ^ 0.5 * 100 - 100, 1e-9)
    eq('CAGR label says how many years', sm.np_cagr.label, '归母净利润增速（2 年复合）')
    eq('TTM in the summary', sm.np_parent_ttm.value, 110)
    eq('an unknown template falls back to general', quality_build(GENERAL, 'nonsense').template, 'general')
end

local function test_analysis()
    section('analysis object')
    local rows, d = {}, '2020-01-01'
    for i = 1, 260 do
        rows[i] = { date = d, close = 20, pe_ttm = 10 + i / 100, pb = 2, market_cap = 2000 }
        d = util_date_add_days(d, 1)
    end
    local data = { code = '600000', market = 'SH', name = '测试', org_type = 'general',
                   reports = GENERAL, balance = GENERAL_BALANCE, valuation = rows, dividends = {} }
    local a = analysis_build(data, { band = { metric = 'pe_ttm', low = 5, high = 8 } },
        { dcf = { discount_rate = 10, terminal_growth = 3, years = 10 } })
    eq('schema is stamped', a.schema, analysis_schema)
    eq('band is evaluated', a.valuation.band.position, 'above')
    check('reverse DCF ran on TTM profit', a.valuation.reverse_dcf.implied_growth ~= nil,
        a.valuation.reverse_dcf.error)
    eq('TTM basis is shown with the DCF', a.valuation.reverse_dcf.earnings_basis,
        '2025-06-30 累计 + 2024-12-31 年报 − 2024-06-30 累计')
    local text, err = util_json_encode(a)
    check('the analysis encodes as JSON', text ~= nil, err)
    check('no dividend events encode as []', text and text:find('"events":[]', 1, true), text)
    eq('the store\'s band table is not rounded in place', data.reports[1].np_parent, 50)

    local md = report_markdown(a)
    check('Markdown has the title', md:find('# 测试（600000.SH）', 1, true), md:sub(1, 80))
    check('Markdown has the checklist', md:find('## 检查清单', 1, true))
end

-- A transport that answers from the recorded fixtures.
local function fixture_transport(url)
    local function body(name)
        return { status = 200, headers = {}, body = util_file_read('test/fixtures/' .. name) }
    end
    if url:find('RPT_F10_FINANCE_MAINFINADATA', 1, true) then
        if url:find('600519.SH', 1, true) then return body('em_reports_600519.json') end
        if url:find('000001.SZ', 1, true) then return body('em_reports_000001.json') end
        return body('em_empty.json')
    elseif url:find('RPT_VALUEANALYSIS_DET', 1, true) then
        if url:find('600519', 1, true) then return body('em_valuation_600519.json') end
        return body('em_empty.json')
    elseif url:find('RPT_SHAREBONUS_DET', 1, true) then
        if url:find('600519', 1, true) then return body('em_dividends_600519.json') end
        return body('em_empty.json')
    elseif url:find('zcfzbAjaxNew', 1, true) then
        return body('em_balance_600519.json')
    elseif url:find('/qt/clist/get', 1, true) then
        return body('em_sectors.json')
    elseif url:find('/qt/stock/kline/get', 1, true) then
        if url:find('secid=1.600519', 1, true) then return body('em_kline_600519.json') end
        -- The regime index, so the trading calendar has days to read. The bars
        -- are a stock's; only their dates matter here.
        if url:find('secid=1.000300', 1, true) then return body('em_kline_600519.json') end
        return body('em_kline_empty.json')
    elseif url:find('BusinessAnalysis', 1, true) then
        if url:find('600519', 1, true) then return body('em_business_600519.json') end
        return { status = 200, headers = {}, body = '{"zyfw":[],"zygcfx":[],"jyps":[]}' }
    end
    return nil, 'unexpected URL in test: ' .. url
end

local function test_commands()
    section('commands')
    eq('an unknown command is not_found', api_call('nope.nope').error.code, 'not_found')
    eq('a missing parameter is bad_request', api_call('stock.get', {}).error.code, 'bad_request')
    eq('a non-numeric number is bad_request',
        api_call('stock.valuation', { code = '600519', years = 'abc' }).error.code, 'bad_request')
    eq('a value outside the enum is bad_request',
        api_call('stock.valuation', { code = '600519', metric = 'eps' }).error.code, 'bad_request')
    eq('a stock never fetched is not_fetched', api_call('stock.get', { code = '600519' }).error.code,
        'not_fetched')

    eq('an inverted band is refused', api_call('watchlist.add',
        { code = '600519', band = { metric = 'pe_ttm', low = 20, high = 10 } }).error.code, 'bad_request')
    eq('an unknown band metric is refused', api_call('watchlist.add',
        { code = '600519', band = { metric = 'eps', low = 1 } }).error.code, 'bad_request')
    local added = api_call('watchlist.add', { code = 'SH600519', note = '观察' })
    eq('add normalises the code', added.ok and added.data.code, '600519')
    eq('adding twice conflicts', api_call('watchlist.add', { code = '600519' }).error.code, 'conflict')
    local upd = api_call('watchlist.update', { code = '600519', band = { low = 15 } })
    eq('a band without metric defaults to PE', upd.ok and upd.data.band.metric, 'pe_ttm')
    local cleared = api_call('watchlist.update', { code = '600519', band = util_null })
    eq('null clears the band', cleared.ok and cleared.data.band, nil)
    eq('the note survives', cleared.ok and cleared.data.note, '观察')
    eq('a band bound given as text is refused, not guessed', api_call('watchlist.update',
        { code = '600519', band = { low = '15' } }).error.code, 'bad_request')

    __net_set_transport(fixture_transport)
    local r = api_call('stock.refresh', { code = '600519' })
    check('refresh succeeds on recorded data', r.ok, r.error and r.error.message)
    if r.ok then
        eq('refresh: name', r.data.name, '贵州茅台')
        eq('refresh: latest report', r.data.latest_report.period, '2026-06-30')
        check('refresh: two valuation days are too few for a percentile',
            r.data.valuation.metrics[1].all == nil and r.data.valuation.metrics[1].all_note ~= nil)
        check('refresh: TTM needs H1 2025, which the fixture lacks',
            r.data.valuation.reverse_dcf.error ~= nil)
        eq('refresh: the latest annual report was profitable', status_of(r.data.checks).profitable, 'pass')
    end
    eq('the stored copy reads back', api_call('stock.get', { code = '600519' }).ok, true)
    local list = api_call('watchlist.list')
    eq('the watchlist summary has the name', list.ok and list.data[1].summary.name, '贵州茅台')

    local bank = api_call('stock.refresh', { code = '000001' })
    eq('a bank gets the bank template', bank.ok and bank.data.template, 'bank')
    eq('a code with no data is not_found', api_call('stock.refresh', { code = '609999' }).error.code,
        'not_found')
    __net_set_transport(nil)

    eq('remove', api_call('watchlist.remove', { code = '600519' }).ok, true)
    eq('removing twice is not_found', api_call('watchlist.remove', { code = '600519' }).error.code,
        'not_found')
end

local function test_http()
    section('HTTP host')
    local function req(method, path, body, query)
        local resp = http_dispatch({ method = method, path = path, headers = {},
                                     query = query or {}, body = body or '' }, {})
        return resp, util_json_decode(resp.body or '')
    end
    local resp, doc = req('GET', '/api/v1/system/info')
    eq('GET system/info is 200', resp.status, 200)
    eq('the envelope says ok', doc and doc.ok, true)
    resp = req('POST', '/api/v1/watchlist', '{not json')
    eq('a body that is not JSON is 400', resp.status, 400)
    resp, doc = req('POST', '/api/v1/watchlist', '{"code":"000001"}')
    eq('POST watchlist is 200', resp.status, 200)
    resp, doc = req('PATCH', '/api/v1/watchlist/000001', '{"code":"600519","note":"x"}')
    eq('the path parameter wins over the body', doc and doc.data and doc.data.code, '000001')
    resp = req('GET', '/api/v1/stocks/000001')
    eq('a stored stock is 200', resp.status, 200)
    resp = req('GET', '/api/v1/stocks/123')
    eq('a bad code is 400', resp.status, 400)
    resp = req('GET', '/api/v1/stocks/600519/valuation', nil, { years = '1' })
    eq('query parameters are coerced', resp.status, 200)
    resp, doc = req('GET', '/api/v1/nope')
    eq('an unknown API path is a JSON 404', doc and doc.ok, false)
    resp = req('OPTIONS', '/api/v1/watchlist')
    eq('preflight is answered', resp.status, 204)
    resp = req('DELETE', '/api/v1/watchlist/000001')
    eq('DELETE watchlist entry', resp.status, 200)

    eq('a missing web root answers 503', __web_serve('test/no-such-dir', '/').status, 503)
    if util_file_exists('web/index.html') then
        local page = __web_serve('web', '/')
        eq('the page is served', page.status, 200)
        check('the page carries the asset digest', not page.body:find('__ASSET_VERSION__', 1, true))
        eq('an unknown route is not claimed', __web_serve('web', '/../xmoat.cfg'), nil)
    end
end

-- ── Phase 2: events, alerts, push channels, schedule ─────────────────────────

-- Two refreshes of one company. Between them: an interim report lands, a
-- dividend plan is proposed, PE falls from mid-history to below every past day
-- (out of the 15-30 band and into the low zone), and the debt ratio crosses 70%.
local function event_pair()
    local function reports(with_h1)
        local list = {}
        if with_h1 then
            list[#list + 1] = R('2025-06-30', { np_parent = 50, np_parent_yoy = 25, revenue = 500,
                                               revenue_yoy = 11.1, roe = 6.2, debt_ratio = 80,
                                               report_name = '2025中报', notice_date = '2025-08-20' })
        end
        list[#list + 1] = R('2024-12-31', { np_parent = 100, np_deducted = 95, revenue = 1000, revenue_yoy = 10,
                                            gross_margin = 30, ocf_to_np = 1.1, roe = 12, eps = 1, debt_ratio = 50 })
        list[#list + 1] = R('2024-06-30', { np_parent = 40, revenue = 450 })
        list[#list + 1] = R('2023-12-31', { np_parent = 90, np_deducted = 85, revenue = 909, revenue_yoy = 5,
                                            gross_margin = 31, ocf_to_np = 1.0, roe = 11, eps = 0.9 })
        return list
    end
    local function rows(last_pe)
        local out, d = {}, '2020-01-01'
        for i = 1, 300 do
            out[i] = { date = d, close = 10, pe_ttm = i < 300 and (10 + i / 10) or last_pe, market_cap = 1000 }
            d = util_date_add_days(d, 1)
        end
        return out
    end
    local base = { code = '600000', market = 'SH', name = '测试银行股份', org_type = 'general',
                   balance = {}, sources = {} }
    local old, new = util_copy(base), util_copy(base)
    old.reports, old.valuation, old.dividends = reports(false), rows(25), {}
    new.reports, new.valuation = reports(true), rows(10.05)
    new.dividends = { { period = '2024-12-31', progress = '董事会预案', plan = '10派5元(含税)', dps = 0.5 } }
    local watch = { code = '600000', band = { metric = 'pe_ttm', low = 15, high = 30 } }
    return old, new, watch
end

local function kinds_of(events)
    local m = {}
    for _, e in ipairs(events) do m[e.kind] = e end
    return m
end

local function test_events()
    section('events')
    local old, new, watch = event_pair()
    local opts = { dcf = { discount_rate = 10, terminal_growth = 3, years = 10 },
                   percentile_low = 10, percentile_high = 90 }
    local evs = events_diff(old, new, watch, opts)
    local k = kinds_of(evs)
    eq('a new interim report is an event', k.report and k.report.period, '2025-06-30')
    eq('the report title names it', k.report and k.report.title, '发布2025中报')
    check('the report detail says interim figures are cumulative',
        k.report and k.report.detail:find('累计营收', 1, true), k.report and k.report.detail)
    eq('a proposed dividend is an event', k.dividend and k.dividend.title, '2024年报分红：董事会预案')
    eq('leaving the band downwards is an event', k.band and k.band.title, 'PE（TTM） 低于你的区间')
    check('entering the low zone is an event', k.percentile and k.percentile.title:find('历史低位', 1, true),
        k.percentile and k.percentile.title)
    eq('a check turning to warn is an event', k.check and k.check.title, '新提示：资产负债率不高')
    eq('five kinds, one each', #evs, 5)

    local again = events_diff(old, new, watch, opts)
    eq('ids are stable across runs', again[1].id, evs[1].id)
    eq('a first fetch has nothing to compare', #events_diff(nil, new, watch, opts), 0)
    eq('an unchanged record has no events', #events_diff(new, new, watch, opts), 0)
    local moved = { code = '600000', band = { metric = 'pe_ttm', low = 5, high = 8 } }
    eq('editing the band between refreshes is not a crossing', #events_diff(new, new, moved, opts), 0)
    local staying_low = events_diff(new, new, watch, { percentile_low = 50 })
    eq('sitting inside the low zone does not repeat', #staying_low, 0)
    return evs
end

local function test_position_events()
    section('position, and the alerts it unlocks')
    local old, new, watch = event_pair()
    local opts = { dcf = { discount_rate = 10, terminal_growth = 3, years = 10 },
                   percentile_low = 10, percentile_high = 90 }

    -- Watching, not holding: the price alerts are not produced at all.
    for _, e in ipairs(events_diff(old, new, watch, opts)) do
        check('watching without holding produces no price alert', e.kind ~= 'level' and e.kind ~= 'trend', e.kind)
    end

    -- The same two refreshes, with a position configured. PE fell from 25 to
    -- 10.05 while the close stayed at 10, so the price that would put PE at
    -- the band low of 15 is now above the close: the stock has entered its own
    -- buy range.
    local held = util_copy(watch)
    held.position = { cost = 12, shares = 100 }
    local k = kinds_of(events_diff(old, new, held, opts))
    eq('holding it turns the level alert on', k.level and k.level.title, '跌进买入区间')
    check('and the alert carries the cost and what it is worth',
        k.level and k.level.detail:find('浮动盈亏 -16.7%', 1, true), k.level and k.level.detail)
    eq('staying in the zone does not repeat', #events_diff(new, new, held, opts), 0)

    -- The position is in the analysis object too, with the arithmetic done.
    local a = analysis_build(new, held, opts)
    near('profit is measured from the cost the user typed', a.watch.position.profit_pct, -16.6667, 0.01)
    near('and the holding is worth what it closed at', a.watch.position.market_value, 1000, 1e-6)
    near('so the loss is in yuan as well', a.watch.position.profit, -200, 1e-6)

    -- 均线转为多头排列: flat for 200 days, then rising. The old record's last
    -- day is before the rise, the new one's well after it, and each side sees
    -- only the bars up to its own day.
    local px, dates = {}, {}
    local d = '2024-01-01'
    for i = 1, 320 do
        local close = i <= 200 and 100 or (100 + (i - 200))
        dates[i] = d
        px[i] = { date = d, close = close, high = close, low = close, volume = 100,
                  amount = close * 100 * 100, turnover = 1 }
        d = util_date_add_days(d, 1)
    end
    local function record_to(last_index)
        local rec = util_copy(new)
        local rows = {}
        for i = 1, last_index do
            rows[i] = { date = dates[i], close = px[i].close, pe_ttm = 20, market_cap = 1000 }
        end
        rec.valuation = rows
        return rec
    end
    local before, after = record_to(199), record_to(320)
    local topts = util_copy(opts)
    topts.quotes = { rows = px, last_date = dates[320] }
    local tk = kinds_of(events_diff(before, after, held, topts))
    eq('the averages falling into bull order is an alert', tk.trend and tk.trend.title, '均线转为多头排列')
    check('only for a holder', kinds_of(events_diff(before, after, watch, topts)).trend == nil)
    eq('and not again while they stay that way', kinds_of(events_diff(after, after, held, topts)).trend, nil)

    -- Validation, through the command path.
    eq('add the stock', api_call('watchlist.add', { code = '600519' }).ok, true)
    eq('a negative size is refused', api_call('watchlist.update',
        { code = '600519', position = { shares = -1 } }).error.code, 'bad_request')
    eq('a cost of zero is refused', api_call('watchlist.update',
        { code = '600519', position = { cost = 0 } }).error.code, 'bad_request')
    eq('a cost given as text is refused, not guessed', api_call('watchlist.update',
        { code = '600519', position = { cost = '12' } }).error.code, 'bad_request')
    local set = api_call('watchlist.update', { code = '600519', position = { cost = 1200, shares = 100 } })
    eq('a position is stored', set.ok and set.data.position.cost, 1200)
    check('with the day it was set', set.ok and set.data.position.since ~= nil)
    local marked = api_call('watchlist.update', { code = '600519', position = {} })
    check('an empty object still means "I hold this"', marked.ok and marked.data.position ~= nil)
    eq('and the earlier numbers survive it', marked.ok and marked.data.position.cost, 1200)
    local cleared = api_call('watchlist.update', { code = '600519', position = util_null })
    eq('null is selling out of it', cleared.ok and cleared.data.position, nil)
    api_call('watchlist.remove', { code = '600519' })
end

local function test_notify()
    section('push channels')
    local long = string.rep('护城河', 60)                       -- 540 bytes
    local cut = notify_truncate(long, 100)
    check('truncation respects the byte limit', #cut <= 100, #cut)
    check('truncation leaves valid UTF-8', utf8.len(cut) ~= nil, cut)
    eq('a short string is untouched', notify_truncate('abc', 100), 'abc')
    eq('URL encoding of base64', notify_urlencode('a+b/c='), 'a%2Bb%2Fc%3D')

    local msg = { title = 't', markdown = 'md', text = 'tx', events = {} }
    local ding = notify_build('dingtalk', { url = 'https://oapi.dingtalk.com/robot/send?access_token=x',
                                            secret = 'SECtest123' }, msg, 1700000000)
    eq('DingTalk signs with its reference vector', ding.url,
        'https://oapi.dingtalk.com/robot/send?access_token=x&timestamp=1700000000000' ..
        '&sign=w3RMHXzixTMdzr8OHJUmVLS4IoPJVdu%2BUt1LE48MePE%3D')
    eq('DingTalk sends Markdown', ding.body.msgtype, 'markdown')
    local feishu = notify_build('feishu', { url = 'https://open.feishu.cn/x', secret = 'SECtest123' }, msg, 1700000000)
    eq('Feishu signs with its reference vector', feishu.body.sign, 'eHRRCyLH7Z4IJQSJlfwertHZThRUYVu2hTUH02xPXYU=')
    eq('Feishu timestamp is in seconds', feishu.body.timestamp, '1700000000')
    eq('Feishu without a secret is unsigned', notify_build('feishu', { url = 'u' }, msg, 1).body.sign, nil)
    local tg = notify_build('telegram', { api = 'https://api.telegram.org', token = '12:AB', chat_id = '7' }, msg, 1)
    eq('Telegram URL carries the token', tg.url, 'https://api.telegram.org/bot12:AB/sendMessage')
    eq('Telegram sends plain text', tg.body.parse_mode, nil)
    eq('WeCom sends Markdown', notify_build('wecom', { url = 'u' }, msg, 1).body.markdown.content, 'md')
    local app = notify_build('wecom_app', { api = 'https://qyapi.test', access_token = 'tk/1',
                                            corp_id = 'c', secret = 's', agent_id = 1000002 }, msg, 1)
    eq('the WeCom app carries its token in the query', app.url,
        'https://qyapi.test/cgi-bin/message/send?access_token=tk%2F1')
    eq('the WeCom app names its application', app.body.agentid, 1000002)
    eq('the WeCom app defaults to everyone it can see', app.body.touser, '@all')
    -- Text, not Markdown: Markdown from an app is invisible in the WeChat plugin.
    eq('the WeCom app sends plain text', app.body.text.content, 'tx')
    eq('the webhook carries a bearer', notify_build('webhook', { url = 'u', bearer = 'k' }, msg, 1).headers.Authorization,
        'Bearer k')

    eq('WeCom errcode 0 is delivered', (notify_judge('wecom', { status = 200 }, { errcode = 0 })), true)
    eq('WeCom errcode with HTTP 200 is refused', (notify_judge('wecom', { status = 200 }, { errcode = 93000, errmsg = 'x' })), false)
    eq('Feishu code 0 is delivered', (notify_judge('feishu', { status = 200 }, { code = 0 })), true)
    local okt, why = notify_judge('telegram', { status = 400 }, { ok = false, description = 'chat not found' })
    check('Telegram gives its own reason', okt == false and why == 'chat not found', why)
    eq('a webhook 204 is delivered', (notify_judge('webhook', { status = 204 }, nil)), true)

    -- The app channel's two-request dance: a token, then the message — and a
    -- fresh token plus a resend when the one we held is no longer accepted.
    __notify_clear_tokens()
    local calls = {}
    __net_set_transport(function(url)
        calls[#calls + 1] = url
        if url:find('gettoken', 1, true) then
            return { status = 200, body = string.format(
                '{"errcode":0,"errmsg":"ok","access_token":"T%d","expires_in":7200}', #calls) }
        elseif url:find('access_token=T1', 1, true) then
            return { status = 200, body = '{"errcode":42001,"errmsg":"access_token expired"}' }
        end
        return { status = 200, body = '{"errcode":0,"errmsg":"ok","invaliduser":""}' }
    end)
    __notify_set_channels({ { kind = 'wecom_app', name = '企业微信应用', conf = {
        api = 'https://qyapi.test', corp_id = 'c', secret = 's', agent_id = 1000002, touser = '@all' } } })
    local res = notify_send(msg)
    eq('a refused token is replaced and the message resent', res[1].ok, true)
    eq('which took token, send, token, send', #calls, 4)
    calls = {}
    eq('the next message reuses the token', (notify_send(msg))[1].ok, true)
    eq('so it is one request, not two', #calls, 1)

    __notify_clear_tokens()
    __net_set_transport(function()
        return { status = 200, body = '{"errcode":40001,"errmsg":"invalid credential"}' }
    end)
    local bad = notify_send(msg)
    check('a secret WeCom refuses is reported as such', bad[1].ok == false and
        tostring(bad[1].error):find('40001', 1, true), bad[1].error)
    __net_set_transport(nil)
    __notify_set_channels(nil)
    __notify_clear_tokens()
end

-- The callback that the console demands before it will let an address be
-- declared trusted. The vector is Tencent's own (the WXBizMsgCrypt sample):
-- their key, their signature, their ciphertext, so a mistake here is ours.
local function test_wecom_callback()
    section('WeCom callback')
    local xutils = require('xutils')
    local conf = {
        token = 'QDG6eK',
        key = xutils.base64_decode('jWmYm7qr5nMoAUwZRjGtBxmz3KA1tkAj3ykkR6q2B2C='),
        receiveid = 'wx5823bf96d3bd56c7',
    }
    local TS, NONCE = '1409659589', '263014780'
    local ECHO = 'P9nAzCzyDtyTWESHep1vC5X9xho/qYX3Zpb4yKa9SKld1DsH3Iyt3tP3' ..
                 'zNdtp+4RPcs8TgAE7OaBO+FZXvnaqQ=='
    local SIG = '5c45ff5e21c57e6ad56bac8758b79b1d9ac89fd3'
    local PLAIN = '1616140317555161061'

    eq('the 43-character key decodes to 32 bytes', #conf.key, 32)
    eq('the signature matches the vector', wxcrypt_signature(conf.token, TS, NONCE, ECHO), SIG)
    eq('the echostr decrypts to its plaintext', (wxcrypt_open(conf, SIG, TS, NONCE, ECHO)), PLAIN)

    eq('a tampered signature is refused', (wxcrypt_open(conf, SIG:gsub('^5c', '5d'), TS, NONCE, ECHO)), nil)
    eq('another nonce is refused', (wxcrypt_open(conf, SIG, TS, '9', ECHO)), nil)
    eq('a missing parameter is refused', (wxcrypt_open(conf, SIG, TS, NONCE, nil)), nil)
    -- Decrypts, but was addressed to another company: the receiveid is the one
    -- part of the plaintext we are entitled to check, so it is checked.
    local other = { token = conf.token, key = conf.key, receiveid = 'wxOTHERCOMPANY' }
    local msg, why = wxcrypt_open(other, SIG, TS, NONCE, ECHO)
    check('a receiveid from another company is refused', msg == nil and why == 'receiveid is another company', why)

    -- Through wxcrypt_config, so the install path a host takes is the one
    -- tested — and so a machine with a callback of its own configured does not
    -- register the route with its keys and fail every check below.
    __wxcrypt_set_config(false)
    eq('without keys there is no route', wecom_install(), false)
    __wxcrypt_set_config(conf)
    check('the route installs once the keys are there', wecom_install())
    __wxcrypt_set_config(nil)

    local path = cfg_get('WECOM_CALLBACK_PATH', '/wecom/callback')
    local function req(method, query, body)
        return http_dispatch({ method = method, path = path, headers = {},
                               query = query, body = body or '' }, {})
    end
    local ok = req('GET', { msg_signature = SIG, timestamp = TS, nonce = NONCE, echostr = ECHO })
    eq('the URL check answers 200', ok.status, 200)
    -- Exactly the plaintext: WeCom compares the whole body, newline included.
    eq('the URL check echoes the plaintext alone', ok.body, PLAIN)
    eq('a forged URL check is 403',
        req('GET', { msg_signature = SIG, timestamp = TS, nonce = '9', echostr = ECHO }).status, 403)

    local xml = '<xml><ToUserName><![CDATA[wx5823bf96d3bd56c7]]></ToUserName>' ..
                '<Encrypt><![CDATA[' .. ECHO .. ']]></Encrypt></xml>'
    local ev = req('POST', { msg_signature = SIG, timestamp = TS, nonce = NONCE }, xml)
    eq('an event is accepted', ev.status, 200)
    -- Nothing is done with it, and an empty body is WeCom's "no reply".
    eq('an event is answered with nothing', ev.body, '')
    eq('a body without Encrypt is 403',
        req('POST', { msg_signature = SIG, timestamp = TS, nonce = NONCE }, '<xml/>').status, 403)
end

local function test_alerts(evs)
    section('alert log and flush')
    for _, e in ipairs(evs) do e.pushed, e.seq, e.created_at = nil, nil, nil end
    eq('record adds new events', alerts_record(evs), 5)
    eq('recording the same events again adds nothing', alerts_record(evs), 0)
    local listed = alerts_list({ code = '600000' })
    eq('list filters by stock', #listed, 5)
    check('newest first', listed[1].seq > listed[#listed].seq)
    eq('after_seq returns only newer', #alerts_list({ after_seq = listed[2].seq }), 1)

    __notify_set_channels({})
    local r = alerts_flush()
    eq('no channel: pending events are skipped, not kept', r.skipped, true)
    eq('nothing left pending', #alerts_pending(), 0)

    local sent = {}
    __net_set_transport(function(url, opts)
        sent[#sent + 1] = { url = url, body = util_json_decode(opts.body) }
        if url:find('wecom', 1, true) then
            return { status = 200, body = '{"errcode":0,"errmsg":"ok"}' }
        end
        return { status = 400, body = '{"ok":false,"description":"chat not found"}' }
    end)
    __notify_set_channels({
        { kind = 'wecom', name = '企业微信', conf = { url = 'https://wecom.test/send?key=k' } },
        { kind = 'telegram', name = 'Telegram', conf = { api = 'https://tg.test', token = 't', chat_id = 'c' } },
    })
    alerts_record({ { id = 'unit-a', code = '600000', name = '测试银行股份', kind = 'report',
                      title = '发布2025三季报', detail = '累计营收 1 亿' } })
    r = alerts_flush()
    eq('one delivered channel is enough', r.sent, 1)
    eq('both channels were tried', #sent, 2)
    check('the digest names the stock', sent[1].body.markdown.content:find('测试银行股份', 1, true),
        sent[1].body.markdown.content)
    eq('each channel reports its own result', r.channels[2].error, 'chat not found')
    eq('a delivered event is marked', alerts_list({ limit = 1 })[1].pushed, true)

    __net_set_transport(function() return { status = 200, body = '{"errcode":45009,"errmsg":"limit"}' } end)
    __notify_set_channels({ { kind = 'wecom', name = '企业微信', conf = { url = 'u' } } })
    alerts_record({ { id = 'unit-b', code = '600000', name = '测试银行股份', kind = 'check',
                      status = 'warn', title = '新提示', detail = '' } })
    alerts_flush()
    eq('a refused push stays pending', alerts_list({ limit = 1 })[1].pushed, false)
    alerts_flush(); alerts_flush()
    eq('three refusals give up', alerts_list({ limit = 1 })[1].pushed, 'failed')

    -- The market review, in the same message rather than a second one.
    local review = {
        as_of = '2026-09-18',
        market = {
            indexes = { { code = '000300', name = '沪深300', close = 4507.39, change_pct = 1.06 } },
            regime = { state = 'range' }, stance = { position = '50–80%' },
        },
        structure = { sector_count = 3, breadth = { up = 2, down = 1, flat = 0, total = 3 },
                      leaders = { { name = '半导体设备', change_pct = 4.83 } }, laggards = {} },
        watchlist = { count = 2, rows = {
            { code = '600000', name = '测试银行股份', change_pct = -1.2, flags = { '跌破止损价' } },
            { code = '600519', name = '别的股票', change_pct = 0.5, flags = {} } } },
    }
    local brief = report_review_brief(review)
    check('the brief names the index and where it closed', brief:find('沪深300 4507.39', 1, true), brief)
    check('and only the held stock that touched a level',
        brief:find('跌破止损价', 1, true) and not brief:find('别的股票', 1, true), brief)
    -- A WeCom application message is 2,000 bytes for everything, digest included.
    check('short enough to push', #brief < 800, #brief)

    sent = {}
    __net_set_transport(function(url, opts)
        sent[#sent + 1] = { url = url, body = util_json_decode(opts.body) }
        return { status = 200, body = '{"errcode":0,"errmsg":"ok"}' }
    end)
    alerts_record({ { id = 'unit-c', code = '600000', name = '测试银行股份', kind = 'level',
                      title = '跌破止损价', detail = '收盘 9.00，止损价 9.50' } })
    local withr = alerts_flush({ review = review })
    eq('the event went out', withr.sent, 1)
    eq('and the review went with it', withr.review, true)
    check('one message, not two', #sent == 1, #sent)
    local body = sent[1].body.markdown.content
    check('the digest has the alert', body:find('跌破止损价', 1, true), body)
    check('and the review at the end', body:find('收盘复盘 2026-09-18', 1, true), body)

    sent = {}
    local quiet = alerts_flush({ review = review })
    eq('nothing pending: the review alone is not pushed by default', #sent, 0)
    eq('and nothing is claimed to have been sent', quiet.sent, 0)

    local ritual = alerts_flush({ review = review, review_alone = true })
    eq('unless asked for every trading day', #sent, 1)
    eq('then it is the whole message', sent[1].body.markdown.content, brief)
    eq('with nothing counted as an alert', ritual.sent, 0)
    eq('but the review reported', ritual.review, true)

    __net_set_transport(nil)
    __notify_set_channels(nil)
end

local function test_schedule()
    section('schedule')
    local times = schedule_parse_times('17:30, 8:05')
    eq('times are normalised and sorted', times and table.concat(times, ','), '08:05,17:30')
    eq('an impossible time is refused', (schedule_parse_times('25:00')), nil)
    local wd = schedule_parse_weekdays('1-5')
    check('1-5 is Monday to Friday', wd[1] and wd[5] and not wd[6] and not wd[7])
    eq('weekday 0 is refused', (schedule_parse_weekdays('0')), nil)

    -- 1700000000 is 2023-11-14 22:13:20 UTC: Wednesday 06:13 in Beijing.
    local c = schedule_clock(8, 1700000000)
    eq('the clock is in the schedule timezone', c.date .. ' ' .. c.hm, '2023-11-15 06:13')
    eq('Wednesday is 3', c.iso_wday, 3)

    local t = { '17:30' }
    local function clock(date, hm, wday) return { date = date, hm = hm, iso_wday = wday } end
    eq('not due before the time', #schedule_due(clock('2023-11-15', '17:29', 3), t, wd, {}), 0)
    eq('due at the time', #schedule_due(clock('2023-11-15', '17:30', 3), t, wd, {}), 1)
    eq('not due twice in a day', #schedule_due(clock('2023-11-15', '20:00', 3), t, wd,
        { ['17:30'] = '2023-11-15' }), 0)
    eq('not due on Saturday', #schedule_due(clock('2023-11-18', '18:00', 6), t, wd, {}), 0)

    eq('next: later today', schedule_next(clock('2023-11-15', '06:13', 3), t, wd, {}), '2023-11-15 17:30')
    eq('next: a missed slot runs now', schedule_next(clock('2023-11-15', '18:00', 3), t, wd, {}),
        '2023-11-15 18:00')
    eq('next: after today\'s run, tomorrow', schedule_next(clock('2023-11-15', '18:00', 3), t, wd,
        { ['17:30'] = '2023-11-15' }), '2023-11-16 17:30')
    eq('next: Friday evening skips the weekend', schedule_next(clock('2023-11-17', '18:00', 5), t, wd,
        { ['17:30'] = '2023-11-17' }), '2023-11-20 17:30')
end

-- A refresh through the command path records what changed.
local function test_refresh_events()
    section('refresh records events')
    __notify_set_channels({})
    eq('watch the stock', api_call('watchlist.add', { code = '600519' }).ok, true)
    __net_set_transport(fixture_transport)
    eq('first refresh', api_call('stock.refresh', { code = '600519' }).ok, true)
    eq('a first fetch records no event', #alerts_list({ code = '600519' }), 0)

    -- The same responses, plus a third-quarter report nobody has seen.
    local doc = fixture('em_reports_600519.json')
    local q3 = util_copy(doc.result.data[1])
    q3.REPORT_DATE, q3.REPORT_DATE_NAME, q3.NOTICE_DATE = '2026-09-30 00:00:00', '2026三季报', '2026-10-28 00:00:00'
    table.insert(doc.result.data, 1, q3)
    local body = util_json_encode(doc)
    __net_set_transport(function(url, opts)
        if url:find('RPT_F10_FINANCE_MAINFINADATA', 1, true) then return { status = 200, body = body } end
        return fixture_transport(url, opts)
    end)
    eq('second refresh', api_call('stock.refresh', { code = '600519' }).ok, true)
    local got = alerts_list({ code = '600519' })
    eq('the new report was recorded', got[1] and got[1].title, '发布2026三季报')
    local listed = api_call('alerts.list', { code = '600519', limit = '5' })
    eq('alerts.list returns it', listed.ok and listed.data[1].kind, 'report')
    eq('alerts.list refuses a silly limit', api_call('alerts.list', { limit = 0 }).error.code, 'bad_request')
    eq('notify.test without channels says how to add one', api_call('notify.test').error.code, 'bad_request')
    eq('schedule.status works without a running schedule', api_call('schedule.status').data.enabled, false)
    __net_set_transport(nil)
    __notify_set_channels(nil)
    api_call('watchlist.remove', { code = '600519' })
end

-- ── Phase 5: screening the whole market ─────────────────────────────────────

local function market_page(rows, count, page_size)
    local data = {}
    for _, r in ipairs(rows) do data[#data + 1] = r end
    return { result = { data = data, count = count or #rows,
                        pages = math.ceil((count or #rows) / (page_size or 2000)) } }
end

local function test_tech()
    section('technical')
    -- Closes 1..10, so the 5-day average of the last bar is (6+7+8+9+10)/5.
    local rows = {}
    for i = 1, 10 do rows[i] = { date = string.format('2026-01-%02d', i), close = i,
                                 high = i, low = i, volume = 100, amount = i * 100 * 100 } end
    eq('a moving average is the mean of the last n closes', tech_ma(rows, 5), 8)
    eq('and nil when there are not n bars', tech_ma(rows, 20), nil)
    eq('an average can be taken at an earlier bar', tech_ma(rows, 5, 5), 3)
    -- (10 - 8) / 8 = 25%.
    near('bias is the distance from that average, in percent', tech_bias(rows, 5), 25, 1e-9)

    -- 60 days climbing, so every average is above the next longer one.
    local up = {}
    for i = 1, 80 do up[i] = { date = string.format('2026-%02d-%02d', 1 + i // 28, 1 + i % 28),
                               close = 10 + i * 0.1, high = 10 + i * 0.1, low = 10 + i * 0.1 } end
    local t = tech_build(up)
    eq('a series that only rises is 多头排列', t.trend.alignment, 'bull')
    eq('with the close above every average it has', t.trend.above_ma, t.trend.ma_count)
    local down = {}
    for i = 1, 80 do down[i] = { date = up[i].date, close = 20 - i * 0.1,
                                 high = 20 - i * 0.1, low = 20 - i * 0.1 } end
    eq('and one that only falls is 空头排列', tech_build(down).trend.alignment, 'bear')
    eq('too few bars say so instead of guessing', (tech_build({ { close = 1 } })), nil)

    -- A hundred days traded at 10, then twenty at 12, 5% of the float a day.
    -- Each day fades what came before by 5%, so 0.95^20 = 35.8% of the chips
    -- are still held from 10 and the rest from 12: 0.358*10 + 0.642*12 = 11.28.
    local chips_rows = {}
    local function bar(i, price)
        chips_rows[#chips_rows + 1] = { date = string.format('d%03d', i), close = price,
            high = price, low = price, volume = 1000, amount = price * 1000 * 100, turnover = 5 }
    end
    for i = 1, 100 do bar(i, 10) end
    for i = 101, 120 do bar(i, 12) end
    local c = tech_chips(chips_rows)
    near('the modelled average cost follows the turnover', c.avg_cost, 11.28, 0.05)
    near('everyone is in profit at the top price', c.profit_ratio, 100, 0.01)
    near('the 90% band spans both prices', c.low_90, 10, 0.02)
    near('up to the newer one', c.high_90, 12, 0.02)
    -- (12 - 10) / (12 + 10) = 9.1%.
    near('concentration is the width over the middle', c.concentration_90, 9.09, 0.2)
    local mid = tech_chips(chips_rows)
    chips_rows[#chips_rows].close = 10.5
    mid = tech_chips(chips_rows)
    check('a price in the middle leaves the older chips in profit only',
        mid.profit_ratio > 30 and mid.profit_ratio < 45, mid.profit_ratio)

    -- Without turnover there is nothing to distribute, and that is said.
    local no_turnover = {}
    for i = 1, 120 do no_turnover[i] = { date = string.format('d%03d', i), close = 10,
                                         high = 10, low = 10 } end
    local none, why = tech_chips(no_turnover)
    check('no turnover, no chip distribution', none == nil and why ~= nil, why)
    local built = tech_build(no_turnover)
    check('and the rest of the technical block still comes out',
        built.ma['20'] == 10 and built.chips == nil and built.chips_note ~= nil)

    -- Position within the range: closes from 10 to 20, last at 15.
    local ranged = {}
    for i = 1, 60 do ranged[i] = { date = string.format('d%03d', i), close = 10 + i / 6,
                                   high = 10 + i / 6, low = 10 + i / 6 } end
    ranged[#ranged].close, ranged[#ranged].high, ranged[#ranged].low = 15, 15, 15
    local rb = tech_build(ranged)
    near('the close sits where the range says', rb.range_60.position, 50, 1)
    near('and its distance from the high is signed', rb.range_60.from_high, -24.8, 0.5)
end

local function test_levels()
    section('levels')
    -- 400 days at PE 10..49 with a matching price, so the quantiles are known:
    -- sorted, the 10th percentile of 400 points sits at index 40.9.
    local rows = {}
    for i = 1, 400 do
        local pe = 10 + (i - 1) * 0.1
        rows[i] = { date = util_date_add_days('2024-01-01', i), close = pe * 2, pe_ttm = pe, pb = pe / 5 }
    end
    -- The last day is PE 49.9 and close 99.8.
    near('a quantile interpolates between neighbours', valuation_quantile(rows, 'pe_ttm', 10), 13.99, 0.02)
    near('the median is the middle', valuation_quantile(rows, 'pe_ttm', 50), 29.95, 0.02)

    local lv = levels_build(rows, { template = 'general' })
    eq('earnings are the default anchor', lv.metric, 'pe_ttm')
    -- price at multiple m = close * m / now = 99.8 * 13.99 / 49.9.
    near('the buy floor is the price at the 10% percentile', lv.buy.low, 27.98, 0.05)
    near('and its top the price at the 25% percentile', lv.buy.high, 39.95, 0.1)
    -- The 70th of 400 points is index 280.3, PE 37.93: 99.8 * 37.93 / 49.9.
    near('the target is the price at the 70% percentile', lv.target.price, 75.86, 0.05)
    near('with the upside measured from the close', lv.target.upside, -23.99, 0.05)
    eq('no daily bars, no stop', lv.stop, nil)

    -- A bank is read on book value instead.
    eq('a bank anchors on PB', levels_build(rows, { template = 'bank' }).metric, 'pb')
    -- A band the user set wins over both.
    local banded = levels_build(rows, { template = 'general',
                                        band = { metric = 'pe_ttm', low = 20, high = 40 } })
    eq('a band takes over the anchor', banded.source, 'band')
    near('buying starts at the band low', banded.buy.high, 40, 0.05)
    near('and the target is its high', banded.target.price, 80, 0.05)
    check('the band low is above the 10% percentile, so the range keeps a floor',
        banded.buy.low ~= nil)

    -- The stop is the nearest support below the price, minus the buffer.
    local tech = { ma = { ['250'] = 80, ['120'] = 95, ['60'] = 105 },
                   chips = { low_90 = 70 }, range_250 = { low = 60 } }
    local stopped = levels_build(rows, { template = 'general', technical = tech, stop_buffer = 3 })
    eq('MA60 is above the close, so MA120 is the nearest support', stopped.stop.support_label, 'MA120')
    near('and the stop sits 3% under it', stopped.stop.price, 92.15, 0.01)
    near('the loss to it is measured from the close', stopped.stop.downside, -7.67, 0.05)
    near('the reward-to-risk ratio compares the two distances', stopped.reward_risk,
        (stopped.target.price - 99.8) / (99.8 - stopped.stop.price), 1e-6)

    -- Below everything: only the year's low is left.
    local low_tech = { ma = { ['250'] = 200 }, chips = { low_90 = 150 }, range_250 = { low = 120 } }
    local floored = levels_build(rows, { template = 'general', technical = low_tech })
    eq('with no support under the price the year low is used', floored.stop.support_label, '近 250 日最低')

    -- A loss-making company has no PE to come back to, and says so.
    local losses = {}
    for i = 1, 400 do losses[i] = { date = rows[i].date, close = 10, pe_ttm = -5 } end
    local none, why = levels_build(losses, { template = 'general' })
    check('a negative anchor is refused with a reason', none == nil and why ~= nil, why)
    eq('and too short a history too',
        (levels_build({ { date = '2026-01-01', close = 10, pe_ttm = 10 } }, {})), nil)
end

local function test_calendar()
    section('trading calendar')
    -- 2026-09-18 is a Friday, the 19th and 20th the weekend, the 21st Monday.
    eq('the next weekday after a Friday is Monday', calendar_next_weekday('2026-09-18'), '2026-09-21')
    eq('after a Saturday, the same Monday', calendar_next_weekday('2026-09-19'), '2026-09-21')
    eq('after a Monday, Tuesday', calendar_next_weekday('2026-09-21'), '2026-09-22')
    -- 15:10 Beijing is 07:10 UTC.
    eq('a day settles at 07:10 UTC', calendar_close_at('2026-09-18') % 1440, 7 * 60 + 10)

    local friday, taken = '2026-09-18', '2026-09-18T08:00:00Z'
    check('Saturday is quiet', calendar_quiet(friday, taken, '2026-09-19T03:00:00Z'))
    check('Sunday night too', calendar_quiet(friday, taken, '2026-09-20T23:00:00Z'))
    check('and Monday before the close', calendar_quiet(friday, taken, '2026-09-21T02:00:00Z'))
    check('after Monday closes there could be a new bar',
        not calendar_quiet(friday, taken, '2026-09-21T08:00:00Z'))

    -- A holiday is discovered, not declared: we looked after Monday's close
    -- and Friday was still the last day, so the next chance is Tuesday's.
    local looked_monday = '2026-09-21T08:00:00Z'
    check('a day that produced no bar moves the next check on',
        calendar_quiet(friday, looked_monday, '2026-09-21T12:00:00Z'))
    check('and keeps it off all evening', calendar_quiet(friday, looked_monday, '2026-09-21T23:00:00Z'))
    check('until the following close', not calendar_quiet(friday, looked_monday, '2026-09-22T08:00:00Z'))
    -- A week-long holiday: each check that finds nothing pushes it one day on.
    check('a whole week of them is one request a day, not one every three hours',
        calendar_quiet(friday, '2026-09-25T08:00:00Z', '2026-09-25T23:00:00Z'))

    -- A bar of a day that is still trading is provisional.
    check('mid-session, the age limit decides', not calendar_quiet(friday, '2026-09-18T02:00:00Z',
        '2026-09-18T03:00:00Z'))
    check('and a bar taken mid-session is refetched after the close',
        not calendar_quiet(friday, '2026-09-18T02:00:00Z', '2026-09-18T08:00:00Z'))
    eq('without a last day there is nothing to conclude',
        calendar_quiet(nil, taken, '2026-09-19T03:00:00Z'), false)

    -- quote_is_stale defers to it: a series from years ago is stale whatever
    -- the clock says.
    check('an old cache is still stale', quote_is_stale({ rows = { { date = '2020-01-02' } },
        last_date = '2020-01-02', fetched_at = '2020-01-02T08:00:00Z' }, 180))

    -- The days that actually traded are read off the cached index.
    __net_set_transport(fixture_transport)
    eq('cache the regime index', api_call('quote.refresh', { code = 'idx:000300' }).ok, true)
    local days = calendar_trading_days()
    eq('the calendar is the index series', days and days.to, '2026-09-15')
    eq('a day in it traded', calendar_is_trading_day('2026-09-04'), true)
    -- 2026-09-05 is a Saturday: inside the range, absent from the series.
    eq('a day inside the range but missing did not', calendar_is_trading_day('2026-09-05'), false)
    eq('beyond the range it says it does not know', calendar_is_trading_day('2019-01-01'), nil)
    eq('and the status reports the source', calendar_status().source, '000300')
    __net_set_transport(nil)
end

local function test_quote()
    section('daily prices')
    local k = source_em_parse_kline(fixture('em_kline_600519.json'))
    eq('every recorded day is parsed', #k.rows, 11)
    eq('the name comes with them', k.name, '贵州茅台')
    -- Eastmoney sends date,open,CLOSE,high,low — not OHLC. The 4th of
    -- September opened at 1295.88 and closed at 1330.00, the high of the run.
    local d4
    for _, r in ipairs(k.rows) do if r.date == '2026-09-04' then d4 = r end end
    eq('open is open', d4.open, 1295.88)
    eq('close is not the second field by accident', d4.close, 1330.00)
    eq('high is the high', d4.high, 1338.86)
    eq('low is the low', d4.low, 1295.60)
    eq('volume is in 手', d4.volume, 45416)
    eq('turnover comes from the eleventh field', d4.turnover, 0.36)
    eq('and the change in percent from the ninth', d4.change_pct, 2.40)
    check('rows are oldest first', k.rows[1].date < k.rows[#k.rows].date)
    eq('a security with no history is empty, not an error',
        #source_em_parse_kline(fixture('em_kline_empty.json')).rows, 0)

    eq('a stock resolves to its own file', quote_resolve('SH600519').key, 'quote:600519')
    eq('an index has its own namespace, since 000001 is also a stock',
        quote_resolve('idx:000001').key, 'quote:idx:000001')
    eq('Shanghai indices are secid 1', source_em_secid(quote_resolve('idx:000001').sec), '1.000001')
    eq('Shenzhen indices are secid 0', source_em_secid(quote_resolve('idx:399001').sec), '0.399001')
    eq('a Shenzhen stock too', source_em_secid(quote_resolve('000001').sec), '0.000001')

    -- Extending a series: the overlap agrees, so the halves splice.
    local old = { { date = '2026-09-01', close = 10 }, { date = '2026-09-02', close = 11 } }
    local merged, drifted = quote_merge(old, { { date = '2026-09-02', close = 11 },
                                               { date = '2026-09-03', close = 12 } })
    eq('an extension keeps what was held', #merged, 3)
    eq('and ends at the new day', merged[3].date, '2026-09-03')
    check('no adjustment change was seen', not drifted)
    -- A dividend rewrites the whole forward-adjusted series: the same day now
    -- closes lower, so the old rows cannot be spliced onto the new ones.
    local after, drift2 = quote_merge(old, { { date = '2026-09-02', close = 10.5 },
                                             { date = '2026-09-03', close = 11.4 } })
    check('a changed adjustment is caught', drift2)
    eq('and only the fresh rows survive it', #after, 2)

    eq('an empty cache is stale', quote_is_stale(nil), true)
    local now = util_now_iso()
    check('a series fetched just now is not',
        not quote_is_stale({ fetched_at = now, rows = { { date = '2026-09-01' } } }, 180))
    check('one fetched yesterday is',
        quote_is_stale({ fetched_at = util_date_add_days(now:sub(1, 10), -1) .. now:sub(11),
                         rows = { { date = '2026-09-01' } } }, 180))

    __net_set_transport(fixture_transport)
    local r = api_call('quote.refresh', { code = '600519' })
    check('a refresh stores the series', r.ok, r.error and r.error.message)
    eq('which knows its last day', r.ok and r.data.last_date, '2026-09-15')
    eq('the head alone comes back from a refresh', r.ok and #r.data.rows, 0)
    local g = api_call('quote.get', { code = '600519', days = 3, offline = true })
    eq('a read serves the cache', g.ok and g.data.days, 11)
    eq('cut to the days asked for', g.ok and #g.data.rows, 3)
    eq('newest last', g.ok and g.data.rows[3].date, '2026-09-15')
    eq('a security the source has no prices for is not_found',
        api_call('quote.refresh', { code = '000002' }).error.code, 'not_found')
    eq('and an offline read of a stock never fetched says so',
        api_call('quote.get', { code = '000002', offline = true }).error.code, 'not_fetched')
    __net_set_transport(nil)
end

local function test_backtest()
    section('backtest')
    -- 500 days, the multiple falling every day and the price compounding 1% a
    -- day. Every cheap day is cheaper than the window before it, so the signal
    -- is true from the moment the 240-day window exists (day 241) onward, and
    -- the cooldown of 20 turns that into one entry every twenty days:
    -- 241, 261, ... 481 — thirteen of them.
    local val, px = {}, {}
    for i = 1, 500 do
        local date = util_date_add_days('2023-01-01', i)
        val[i] = { date = date, close = 100 * 1.01 ^ i, pe_ttm = 501 - i }
        px[i] = { date = date, close = 100 * 1.01 ^ i,
                  high = 100 * 1.01 ^ i, low = 100 * 1.01 ^ i }
    end
    local found = backtest_signals(val, px, { signal = 'value', metric = 'pe_ttm',
                                              percentile = 25, cooldown = 20 })
    eq('the cooldown turns a standing signal into periodic entries', #found.entries, 13)
    eq('the first is the day the window becomes long enough', found.entries[1].date, val[241].date)
    eq('days before that are not even tested', found.tested, 260)
    check('each entry knows the threshold it was judged against',
        found.entries[1].threshold ~= nil and found.entries[1].threshold > found.entries[1].metric_value)

    -- A rising multiple never reaches its own lower quartile.
    local rising = {}
    for i = 1, 500 do rising[i] = { date = val[i].date, close = val[i].close, pe_ttm = i } end
    eq('a multiple that only rises never fires', #backtest_signals(rising, px,
        { signal = 'value', metric = 'pe_ttm', percentile = 25 }).entries, 0)

    -- 1.01^20 = 22.02%, every time, so the direction is won every time.
    local hz = backtest_horizons(found.entries, px, { 20 })
    eq('an entry without 20 more days of data has no 20-day result', hz[1].n, 12)
    near('a series that only rises wins every time', hz[1].win_rate, 100, 1e-9)
    near('and the return is the compounding', hz[1].avg, 22.019, 0.01)

    -- The barriers, on bars built to touch one level or the other.
    local function bars(second)
        return { { date = 'd1', close = 100, high = 100, low = 100 }, second }
    end
    local entry = { { index = 1, date = 'd1', close = 100 } }
    local up = backtest_barrier(entry, bars({ date = 'd2', close = 121, high = 121, low = 99 }),
                                { take_profit = 20, stop_loss = 10 })
    eq('touching the take profit first is a win', up.hit_tp, 1)
    near('recorded one day after the entry', up.avg_days_tp, 1, 1e-9)
    local down = backtest_barrier(entry, bars({ date = 'd2', close = 89, high = 101, low = 89 }),
                                  { take_profit = 20, stop_loss = 10 })
    eq('touching the stop first is a loss', down.hit_sl, 1)
    -- A day that covers both: daily bars cannot say which came first, and the
    -- flattering assumption is the one that makes every backtest look good.
    local both = backtest_barrier(entry, bars({ date = 'd2', close = 100, high = 121, low = 89 }),
                                  { take_profit = 20, stop_loss = 10 })
    eq('a day that touches both counts as the stop', both.hit_sl, 1)
    eq('and is counted separately so it can be read', both.both_same_day, 1)
    local flat = backtest_barrier(entry, bars({ date = 'd2', close = 100, high = 101, low = 99 }),
                                  { take_profit = 20, stop_loss = 10 })
    eq('reaching neither within the horizon is neither', flat.neither, 1)
    eq('and leaves the hit rate to the decided ones', flat.win_rate, nil)

    -- The whole thing, with its baseline.
    local res = backtest_evaluate(val, px, { signal = 'value', metric = 'pe_ttm',
                                             percentile = 25, cooldown = 20,
                                             horizons = { 20 }, take_profit = 20, stop_loss = 10 })
    eq('the result counts its entries', res.entries, 13)
    check('and compares them with buying on any day of the same window',
        res.baseline and res.baseline.horizons[1].n > res.horizons[1].n)
    near('which on this series also wins every time', res.baseline.horizons[1].win_rate, 100, 1e-9)

    -- A signal that never fires says so instead of returning empty statistics.
    local none = backtest_evaluate(rising, px, { signal = 'value', metric = 'pe_ttm' })
    check('a signal that never fired is reported as such', none.note ~= nil and none.entries == 0)

    -- 多头排列 on prices alone, no valuation window needed.
    local trend = backtest_signals(val, px, { signal = 'trend', cooldown = 60 })
    check('a rising series is in bull order once the averages exist', #trend.entries > 0)
    eq('and the first is after MA60 exists', trend.entries[1].index >= 60, true)

    __net_set_transport(fixture_transport)
    eq('a stock with too little valuation history is refused',
        api_call('backtest.run', { code = '600519' }).error.code, 'bad_request')
    eq('and a nonsensical stop is refused before any work',
        api_call('backtest.run', { code = '600519', stop_loss = 0 }).error.code, 'bad_request')
    __net_set_transport(nil)
end

local function test_review()
    section('daily review')
    local sect = source_em_parse_sectors(fixture('em_sectors.json'))
    eq('every board row is parsed', #sect.rows, 12)
    eq('and the table says how many there are in all', sect.count, 496)
    eq('boards come back strongest first', sect.rows[1].name, '其他医疗服务')
    eq('with their own change', sect.rows[1].change_pct, 6.72)
    eq('the advancing count', sect.rows[1].up, 5)
    eq('the declining count', sect.rows[1].down, 0)
    eq('the board leader', sect.rows[1].leader, '南华生物')
    eq('and its change', sect.rows[1].leader_change, 10.0)
    eq('a board with no rows at all is empty, not an error',
        #source_em_parse_sectors({ data = util_null }).rows, 0)

    -- A series that only rises ends above a rising 250-day average.
    local up = {}
    for i = 1, 400 do up[i] = { date = util_date_add_days('2024-01-01', i),
                                close = 1000 + i, high = 1000 + i, low = 1000 + i } end
    local bull = review_regime(up)
    eq('rising above a rising long average is 多头', bull.state, 'bull')
    check('and the reason says why', #bull.reasons > 0 and bull.reasons[1]:find('MA250', 1, true))
    near('with no drawdown at a new high', bull.drawdown, 0, 1e-9)

    local down = {}
    for i = 1, 400 do down[i] = { date = up[i].date, close = 2000 - i, high = 2000 - i, low = 2000 - i } end
    eq('falling below a falling one is 空头', review_regime(down).state, 'bear')

    -- Up for a year, then down for a year: the average is still rising while
    -- the price is below it, which is exactly the third state.
    local mixed = {}
    for i = 1, 250 do mixed[#mixed + 1] = { date = up[i].date, close = 1000 + i * 2,
                                            high = 1000 + i * 2, low = 1000 + i * 2 } end
    for i = 1, 150 do mixed[#mixed + 1] = { date = up[250 + i].date, close = 1500 - i * 2,
                                            high = 1500 - i * 2, low = 1500 - i * 2 } end
    eq('anything else is 震荡', review_regime(mixed).state, 'range')
    eq('and too little history is unknown', review_regime({ { close = 1 } }).state, 'unknown')
    eq('an unknown regime still gets a stance', review_stance('unknown').position, '—')
    check('every state maps to one', review_stance('bull').position ~= nil
        and review_stance('bear').position ~= nil and review_stance('range').position ~= nil)

    __net_set_transport(fixture_transport)
    local r = api_call('review.daily', { top = 3 })
    check('the review builds', r.ok, r.error and r.error.message)
    if r.ok then
        eq('the board table came from the fixture', r.data.structure.sector_count, 12)
        eq('breadth counts boards, not companies', r.data.structure.breadth.total, 12)
        eq('leaders are capped at the number asked for', #r.data.structure.leaders, 3)
        eq('and laggards too', #r.data.structure.laggards, 3)
        eq('the weakest board is last', r.data.structure.laggards[1].name,
            sect.rows[#sect.rows].name)
        eq('no index history in the fixtures, so no regime', r.data.market.regime.state, 'unknown')
        eq('the watchlist part lists what is watched', r.data.watchlist.count,
            #api_call('watchlist.list').data)
    end
    local md = report_review_markdown(r.data)
    check('the review renders as Markdown', md:find('## 二、结构', 1, true))
    __net_set_transport(nil)
end

local function test_market()
    section('market snapshot')
    eq('60 is the main board', market_board('600519'), 'main')
    eq('00 too', market_board('000001'), 'main')
    eq('30 is ChiNext', market_board('300750'), 'gem')
    eq('68 is the STAR market', market_board('688336'), 'star')
    eq('83 is Beijing', market_board('830799'), 'bj')
    check('ST is read off the name', market_is_st('*ST 某某') and market_is_st('ST康美'))
    check('and an ordinary name is not', not market_is_st('贵州茅台'))
    -- Annual reports land between January and April, so before May the year
    -- before last is the one every company has filed.
    eq('in March, the year before last', market_annual_period('2026-03-15'), '2024-12-31')
    eq('in May, last year', market_annual_period('2026-05-01'), '2025-12-31')

    local valuation = {
        { SECURITY_CODE = '600001', SECURITY_NAME_ABBR = '甲公司', BOARD_NAME = '白酒Ⅱ',
          TOTAL_MARKET_CAP = 5e10, CLOSE_PRICE = 50, PE_TTM = 12, PB_MRQ = 3, PS_TTM = 4, PCF_OCF_TTM = 9 },
        { SECURITY_CODE = '300002', SECURITY_NAME_ABBR = '乙公司', BOARD_NAME = '软件开发',
          TOTAL_MARKET_CAP = 8e9, CLOSE_PRICE = 20, PE_TTM = -8, PB_MRQ = 6, PS_TTM = 20, PCF_OCF_TTM = -3 },
        { SECURITY_CODE = '600003', SECURITY_NAME_ABBR = 'ST丙', BOARD_NAME = '白酒Ⅱ',
          TOTAL_MARKET_CAP = 2e9, CLOSE_PRICE = 4, PE_TTM = 40, PB_MRQ = 1, PS_TTM = 2, PCF_OCF_TTM = 5 },
    }
    local reports = {
        { SECURITY_CODE = '600001', SECURITY_NAME_ABBR = '甲公司', WEIGHTAVG_ROE = 25,
          TOTAL_OPERATE_INCOME = 1e10, PARENT_NETPROFIT = 3e9, YSTZ = 12, SJLTZ = 18,
          XSMLL = 60, BASIC_EPS = 2, DEDUCT_BASIC_EPS = 1.9, BPS = 10, MGJYXJJE = 2.4,
          NOTICE_DATE = '2026-03-20 00:00:00' },
        { SECURITY_CODE = '300002', SECURITY_NAME_ABBR = '乙公司', WEIGHTAVG_ROE = -5,
          TOTAL_OPERATE_INCOME = 4e8, PARENT_NETPROFIT = -1e8, YSTZ = 40, SJLTZ = -200,
          XSMLL = 70, BASIC_EPS = -0.3, BPS = 3, MGJYXJJE = 0.1 },
        { SECURITY_CODE = '600003', SECURITY_NAME_ABBR = 'ST丙', WEIGHTAVG_ROE = 30,
          TOTAL_OPERATE_INCOME = 1e9, PARENT_NETPROFIT = 2e8, YSTZ = 5, SJLTZ = 3,
          XSMLL = 20, BASIC_EPS = 0.5, BPS = 2, MGJYXJJE = 0.2 },
    }

    local parsed = source_em_parse_market_valuation(market_page(valuation, 5565))
    eq('valuation rows parsed', #parsed.rows, 3)
    eq('and the page count comes from the source', parsed.pages, 3)
    eq('code kept', parsed.rows[1].code, '600001')
    eq('industry kept', parsed.rows[1].industry, '白酒Ⅱ')
    eq('an empty result is empty, not an error',
        #source_em_parse_market_valuation(fixture('em_empty.json')).rows, 0)
    eq('a wrong shape is an error', (source_em_parse_market_valuation({ foo = 1 })), nil)

    local fin = source_em_parse_market_reports(market_page(reports, 5574, 500))
    eq('report rows parsed', #fin.rows, 3)
    eq('weighted ROE mapped', fin.rows[1].roe, 25)
    eq('revenue growth mapped', fin.rows[1].revenue_yoy, 12)
    eq('per-share operating cash flow mapped', fin.rows[1].ocfps, 2.4)

    -- Refresh through the real path, with the two tables served as one page each.
    __net_set_transport(function(url)
        if url:find('TRADE_DATE&sortTypes=-1', 1, true) then
            return { status = 200, body = util_json_encode(
                { result = { data = { { TRADE_DATE = '2026-09-18 00:00:00' } }, count = 1, pages = 1 } }) }
        elseif url:find('RPT_VALUEANALYSIS_DET', 1, true) then
            return { status = 200, body = util_json_encode(market_page(valuation)) }
        elseif url:find('RPT_LICO_FN_CPD', 1, true) then
            return { status = 200, body = util_json_encode(market_page(reports, 3, 500)) }
        end
        return nil, 'unexpected URL in test: ' .. url
    end)
    local st = api_call('market.refresh')
    check('refresh succeeds', st.ok, st.error and st.error.message)
    eq('the snapshot knows its trade date', st.ok and st.data.trade_date, '2026-09-18')
    eq('and how many rows carry figures', st.ok and st.data.with_reports, 3)
    __net_set_transport(nil)

    local function screen(q)
        local res = api_call('market.screen', q)
        return res.ok and res.data or nil, res.error
    end
    local all = screen({})
    eq('ST is excluded by default', all.matched, 2)
    eq('unless asked for', screen({ include_st = 'true' }).matched, 3)
    eq('ROE filter', screen({ roe_min = 20 }).matched, 1)
    eq('a PE ceiling excludes a loss-maker', screen({ pe_max = 100 }).matched, 1)
    eq('market cap is given in 亿', screen({ cap_min = 100 }).matched, 1)
    eq('board filter', screen({ boards = 'gem' }).matched, 1)
    eq('industry is a substring', screen({ industry = '白酒' }).matched, 1)
    eq('keyword matches the name', screen({ keyword = '乙' }).matched, 1)
    eq('keyword matches the code too', screen({ keyword = '600001' }).matched, 1)
    -- 2.4 / 2 = 1.2 for 甲; 乙 has a negative EPS and cannot qualify.
    eq('cash flow over EPS', screen({ ocf_to_eps_min = 1 }).matched, 1)
    eq('a row missing the figure never passes a filter on it',
        screen({ gross_margin_min = 0, keyword = '600003', include_st = 'true' }).matched, 1)

    local sorted = screen({ include_st = 'true', sort = 'pb', order = 'asc' })
    eq('sorting ascending', sorted.rows[1].code, '600003')
    eq('sorting descending', screen({ include_st = 'true', sort = 'pb' }).rows[1].code, '300002')
    eq('limit caps the rows but not the count', #screen({ include_st = 'true', limit = 1 }).rows, 1)
    eq('the count is still the full match', screen({ include_st = 'true', limit = 1 }).matched, 3)
    eq('an unknown sort is refused', api_call('market.screen', { sort = 'nope' }).error.code, 'bad_request')
    eq('an unknown board is refused', api_call('market.screen', { boards = 'nope' }).error.code, 'bad_request')

    local row = all.rows[1]
    eq('the row carries what the table showed', row.code, '600001')
    near('with the derived cash-flow ratio', row.ocf_to_eps, 1.2, 1e-9)
end

-- ── Phase 5: the insurance and broker templates ─────────────────────────────

local function test_insurer()
    section('template: insurance')
    local rep = source_em_parse_reports(fixture('em_reports_601318.json'))
    eq('保险 is the insurance template', rep.org_type, 'insurance')
    local latest = rep.reports[1]
    eq('solvency ratio mapped', latest.solvency_ratio, 198.1)
    eq('embedded value mapped', latest.embedded_value, 970839000000)
    eq('new business value mapped', latest.nbv, 24847000000)
    eq('surrender rate mapped', latest.surrender_rate, 0.64)

    local q = quality_build(rep.reports, 'insurance')
    local keys = {}
    for _, s in ipairs(q.series) do keys[s.key] = true end
    check('the series are the insurer\'s own', keys.solvency_ratio and keys.nbv and keys.embedded_value)
    check('and not a general company\'s', not keys.gross_margin and not keys.ocf_to_np)
    local sm = {}
    for _, s in ipairs(q.summary) do sm[s.key] = s end
    eq('solvency in the summary', sm.solvency_latest.value, 198.1)
    -- 36,897 -> 40,024 -> 31,080 over 2023..2025: two years, both ends positive
    check('new business value has a growth line', sm.nbv_cagr and sm.nbv_cagr.value ~= nil)

    local s = status_of(checks_build(rep.reports, {}, 'insurance'))
    eq('solvency 198.1% clears the 150% line', s.solvency, 'pass')
    -- 2025 new business value 368.97亿 vs 2024 400.24亿 = -7.8%, inside -10%
    eq('new business value down 7.8% still passes', s.nbv_trend, 'pass')
    eq('a 1.52% surrender rate passes', s.surrender_rate, 'pass')
    -- The 2025 annual net investment yield is 3.7%, above the 3.5% line
    eq('net investment yield read from the annual report', s.net_investment_yield, 'pass')
    eq('insurers skip the bank checks', s.npl_ratio, nil)

    local weak = { R('2025-12-31', { np_parent = 1e9, solvency_ratio = 120, nbv = 5e9,
                                     surrender_rate = 4.5, net_investment_yield = 2.9 }),
                   R('2024-12-31', { np_parent = 1e9, nbv = 8e9 }) }
    local w = status_of(checks_build(weak, {}, 'insurance'))
    eq('solvency 120% warns', w.solvency, 'warn')
    eq('new business value down 37.5% warns', w.nbv_trend, 'warn')
    eq('a 4.5% surrender rate warns', w.surrender_rate, 'warn')
    eq('a 2.9% net investment yield warns', w.net_investment_yield, 'warn')

    -- P/EV: market capitalisation over the newest reported embedded value.
    local data = { code = '601318', market = 'SH', name = '中国平安', org_type = 'insurance',
                   reports = rep.reports, dividends = {},
                   valuation = { { date = '2026-09-17', close = 60, market_cap = 970839000000 } } }
    local a = analysis_build(data, nil, {})
    local pev = a.valuation.extras[1]
    eq('P/EV is offered for insurers', pev.key, 'pev')
    near('and equals cap / embedded value', pev.value, 1, 1e-9)
    check('with the arithmetic shown', pev.basis:find('2026-06-30', 1, true), pev.basis)
    check('the note says whose assumptions those are', pev.note:find('精算假设', 1, true))
end

local function test_broker()
    section('template: broker')
    local rep = source_em_parse_reports(fixture('em_reports_600030.json'))
    eq('证券 is the broker template', rep.org_type, 'broker')
    local latest = rep.reports[1]
    eq('risk coverage mapped', latest.risk_coverage, 225.31)
    eq('capital leverage mapped', latest.capital_leverage, 12.7)
    eq('net capital / net assets mapped', latest.net_capital_ratio, 64.83)
    eq('proprietary equity exposure mapped', latest.proprietary_equity_ratio, 39.96)

    local q = quality_build(rep.reports, 'broker')
    local keys = {}
    for _, s in ipairs(q.series) do keys[s.key] = true end
    check('the series are the regulator\'s ratios', keys.risk_coverage and keys.capital_leverage
        and keys.net_capital_ratio)

    local s = status_of(checks_build(rep.reports, {}, 'broker'))
    for _, key in ipairs({ 'risk_coverage', 'capital_leverage', 'liquidity_coverage',
                           'net_funding_ratio', 'net_capital_ratio', 'proprietary_equity' }) do
        eq('a well capitalised broker passes ' .. key, s[key], 'pass')
    end
    eq('brokers skip the general checks', s.gross_margin_stable, nil)

    -- At the warning levels, every one of them fires.
    local tight = { R('2026-06-30', { np_parent = 1e9, risk_coverage = 110, capital_leverage = 9,
                                      liquidity_coverage = 105, net_funding_ratio = 110,
                                      net_capital_ratio = 21, proprietary_equity_ratio = 95 }) }
    local t = status_of(checks_build(tight, {}, 'broker'))
    eq('risk coverage 110% warns', t.risk_coverage, 'warn')
    eq('capital leverage 9% warns', t.capital_leverage, 'warn')
    eq('liquidity coverage 105% warns', t.liquidity_coverage, 'warn')
    eq('net stable funding 110% warns', t.net_funding_ratio, 'warn')
    eq('net capital at 21% of net assets warns', t.net_capital_ratio, 'warn')
    eq('a 95% equity exposure warns', t.proprietary_equity, 'warn')

    local bare = status_of(checks_build({ R('2026-06-30', { np_parent = 1 }) }, {}, 'broker'))
    eq('missing ratios are na, not pass', bare.risk_coverage, 'na')
end

-- ── Phase 4: business breakdown, language models, insights ──────────────────

local function business_record()
    local parsed = source_em_parse_business(fixture('em_business_600519.json'))
    return { scope = parsed.scope, reviews = { parsed.review }, segments = parsed.segments }, parsed
end

local function test_business()
    section('business breakdown')
    local biz, parsed = business_record()
    check('scope parsed', type(parsed.scope) == 'string' and #parsed.scope > 0)
    eq('the review is the latest report\'s', parsed.review and parsed.review.period, '2026-06-30')
    eq('segments from three periods', #parsed.segments, 21)
    local moutai
    for _, s in ipairs(parsed.segments) do
        if s.period == '2025-12-31' and s.kind == 'product' and s.name == '茅台酒' then moutai = s end
    end
    near('a share arrives as a fraction and is kept as percent', moutai and moutai.revenue_share, 86.7695, 1e-6)
    near('gross margin likewise', moutai and moutai.gross_margin, 93.5258, 1e-6)
    check('revenue sent as a string is a number', type(moutai and moutai.revenue) == 'number')
    eq('a wrong shape is an error', (source_em_parse_business({ foo = 1 })), nil)

    local a = analysis_build({ code = '600519', market = 'SH', name = '贵州茅台', org_type = 'general',
                               reports = {}, valuation = {}, dividends = {}, business = biz }, nil, {})
    eq('the breakdown uses the latest annual report', a.business.period, '2025-12-31')
    eq('and compares with the year before', a.business.previous_period, '2024-12-31')
    eq('largest line first', a.business.by.product[1].name, '茅台酒')
    -- 86.7695 (2025) - 85.3884 (2024)
    near('share change is computed here, not by the model', a.business.by.product[1].share_change, 1.3811, 1e-4)
    eq('the review is summarised, not copied into the analysis', a.business.review.period, '2026-06-30')
end

local function test_llm()
    section('language model protocols')
    local ac = { provider = 'anthropic', base = 'https://api.anthropic.com', key = 'k', model = 'claude-opus-5',
                 max_tokens = 16000, fallbacks = true }
    local req = llm_build(ac, { system = 's', messages = { { role = 'user', content = 'q' } }, schema = { type = 'object' } })
    eq('Claude: Messages API path', req.url, 'https://api.anthropic.com/v1/messages')
    eq('Claude: key header', req.headers['x-api-key'], 'k')
    eq('Claude: version header', req.headers['anthropic-version'], '2023-06-01')
    eq('Claude: fallbacks on by default', req.body.fallbacks, 'default')
    eq('Claude: with its beta header', req.headers['anthropic-beta'], 'server-side-fallback-2026-07-01')
    eq('Claude: a schema becomes output_config.format', req.body.output_config.format.type, 'json_schema')
    eq('Claude: system is top-level', req.body.system, 's')
    local plain = llm_build(util_copy(ac), { system = 's', messages = {} })
    eq('Claude: no schema, no effort, no output_config', plain.body.output_config, nil)
    local nofb = util_copy(ac); nofb.fallbacks = false
    eq('Claude: fallbacks can be turned off', llm_build(nofb, { system = 's', messages = {} }).headers['anthropic-beta'], nil)

    local oc = { provider = 'openai', base = 'https://api.deepseek.com/v1', key = 'k', model = 'deepseek-chat', max_tokens = 4000 }
    local oreq = llm_build(oc, { system = 's', messages = { { role = 'user', content = 'q' } }, schema = {} })
    eq('OpenAI-compatible: path', oreq.url, 'https://api.deepseek.com/v1/chat/completions')
    eq('OpenAI-compatible: bearer', oreq.headers.Authorization, 'Bearer k')
    eq('OpenAI-compatible: system is the first message', oreq.body.messages[1].role, 'system')
    eq('OpenAI-compatible: JSON mode', oreq.body.response_format.type, 'json_object')

    local ok200 = { status = 200 }
    local got = llm_parse(ac, ok200, { model = 'claude-opus-5', stop_reason = 'end_turn',
        content = { { type = 'thinking', thinking = '' }, { type = 'text', text = 'a' }, { type = 'text', text = 'b' } },
        usage = { input_tokens = 10, output_tokens = 5 } })
    eq('Claude: text blocks joined, thinking skipped', got and got.text, 'ab')
    eq('Claude: usage kept', got and got.usage.output_tokens, 5)
    eq('Claude: a refusal is an error', (llm_parse(ac, ok200, { stop_reason = 'refusal', content = {} })), nil)
    eq('Claude: a truncated answer is an error',
        (llm_parse(ac, ok200, { stop_reason = 'max_tokens', content = { { type = 'text', text = 'x' } } })), nil)
    local _, why = llm_parse(ac, { status = 401 }, { error = { message = 'invalid x-api-key' } })
    check('an HTTP error carries the service\'s message', why and why:find('invalid x-api-key', 1, true), why)

    local og = llm_parse(oc, ok200, { choices = { { message = { content = 'hi' }, finish_reason = 'stop' } },
                                      usage = { prompt_tokens = 3, completion_tokens = 2 } })
    eq('OpenAI-compatible: content', og and og.text, 'hi')
    eq('OpenAI-compatible: usage mapped', og and og.usage.input_tokens, 3)
    eq('OpenAI-compatible: length is truncation',
        (llm_parse(oc, ok200, { choices = { { message = { content = 'x' }, finish_reason = 'length' } } })), nil)
end

local INSIGHT_JSON = '{"summary":"品牌护城河强，但增速放缓。","moat":{"sources":["品牌","特许经营与牌照"],' ..
    '"strength":"强","evidence":["主营构成：茅台酒 占 86.8%","毛利率 99.9%"]},"changes":["营收同比 -1.2%"],' ..
    '"risks":[],"questions":["系列酒毛利率为何低于茅台酒"]}'

local function test_insight()
    section('insights: facts in, a checked reading out')
    local nums = {}
    for _, n in ipairs(insight_numbers('ROE 均值 32.6%，营收 1720.54 亿，2025 年，3 项，变化 -0.8 个百分点，10派280.2423元')) do
        nums[#nums + 1] = n.text
    end
    eq('numbers that make a claim are found; years and counts are not', table.concat(nums, ' '),
        '32.6 1720.54 0.8 280.2423')
    local bad = insight_unverified('ROE 32.6%，净利润 999.9 亿，PE 19.4', 'ROE 32.56%，PE 19.45')
    eq('a figure absent from the facts is flagged', table.concat(bad, ','), '999.9')
    eq('rounding to the stated precision is not', #insight_unverified('PE 19.5', 'PE 19.45'), 0)

    local parsed = insight_parse('```json\n' .. INSIGHT_JSON .. '\n```')
    eq('a fenced JSON answer parses', parsed and parsed.moat.strength, '强')
    eq('an empty list stays a list', parsed and #parsed.risks, 0)
    eq('prose is not an answer', (insight_parse('这是一段话')), nil)
    eq('the wrong JSON is not an answer', (insight_parse('{"a":1}')), nil)
    check('a provider without schemas is told the shape',
        insight_request('f', 'openai').messages[1].content:find('只输出一个 JSON 对象', 1, true))
    check('Claude is given the schema instead',
        not insight_request('f', 'anthropic').messages[1].content:find('只输出一个 JSON 对象', 1, true))

    __llm_set_config(false)
    eq('without a model, generating is unavailable', api_call('insight.generate', { code = '600519' }).error.code,
        'unavailable')
    eq('llm.status says so', api_call('llm.status').data.enabled, false)

    __llm_set_config({ provider = 'anthropic', base = 'https://llm.test', key = 'k', model = 'claude-opus-5',
                       max_tokens = 16000, timeout_ms = 1000, fallbacks = true })
    local sent = {}
    __net_set_transport(function(url, opts)
        if url:find('llm.test', 1, true) then
            sent[#sent + 1] = util_json_decode(opts.body)
            local text = #sent <= 2 and INSIGHT_JSON or '公司 ROE 较高。'
            return { status = 200, body = util_json_encode({ model = 'claude-opus-5', stop_reason = 'end_turn',
                content = { { type = 'text', text = text } }, usage = { input_tokens = 100, output_tokens = 50 } }) }
        end
        return fixture_transport(url, opts)
    end)
    eq('fetch the stock with its business data', api_call('stock.refresh', { code = '600519' }).ok, true)
    local r = api_call('insight.generate', { code = '600519' })
    check('generate succeeds', r.ok, r.error and r.error.message)
    if r.ok then
        eq('the reading is stored parsed', r.data.result.moat.sources[1], '品牌')
        check('an invented figure is flagged', table.concat(r.data.unverified, ','):find('99.9', 1, true),
            table.concat(r.data.unverified, ','))
        check('a copied figure is not', not table.concat(r.data.unverified, ','):find('86.8', 1, true),
            table.concat(r.data.unverified, ','))
        local body = sent[1]
        check('the model is told not to compute', body.system:find('不要自己计算', 1, true))
        check('the facts carry the business breakdown', body.messages[1].content:find('【主营构成】', 1, true))
        check('and the management review', body.messages[1].content:find('【管理层经营评述】', 1, true))
        eq('the schema is enforced', body.output_config.format.type, 'json_schema')
    end
    eq('insight.get returns what was stored', api_call('insight.get', { code = '600519' }).data.created_at,
        r.ok and r.data.created_at)
    api_call('insight.generate', { code = '600519' })
    local stored = store_load('insight:600519')
    eq('the previous reading moves to history', stored and #stored.history, 1)

    local asked = api_call('insight.ask', { code = '600519', question = 'ROE 高吗？',
        history = { { role = 'user', content = '毛利率呢？' }, { role = 'assistant', content = '很高。' } } })
    eq('ask answers', asked.ok and asked.data.answer, '公司 ROE 较高。')
    local q = sent[#sent]
    eq('history plus the question make three turns', q and #q.messages, 3)
    check('the facts ride on the first turn', q and q.messages[1].content:find('【事实】', 1, true))
    eq('a missing question is refused', api_call('insight.ask', { code = '600519' }).error.code, 'bad_request')

    -- A new annual report during a check produces a reading in the same run.
    api_call('watchlist.add', { code = '600519' })
    local doc = fixture('em_reports_600519.json')
    local fy = util_copy(doc.result.data[1])
    fy.REPORT_DATE, fy.REPORT_DATE_NAME, fy.NOTICE_DATE = '2026-12-31 00:00:00', '2026年报', '2027-03-28 00:00:00'
    table.insert(doc.result.data, 1, fy)
    local reports_body = util_json_encode(doc)
    __notify_set_channels({})
    __net_set_transport(function(url, opts)
        if url:find('llm.test', 1, true) then
            return { status = 200, body = util_json_encode({ stop_reason = 'end_turn',
                content = { { type = 'text', text = INSIGHT_JSON } } }) }
        elseif url:find('RPT_F10_FINANCE_MAINFINADATA', 1, true) then
            return { status = 200, body = reports_body }
        end
        return fixture_transport(url, opts)
    end)
    local run = api_call('alerts.run')
    check('the check runs', run.ok, run.error and run.error.message)
    local kinds = {}
    for _, e in ipairs(alerts_list({ code = '600519', limit = 5 })) do
        kinds[e.kind] = kinds[e.kind] or e       -- newest first: keep the newest of each kind
    end
    check('the new annual report is an alert', kinds.report and kinds.report.period == '2026-12-31')
    check('and so is its reading', kinds.insight and kinds.insight.detail:find('护城河：强', 1, true),
        kinds.insight and kinds.insight.detail)

    __net_set_transport(nil)
    __notify_set_channels(nil)
    __llm_set_config(nil)
    api_call('watchlist.remove', { code = '600519' })
end

-- ─────────────────────────────────────────────────────────────────────────────

local DATA = 'tmp/unit-data'

local function clean()
    for _, f in ipairs({ 'watchlist.json', 'alerts.json', 'state.json', 'stocks/600519.json',
                         'stocks/000001.json', 'stocks/609999.json', 'insights/600519.json',
                         'market.json' }) do
        util_file_remove(DATA .. '/' .. f)
    end
end

local function run_all()
    test_modules()
    test_json()
    test_security()
    test_parsers()
    test_fin()
    test_valuation()
    test_dividends()
    test_checks()
    test_quality()
    test_analysis()
    test_commands()
    test_http()
    local evs = test_events()
    test_notify()
    test_wecom_callback()
    test_alerts(evs)
    test_schedule()
    test_position_events()
    test_refresh_events()
    test_business()
    test_llm()
    test_insight()
    test_insurer()
    test_broker()
    test_market()
    test_quote()
    test_calendar()
    test_tech()
    test_levels()
    test_review()
    test_backtest()
end

return {
    __thread_handle = function() end,
    __init = function()
        assert(xnet.init())
        xtimer.init(16)
        clean()
        local ok, err = engine_start({ data_dir = DATA })
        if not ok then
            out('engine failed to start: ' .. tostring(err) .. '\n')
            xthread.stop(1)
            return
        end
        http_install_api()
        -- On a coroutine: refresh paces its requests with sched_sleep.
        sched_spawn('unit', function()
            local okr, e = xpcall(run_all, debug.traceback)
            if not okr then
                fails = fails + 1
                out('FAIL (raised) ' .. tostring(e) .. '\n')
            end
            clean()
            out(string.format('\n[unit] %s (%d checks, %d failure(s))\n',
                fails == 0 and 'ALL PASS' or 'FAILED', total, fails))
            xthread.stop(fails == 0 and 0 or 1)
        end)
    end,
    __uninit = function()
        engine_stop()
        xnet.uninit()
    end,
}
