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
    eq('an insurer gets the profit check only', #checks_build(bank, {}, 'insurance'), 1)
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
    eq('the webhook carries a bearer', notify_build('webhook', { url = 'u', bearer = 'k' }, msg, 1).headers.Authorization,
        'Bearer k')

    eq('WeCom errcode 0 is delivered', (notify_judge('wecom', { status = 200 }, { errcode = 0 })), true)
    eq('WeCom errcode with HTTP 200 is refused', (notify_judge('wecom', { status = 200 }, { errcode = 93000, errmsg = 'x' })), false)
    eq('Feishu code 0 is delivered', (notify_judge('feishu', { status = 200 }, { code = 0 })), true)
    local okt, why = notify_judge('telegram', { status = 400 }, { ok = false, description = 'chat not found' })
    check('Telegram gives its own reason', okt == false and why == 'chat not found', why)
    eq('a webhook 204 is delivered', (notify_judge('webhook', { status = 204 }, nil)), true)
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

-- ─────────────────────────────────────────────────────────────────────────────

local DATA = 'tmp/unit-data'

local function clean()
    for _, f in ipairs({ 'watchlist.json', 'alerts.json', 'state.json', 'stocks/600519.json',
                         'stocks/000001.json', 'stocks/609999.json' }) do
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
    test_alerts(evs)
    test_schedule()
    test_refresh_events()
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
