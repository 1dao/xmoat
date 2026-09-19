-- engine/quality.lua — is this a good business: multi-year series and summaries.
--
-- Exports: quality_build
--
-- Built from ANNUAL reports only. A single quarter says little about a
-- business, and mixing cumulative quarters with full years in one series is
-- the trap described in engine/fin.lua.
--
-- Which series and summaries apply depends on the template (the company type
-- the source reports). A bank has no gross margin and lives on leverage, so
-- the general template's lines would be meaningless or alarming for it.

local YEARS = 10

-- key, label, unit[, digits]. Units are for the client: '%' percent, 'x' a
-- plain ratio, 'CNY' yuan (the client scales to 亿). `digits` is a display hint
-- for the few lines that move in hundredths: an NPL ratio of 1.05% shown as
-- "1.1%" hides the change a reader is looking for.
local SERIES = {
    general = {
        { 'roe', 'ROE（加权）', '%' },
        { 'roic', 'ROIC', '%' },
        { 'gross_margin', '毛利率', '%' },
        { 'net_margin', '净利率', '%' },
        { 'ocf_to_np', '经营现金流 / 净利润', 'x' },
        { 'debt_ratio', '资产负债率', '%' },
        { 'revenue', '营业总收入', 'CNY' },
        { 'revenue_yoy', '营收同比', '%' },
        { 'np_parent', '归母净利润', 'CNY' },
        { 'np_parent_yoy', '归母净利润同比', '%' },
        { 'np_deducted', '扣非净利润', 'CNY' },
    },
    bank = {
        { 'roe', 'ROE（加权）', '%' },
        { 'npl_ratio', '不良贷款率', '%', 2 },
        { 'provision_coverage', '拨备覆盖率', '%' },
        { 'nim', '净息差', '%', 2 },
        { 'core_t1', '核心一级资本充足率', '%' },
        { 'car', '资本充足率', '%' },
        { 'revenue', '营业收入', 'CNY' },
        { 'revenue_yoy', '营收同比', '%' },
        { 'np_parent', '归母净利润', 'CNY' },
        { 'np_parent_yoy', '归母净利润同比', '%' },
    },
}
SERIES.insurance = {
    { 'roe', 'ROE（加权）', '%' },
    { 'solvency_ratio', '综合偿付能力充足率', '%' },
    { 'embedded_value', '内含价值', 'CNY' },
    { 'nbv', '新业务价值', 'CNY' },
    { 'nbv_rate', '新业务价值率', '%' },
    { 'net_investment_yield', '净投资收益率', '%', 2 },
    { 'surrender_rate', '退保率', '%', 2 },
    { 'earned_premium', '已赚保费', 'CNY' },
    { 'np_parent', '归母净利润', 'CNY' },
    { 'np_parent_yoy', '归母净利润同比', '%' },
}
SERIES.broker = {
    { 'roe', 'ROE（加权）', '%' },
    { 'net_capital', '净资本', 'CNY' },
    { 'net_capital_ratio', '净资本 / 净资产', '%' },
    { 'risk_coverage', '风险覆盖率', '%' },
    { 'capital_leverage', '资本杠杆率', '%' },
    { 'liquidity_coverage', '流动性覆盖率', '%' },
    { 'net_funding_ratio', '净稳定资金率', '%' },
    { 'proprietary_equity_ratio', '自营权益类证券 / 净资本', '%' },
    { 'revenue', '营业收入', 'CNY' },
    { 'revenue_yoy', '营收同比', '%' },
    { 'np_parent', '归母净利润', 'CNY' },
    { 'np_parent_yoy', '归母净利润同比', '%' },
}
-- A company type with no template of its own gets the lines every company has.
SERIES.other = {
    { 'roe', 'ROE（加权）', '%' },
    { 'revenue', '营业收入', 'CNY' },
    { 'revenue_yoy', '营收同比', '%' },
    { 'np_parent', '归母净利润', 'CNY' },
    { 'np_parent_yoy', '归母净利润同比', '%' },
}

local function column(annual, key)
    local out = {}
    for i, r in ipairs(annual) do out[i] = util_num(r[key]) or util_null end
    return out
end

-- The last k entries of an annual list.
local function tail(list, k)
    local out = {}
    for i = math.max(1, #list - k + 1), #list do out[#out + 1] = list[i] end
    return out
end

local function summary_item(key, label, unit, value, basis, digits)
    return { key = key, label = label, unit = unit, value = value, basis = basis, digits = digits }
end

-- Growth over the last up-to-five annual reports, stating how many years it
-- actually spans: a company with three years of history gets a 2-year CAGR
-- labelled as such, not a "5-year" one.
local function cagr_item(key, label, annual, field)
    local span = tail(annual, 6)
    if #span < 2 then return nil end
    local first, last = span[1], span[#span]
    local years = fin_year_of(last.period) - fin_year_of(first.period)
    local v = fin_cagr(first[field], last[field], years)
    return summary_item(key, string.format('%s（%d 年复合）', label, years), '%', v,
        first.period .. ' → ' .. last.period)
end

local function avg_item(key, label, unit, annual, field, k, fn)
    local span = tail(annual, k)
    if #span == 0 then return nil end
    local vals = column(span, field)
    return summary_item(key, string.format(label, #span), unit, (fn or fin_mean)(vals),
        span[1].period .. ' → ' .. span[#span].period)
end

local function range(vals)
    local lo, hi = fin_min(vals), fin_max(vals)
    if not lo then return nil end
    return hi - lo
end

-- template: 'general' | 'bank' | 'insurance' | 'broker' | 'other'
-- Returns { template, periods, notice_dates, series, summary }.
function g_exports.quality_build(reports, template)
    template = SERIES[template] and template or 'general'
    local annual = fin_annual(reports, YEARS)

    local periods, notices = {}, {}
    for i, r in ipairs(annual) do
        periods[i] = r.period
        notices[i] = r.notice_date or util_null
    end

    local series = {}
    for _, s in ipairs(SERIES[template]) do
        series[#series + 1] = { key = s[1], label = s[2], unit = s[3], digits = s[4],
                                values = util_json_array(column(annual, s[1])) }
    end

    local summary = {}
    local function add(item) if item then summary[#summary + 1] = item end end

    add(avg_item('roe_avg_5y', 'ROE 均值（近 %d 年）', '%', annual, 'roe', 5))
    add(avg_item('roe_min_5y', 'ROE 最低（近 %d 年）', '%', annual, 'roe', 5, fin_min))
    if template == 'general' then
        add(avg_item('roic_avg_5y', 'ROIC 均值（近 %d 年）', '%', annual, 'roic', 5))
        add(avg_item('gross_margin_avg_5y', '毛利率均值（近 %d 年）', '%', annual, 'gross_margin', 5))
        add(avg_item('gross_margin_range_5y', '毛利率波动幅度（近 %d 年，最高 − 最低）', 'pt',
            annual, 'gross_margin', 5, range))
        add(avg_item('ocf_to_np_avg_3y', '经营现金流 / 净利润 均值（近 %d 年）', 'x',
            annual, 'ocf_to_np', 3))
        add(cagr_item('revenue_cagr', '营收增速', annual, 'revenue'))
    elseif template == 'bank' then
        local latest = fin_latest(reports)
        if latest then
            local basis = latest.period
            add(summary_item('npl_ratio_latest', '不良贷款率（最新）', '%', util_num(latest.npl_ratio),
                basis, 2))
            add(summary_item('provision_coverage_latest', '拨备覆盖率（最新）', '%',
                util_num(latest.provision_coverage), basis))
            add(summary_item('core_t1_latest', '核心一级资本充足率（最新）', '%',
                util_num(latest.core_t1), basis))
        end
    elseif template == 'insurance' then
        local latest = fin_latest(reports)
        if latest then
            local basis = latest.period
            add(summary_item('solvency_latest', '综合偿付能力充足率（最新）', '%',
                util_num(latest.solvency_ratio), basis))
            add(summary_item('embedded_value_latest', '内含价值（最新）', 'CNY',
                util_num(latest.embedded_value), basis))
            add(summary_item('nbv_rate_latest', '新业务价值率（最新）', '%', util_num(latest.nbv_rate), basis))
        end
        -- New business value is what a life insurer sold this year, and the
        -- number the market follows; its trend belongs beside ROE.
        add(cagr_item('nbv_cagr', '新业务价值增速', annual, 'nbv'))
    elseif template == 'broker' then
        local latest = fin_latest(reports)
        if latest then
            local basis = latest.period
            add(summary_item('risk_coverage_latest', '风险覆盖率（最新）', '%',
                util_num(latest.risk_coverage), basis))
            add(summary_item('capital_leverage_latest', '资本杠杆率（最新）', '%',
                util_num(latest.capital_leverage), basis))
            add(summary_item('net_capital_ratio_latest', '净资本 / 净资产（最新）', '%',
                util_num(latest.net_capital_ratio), basis))
        end
    end
    add(cagr_item('np_cagr', '归母净利润增速', annual, 'np_parent'))

    local np_ttm, np_basis = fin_ttm(reports, 'np_parent')
    add(summary_item('np_parent_ttm', '归母净利润（TTM）', 'CNY', np_ttm, fin_ttm_basis(np_basis)))

    return {
        template = template,
        periods = util_json_array(periods),
        notice_dates = util_json_array(notices),
        series = series,
        summary = util_json_array(summary),
    }
end
