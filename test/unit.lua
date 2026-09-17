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

-- ─────────────────────────────────────────────────────────────────────────────

local DATA = 'tmp/unit-data'

local function clean()
    for _, f in ipairs({ 'watchlist.json', 'stocks/600519.json', 'stocks/000001.json',
                         'stocks/609999.json' }) do
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
