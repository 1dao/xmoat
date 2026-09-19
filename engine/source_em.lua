-- engine/source_em.lua — Eastmoney (东方财富) as a data source.
--
-- Exports: source_em_security,
--          source_em_parse_reports, source_em_parse_valuation,
--          source_em_parse_balance, source_em_parse_dividends, source_em_parse_business,
--          source_em_fetch_reports, source_em_fetch_valuation,
--          source_em_fetch_balance, source_em_fetch_dividends, source_em_fetch_business
--
-- Everything this file returns is in xmoat's own field names. Nothing outside
-- it knows that Eastmoney calls weighted ROE `ROEJQ`, so a second source
-- (Tushare, SEC EDGAR) only has to produce the same records, and the analysis
-- modules never change for it.
--
-- WHAT THESE ENDPOINTS ARE. Public JSON endpoints behind Eastmoney's own F10
-- and data-centre pages — the same ones AkShare reads. There is no documented
-- contract: fields can be renamed or an endpoint withdrawn without notice. The
-- parse_* functions are therefore separate from fetching, fed by recorded
-- responses in test/unit.lua, so a change in shape shows up as a failing test
-- rather than as silently empty analysis.
--
-- UNITS, which are not uniform and are easy to get wrong:
--   * money: yuan (元), as sent
--   * ROE, margins, debt ratio, growth rates: percent (15.2 means 15.2%)
--   * ocf_to_np, ocf_to_revenue: plain ratios (1.53 means 153%)
--   * per-share dividend: yuan per share. Eastmoney sends it per TEN shares
--     (PRETAX_BONUS_RMB, from "10派280.2423元"), divided here.
--   * flow items in a Q1/H1/Q3 report are year-to-date cumulative, not the
--     quarter alone. engine/fin.lua is where that is accounted for.

local DATACENTER = 'https://datacenter.eastmoney.com/securities/api/data/get'
local DATACENTER_WEB = 'https://datacenter-web.eastmoney.com/api/data/v1/get'
local F10 = 'https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/'

local num = util_num

local function str(v)
    if type(v) == 'string' and v ~= '' then return v end
    return nil
end

local function day(v)
    local s = str(v)
    return s and s:sub(1, 10) or nil
end

-- ---------------------------------------------------------------------------
-- Securities
-- ---------------------------------------------------------------------------

-- Accepts 600519, SH600519, sh600519, 600519.SH. Returns
--   { code = '600519', market = 'SH', secucode = '600519.SH', f10 = 'SH600519' }
-- or nil plus a message.
--
-- The exchange is derived from the code rather than looked up. That is exact
-- for A-share common stock, which is all this accepts: Shanghai 60/68, Shenzhen
-- 00/30, Beijing 43/83/87/88/92. Funds, bonds and B shares share those prefixes
-- with nothing and are refused rather than guessed at.
function g_exports.source_em_security(input)
    local s = util_str_trim(input):upper()
    local digits, mkt = s:match('^(%d%d%d%d%d%d)%.(%a%a)$')
    if not digits then
        mkt, digits = s:match('^(%a%a)(%d%d%d%d%d%d)$')
    end
    if not digits then digits = s:match('^(%d%d%d%d%d%d)$') end
    if not digits then return nil, '股票代码应为 6 位数字，例如 600519' end

    local p2 = digits:sub(1, 2)
    local derived
    if p2 == '60' or p2 == '68' then derived = 'SH'
    elseif p2 == '00' or p2 == '30' then derived = 'SZ'
    elseif p2 == '43' or p2 == '83' or p2 == '87' or p2 == '88' or p2 == '92' then derived = 'BJ'
    else
        return nil, '目前只支持 A 股个股（沪市 60/68、深市 00/30、北交所 43/83/87/88/92 开头）'
    end
    if mkt and mkt ~= derived then
        return nil, string.format('%s 属于 %s，不是 %s', digits, derived, mkt)
    end
    return { code = digits, market = derived,
             secucode = digits .. '.' .. derived, f10 = derived .. digits }
end

-- ---------------------------------------------------------------------------
-- Periodic reports: RPT_F10_FINANCE_MAINFINADATA ("主要指标", 按报告期)
-- ---------------------------------------------------------------------------

local ORG_TYPES = { ['通用'] = 'general', ['银行'] = 'bank',
                    ['保险'] = 'insurance', ['证券'] = 'broker' }

local PERIOD_TYPES = { ['03-31'] = 'Q1', ['06-30'] = 'H1', ['09-30'] = 'Q3', ['12-31'] = 'FY' }

-- em field -> xmoat field. Only numbers are copied; see UNITS above.
local REPORT_FIELDS = {
    EPSJB = 'eps', BPS = 'bps', MGJYXJJE = 'ocfps',
    TOTALOPERATEREVE = 'revenue', MLR = 'gross_profit',
    PARENTNETPROFIT = 'np_parent', KCFJCXSYJLR = 'np_deducted',
    TOTALOPERATEREVETZ = 'revenue_yoy', PARENTNETPROFITTZ = 'np_parent_yoy',
    KCFJCXSYJLRTZ = 'np_deducted_yoy',
    ROEJQ = 'roe', ROEKCJQ = 'roe_deducted', ZZCJLL = 'roa', ROIC = 'roic',
    XSMLL = 'gross_margin', XSJLL = 'net_margin',
    JYXJLYYSR = 'ocf_to_revenue', NCO_NETPROFIT = 'ocf_to_np',
    ZCFZL = 'debt_ratio', LD = 'current_ratio', SD = 'quick_ratio',
    YSZKZZTS = 'receivable_days', CHZZTS = 'inventory_days',
    -- banks
    NONPERLOAN = 'npl_ratio', BLDKBBL = 'provision_coverage',
    NET_INTEREST_MARGIN = 'nim', NEWCAPITALADER = 'car', HXYJBCZL = 'core_t1',
    LOAN_PROVISION_RATIO = 'loan_provision_ratio',
    -- insurers. Solvency and embedded value are point-in-time; the premium,
    -- the new business value and the yields are flows, cumulative in an
    -- interim report like every other flow item here.
    SOLVENCY_AR = 'solvency_ratio', NHJZ_CURRENT_AMT = 'embedded_value',
    NBV_LIFE = 'nbv', NBV_RATE = 'nbv_rate',
    EARNED_PREMIUM = 'earned_premium', COMPENSATE_EXPENSE = 'claims_expense',
    SURRENDER_RATE_LIFE = 'surrender_rate',
    NET_ROI = 'net_investment_yield', TOTAL_ROI = 'total_investment_yield',
    -- brokers. All of these are the regulator's own risk-control ratios
    -- (《证券公司风险控制指标管理办法》), reported point-in-time.
    JZB = 'net_capital', JZC = 'net_assets', JZBJZC = 'net_capital_ratio',
    RISK_COVERAGE = 'risk_coverage', CAPITAL_LEVERAGE_RATIO = 'capital_leverage',
    LIQUIDITY_COVERAGE_RATIO = 'liquidity_coverage', NET_FUNDING_RATIO = 'net_funding_ratio',
    NET_CAPITAL_LIABILITIES = 'net_capital_to_liabilities',
    NET_ASSETS_LIABILITIES = 'net_assets_to_liabilities',
    PROPRIETARY_CAPITAL = 'proprietary_equity_ratio',
    ZYGDSYLZQJZB = 'proprietary_fixed_income_ratio',
}

-- Parse one response document. Returns
--   { name, org_type, reports = { newest first } }
-- or nil plus a message.
function g_exports.source_em_parse_reports(doc)
    -- A code with no data answers {"result": null}, not an error status.
    if type(doc) == 'table' and doc.result == util_null then return { reports = {} } end
    local rows = type(doc) == 'table' and type(doc.result) == 'table' and doc.result.data
    if type(rows) ~= 'table' then
        return nil, 'unexpected response shape (no result.data)'
    end
    local out, name, org_type = {}, nil, nil
    for _, row in ipairs(rows) do
        local period = day(row.REPORT_DATE)
        local ptype = period and PERIOD_TYPES[period:sub(6, 10)]
        if ptype then
            local rec = {
                period = period,
                period_type = ptype,
                notice_date = day(row.NOTICE_DATE),
                update_date = day(row.UPDATE_DATE),
                report_name = str(row.REPORT_DATE_NAME),
                currency = str(row.CURRENCY),
            }
            for from, to in pairs(REPORT_FIELDS) do rec[to] = num(row[from]) end
            out[#out + 1] = rec
            name = name or str(row.SECURITY_NAME_ABBR)
            org_type = org_type or ORG_TYPES[str(row.ORG_TYPE) or ''] or
                       (str(row.ORG_TYPE) and 'other') or nil
        end
    end
    table.sort(out, function(a, b) return a.period > b.period end)
    return { name = name, org_type = org_type, reports = out }
end

function g_exports.source_em_fetch_reports(sec, limit)
    local url = DATACENTER .. '?type=RPT_F10_FINANCE_MAINFINADATA&sty=APP_F10_MAINFINADATA' ..
        '&quoteColumns=&filter=(SECUCODE=%22' .. sec.secucode .. '%22)' ..
        '&p=1&ps=' .. tostring(limit or 200) .. '&sr=-1&st=REPORT_DATE&source=HSF10&client=PC'
    local doc, err = net_get_json(url, { timeout_ms = (limit or 200) > 20 and 60000 or nil })
    if not doc then return nil, err end
    return source_em_parse_reports(doc)
end

-- ---------------------------------------------------------------------------
-- Daily valuation: RPT_VALUEANALYSIS_DET ("估值分析")
--
-- Eastmoney computes PE(TTM), PB(MRQ), PS(TTM) and PCF(TTM) itself. Using
-- theirs rather than recomputing from price and reports is deliberate for the
-- history: recomputing needs every report as it stood on each past day, and a
-- single restatement would otherwise leak future numbers into old dates.
-- ---------------------------------------------------------------------------

function g_exports.source_em_parse_valuation(doc)
    if type(doc) == 'table' and doc.result == util_null then return { rows = {} } end
    local rows = type(doc) == 'table' and type(doc.result) == 'table' and doc.result.data
    if type(rows) ~= 'table' then
        return nil, 'unexpected response shape (no result.data)'
    end
    local out, name, industry = {}, nil, nil
    for _, row in ipairs(rows) do
        local date = day(row.TRADE_DATE)
        if date then
            out[#out + 1] = {
                date = date,
                close = num(row.CLOSE_PRICE),
                pe_ttm = num(row.PE_TTM),
                pe_static = num(row.PE_LAR),
                pb = num(row.PB_MRQ),
                ps_ttm = num(row.PS_TTM),
                pcf_ttm = num(row.PCF_OCF_TTM),
                market_cap = num(row.TOTAL_MARKET_CAP),
                shares = num(row.TOTAL_SHARES),
            }
            name = name or str(row.SECURITY_NAME_ABBR)
            industry = industry or str(row.BOARD_NAME)
        end
    end
    table.sort(out, function(a, b) return a.date < b.date end)
    return { name = name, industry = industry, rows = out }
end

-- `limit` trading days, newest first on the wire, returned oldest first.
function g_exports.source_em_fetch_valuation(sec, limit)
    local url = DATACENTER_WEB .. '?sortColumns=TRADE_DATE&sortTypes=-1' ..
        '&pageSize=' .. tostring(limit or 5000) .. '&pageNumber=1' ..
        '&reportName=RPT_VALUEANALYSIS_DET&columns=ALL&quoteColumns=&source=WEB&client=WEB' ..
        '&filter=(SECURITY_CODE=%22' .. sec.code .. '%22)'
    -- The full history is over a megabyte, and this endpoint has been measured
    -- taking most of a minute to send it when busy. A first fetch gets the time
    -- it needs; an incremental one keeps the default.
    local doc, err = net_get_json(url, { timeout_ms = (limit or 5000) > 500 and 120000 or nil })
    if not doc then return nil, err end
    return source_em_parse_valuation(doc)
end

-- ---------------------------------------------------------------------------
-- Balance sheet: F10 zcfzbAjaxNew ("资产负债表", 按报告期)
--
-- Only for general companies (companyType=4). A bank's balance sheet is a
-- different statement with different items, and asking with the wrong type
-- answers a stub object rather than an error — see parse below.
-- ---------------------------------------------------------------------------

local BALANCE_FIELDS = {
    MONETARYFUNDS = 'cash', ACCOUNTS_RECE = 'receivables',
    NOTE_ACCOUNTS_RECE = 'notes_and_receivables', INVENTORY = 'inventory',
    GOODWILL = 'goodwill', TOTAL_ASSETS = 'total_assets',
    TOTAL_LIABILITIES = 'total_liabilities', TOTAL_PARENT_EQUITY = 'equity_parent',
    SHORT_LOAN = 'short_loan', LONG_LOAN = 'long_loan', BOND_PAYABLE = 'bonds_payable',
    NONCURRENT_LIAB_1YEAR = 'noncurrent_liab_1y', LEASE_LIAB = 'lease_liab',
    CONTRACT_LIAB = 'contract_liab', ADVANCE_RECEIVABLES = 'advance_receipts',
}

function g_exports.source_em_parse_balance(doc)
    if type(doc) ~= 'table' or type(doc.data) ~= 'table' then
        return nil, 'unexpected response shape (no data)'
    end
    local out = {}
    for _, row in ipairs(doc.data) do
        local period = day(row.REPORT_DATE)
        if period then
            local rec = { period = period, notice_date = day(row.NOTICE_DATE) }
            for from, to in pairs(BALANCE_FIELDS) do rec[to] = num(row[from]) end
            out[#out + 1] = rec
        end
    end
    table.sort(out, function(a, b) return a.period > b.period end)
    return out
end

-- `periods` is a list of 'YYYY-MM-DD'. The endpoint takes at most five dates
-- per call, so a longer list is split.
function g_exports.source_em_fetch_balance(sec, periods)
    local out = {}
    for i = 1, #periods, 5 do
        local batch = {}
        for j = i, math.min(i + 4, #periods) do batch[#batch + 1] = periods[j] end
        local url = F10 .. 'zcfzbAjaxNew?companyType=4&reportDateType=0&reportType=1' ..
            '&dates=' .. table.concat(batch, ',') .. '&code=' .. sec.f10
        local doc, err = net_get_json(url)
        if not doc then return nil, err end
        local rows, perr = source_em_parse_balance(doc)
        if not rows then return nil, perr end
        for _, r in ipairs(rows) do out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.period > b.period end)
    return out
end

-- ---------------------------------------------------------------------------
-- The whole market, in two snapshots
--
-- A screener cannot fetch five and a half thousand stocks one at a time, so it
-- reads two market-wide tables instead:
--
--   RPT_VALUEANALYSIS_DET filtered by one TRADE_DATE — the same daily valuation
--       table a single stock's history comes from, sliced across the market
--       instead of across time. 2000 rows per page.
--   RPT_LICO_FN_CPD filtered by one REPORTDATE — every A-share's headline
--       figures for that period (ROE, revenue, profit, their growth, gross
--       margin, per-share cash flow). 500 rows per page, whatever is asked.
--
-- Both are paged by the caller; engine/market.lua does the paging and the
-- pacing. What is NOT here: dividends, which have no market-wide table, so a
-- screen cannot filter on yield.
-- ---------------------------------------------------------------------------

local MARKET_VAL_COLUMNS = 'SECURITY_CODE,SECURITY_NAME_ABBR,BOARD_NAME,TOTAL_MARKET_CAP,' ..
    'CLOSE_PRICE,PE_TTM,PB_MRQ,PS_TTM,PCF_OCF_TTM'

local function paged(doc)
    local result = type(doc) == 'table' and type(doc.result) == 'table' and doc.result
    if not result or type(result.data) ~= 'table' then return nil end
    return result
end

-- Returns { rows, count, pages } or nil plus a message.
function g_exports.source_em_parse_market_valuation(doc)
    if type(doc) == 'table' and doc.result == util_null then
        return { rows = {}, count = 0, pages = 0 }
    end
    local result = paged(doc)
    if not result then return nil, 'unexpected response shape (no result.data)' end
    local rows = {}
    for _, row in ipairs(result.data) do
        local code = str(row.SECURITY_CODE)
        if code then
            rows[#rows + 1] = {
                code = code, name = str(row.SECURITY_NAME_ABBR), industry = str(row.BOARD_NAME),
                market_cap = num(row.TOTAL_MARKET_CAP), close = num(row.CLOSE_PRICE),
                pe_ttm = num(row.PE_TTM), pb = num(row.PB_MRQ),
                ps_ttm = num(row.PS_TTM), pcf_ttm = num(row.PCF_OCF_TTM),
            }
        end
    end
    return { rows = rows, count = num(result.count) or #rows, pages = num(result.pages) or 1 }
end

-- The newest trading day the valuation table carries, as 'YYYY-MM-DD'.
function g_exports.source_em_fetch_trade_date()
    local url = DATACENTER_WEB .. '?sortColumns=TRADE_DATE&sortTypes=-1&pageSize=1&pageNumber=1' ..
        '&reportName=RPT_VALUEANALYSIS_DET&columns=TRADE_DATE&source=WEB&client=WEB'
    local doc, err = net_get_json(url)
    if not doc then return nil, err end
    local result = paged(doc)
    local row = result and result.data[1]
    local date = row and day(row.TRADE_DATE)
    if not date then return nil, '无法确定最新交易日' end
    return date
end

function g_exports.source_em_fetch_market_valuation(date, page, page_size)
    local url = DATACENTER_WEB .. '?sortColumns=SECURITY_CODE&sortTypes=1' ..
        '&pageSize=' .. tostring(page_size or 2000) .. '&pageNumber=' .. tostring(page or 1) ..
        '&reportName=RPT_VALUEANALYSIS_DET&columns=' .. MARKET_VAL_COLUMNS ..
        '&quoteColumns=&source=WEB&client=WEB&filter=(TRADE_DATE%3D%27' .. date .. '%27)'
    local doc, err = net_get_json(url, { timeout_ms = 60000 })
    if not doc then return nil, err end
    return source_em_parse_market_valuation(doc)
end

local MARKET_FIN_COLUMNS = 'SECURITY_CODE,SECURITY_NAME_ABBR,WEIGHTAVG_ROE,TOTAL_OPERATE_INCOME,' ..
    'PARENT_NETPROFIT,YSTZ,SJLTZ,XSMLL,BASIC_EPS,DEDUCT_BASIC_EPS,BPS,MGJYXJJE,NOTICE_DATE'

function g_exports.source_em_parse_market_reports(doc)
    if type(doc) == 'table' and doc.result == util_null then
        return { rows = {}, count = 0, pages = 0 }
    end
    local result = paged(doc)
    if not result then return nil, 'unexpected response shape (no result.data)' end
    local rows = {}
    for _, row in ipairs(result.data) do
        local code = str(row.SECURITY_CODE)
        if code then
            rows[#rows + 1] = {
                code = code, name = str(row.SECURITY_NAME_ABBR),
                roe = num(row.WEIGHTAVG_ROE),                 -- weighted, as everywhere else
                revenue = num(row.TOTAL_OPERATE_INCOME), np_parent = num(row.PARENT_NETPROFIT),
                revenue_yoy = num(row.YSTZ), np_parent_yoy = num(row.SJLTZ),
                gross_margin = num(row.XSMLL),
                eps = num(row.BASIC_EPS), eps_deducted = num(row.DEDUCT_BASIC_EPS),
                bps = num(row.BPS), ocfps = num(row.MGJYXJJE),
                notice_date = day(row.NOTICE_DATE),
            }
        end
    end
    return { rows = rows, count = num(result.count) or #rows, pages = num(result.pages) or 1 }
end

-- `period` is a report date, 'YYYY-12-31' for an annual one. A shares only
-- (SECURITY_TYPE_CODE 058001001); the table also carries B shares.
function g_exports.source_em_fetch_market_reports(period, page, page_size)
    local url = DATACENTER_WEB .. '?sortColumns=SECURITY_CODE&sortTypes=1' ..
        '&pageSize=' .. tostring(page_size or 500) .. '&pageNumber=' .. tostring(page or 1) ..
        '&reportName=RPT_LICO_FN_CPD&columns=' .. MARKET_FIN_COLUMNS ..
        '&filter=(REPORTDATE%3D%27' .. period .. '%27)(SECURITY_TYPE_CODE%3D%22058001001%22)' ..
        '&source=DataCenter&client=WEB'
    local doc, err = net_get_json(url, { timeout_ms = 60000 })
    if not doc then return nil, err end
    return source_em_parse_market_reports(doc)
end

-- ---------------------------------------------------------------------------
-- Business: F10 BusinessAnalysis/PageAjax ("经营分析")
--
-- Three things in one response:
--   zyfw    business scope, as registered
--   zygcfx  revenue, cost, profit and gross margin by industry / product /
--           region, per report period. Numbers arrive as STRINGS here, and the
--           ratios as fractions (0.8569), unlike the percent everywhere else.
--   jyps    the management's business review for the latest report only: the
--           text the model reads. Older ones are kept by engine/stock.lua as
--           they are fetched, since this endpoint forgets them.
-- ---------------------------------------------------------------------------

local SEGMENT_KINDS = { ['1'] = 'industry', ['2'] = 'product', ['3'] = 'region' }

local function strnum(v)
    if type(v) == 'number' then return num(v) end
    if type(v) == 'string' and v ~= '' then return num(tonumber(v)) end
    return nil
end

local function pct_of(v)
    local x = strnum(v)
    return x and x * 100 or nil
end

-- Returns { scope, review = {period, text} | nil, segments = { ... } } or nil
-- plus a message.
function g_exports.source_em_parse_business(doc)
    if type(doc) ~= 'table' or (doc.zygcfx == nil and doc.jyps == nil and doc.zyfw == nil) then
        return nil, 'unexpected response shape (no zygcfx/jyps/zyfw)'
    end
    local out = { segments = {} }
    local scope = type(doc.zyfw) == 'table' and doc.zyfw[1]
    out.scope = scope and str(scope.BUSINESS_SCOPE) or nil

    local review = type(doc.jyps) == 'table' and doc.jyps[1]
    if review and str(review.BUSINESS_REVIEW) and day(review.REPORT_DATE) then
        out.review = { period = day(review.REPORT_DATE), text = review.BUSINESS_REVIEW }
    end

    for _, row in ipairs(type(doc.zygcfx) == 'table' and doc.zygcfx or {}) do
        local period = day(row.REPORT_DATE)
        local kind = SEGMENT_KINDS[tostring(row.MAINOP_TYPE)]
        local name = str(row.ITEM_NAME)
        if period and kind and name then
            out.segments[#out.segments + 1] = {
                period = period, kind = kind, name = name,
                revenue = strnum(row.MAIN_BUSINESS_INCOME),
                revenue_share = pct_of(row.MBI_RATIO),
                cost = strnum(row.MAIN_BUSINESS_COST),
                profit = strnum(row.MAIN_BUSINESS_RPOFIT),     -- sic, the source's spelling
                gross_margin = pct_of(row.GROSS_RPOFIT_RATIO),
                rank = strnum(row.RANK),
            }
        end
    end
    return out
end

function g_exports.source_em_fetch_business(sec)
    local url = 'https://emweb.securities.eastmoney.com/PC_HSF10/BusinessAnalysis/PageAjax?code=' .. sec.f10
    local doc, err = net_get_json(url)
    if not doc then return nil, err end
    return source_em_parse_business(doc)
end

-- ---------------------------------------------------------------------------
-- Dividends: RPT_SHAREBONUS_DET ("分红送配")
-- ---------------------------------------------------------------------------

function g_exports.source_em_parse_dividends(doc)
    -- A company that has never paid answers {"result": null}.
    if type(doc) == 'table' and doc.result == util_null then return {} end
    local rows = type(doc) == 'table' and type(doc.result) == 'table' and doc.result.data
    if type(rows) ~= 'table' then
        return nil, 'unexpected response shape (no result.data)'
    end
    local out = {}
    for _, row in ipairs(rows) do
        local period = day(row.REPORT_DATE)
        if period then
            local per10 = num(row.PRETAX_BONUS_RMB)
            out[#out + 1] = {
                period = period,
                progress = str(row.ASSIGN_PROGRESS),
                plan = str(row.IMPL_PLAN_PROFILE),
                dps = per10 and per10 / 10 or nil,
                notice_date = day(row.NOTICE_DATE),
                plan_notice_date = day(row.PLAN_NOTICE_DATE),
                record_date = day(row.EQUITY_RECORD_DATE),
                ex_date = day(row.EX_DIVIDEND_DATE),
                bonus_ratio = num(row.BONUS_RATIO),        -- 送股, per 10 shares
                transfer_ratio = num(row.IT_RATIO),        -- 转增, per 10 shares
            }
        end
    end
    table.sort(out, function(a, b) return a.period > b.period end)
    return out
end

function g_exports.source_em_fetch_dividends(sec)
    local url = DATACENTER_WEB .. '?sortColumns=REPORT_DATE&sortTypes=-1&pageSize=500&pageNumber=1' ..
        '&reportName=RPT_SHAREBONUS_DET&columns=ALL&quoteColumns=&source=WEB&client=WEB' ..
        '&filter=(SECURITY_CODE=%22' .. sec.code .. '%22)'
    local doc, err = net_get_json(url)
    if not doc then return nil, err end
    return source_em_parse_dividends(doc)
end
