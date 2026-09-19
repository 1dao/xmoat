-- engine/analysis.lua — one stock's stored data, turned into the analysis object.
--
-- Exports: analysis_build, analysis_schema
--
-- The analysis object is THE contract between the engine and every client:
-- the web page, the CLI's Markdown, and later a phone app all render this one
-- structure, and none of them computes a financial number of its own. Its
-- shape is documented in docs/API.md; a change to it is a change to that
-- document, and a bump of analysis_schema when an existing field changes
-- meaning.
--
-- Recomputed on every read from the stored source data rather than stored
-- itself. It costs milliseconds, and it means a corrected formula applies to
-- every stock at once instead of only to the ones fetched after the fix.

g_exports.analysis_schema = 1

local TEMPLATE_NOTES = {
    insurance = '保险公司的专项指标（内含价值、新业务价值、偿付能力）尚未实现，这里只展示通用指标和估值。',
    broker = '证券公司的专项指标（净资本、风险覆盖率、自营占比）尚未实现，这里只展示通用指标和估值。',
    other = '该公司类型没有专门的指标模板，这里只展示通用指标和估值。',
    bank = '银行杠杆经营，资产负债率等通用指标不适用；估值上 PB 通常比 PE 更有参考意义。' ..
           '银行的经营现金流包含存贷款变动，PCF 对银行没有意义。',
}

-- Presentation rounding, applied once to the finished object. Stored source
-- data is never rounded, so this only ever loses digits nobody reads.
local function round_floats(v)
    if type(v) == 'table' then
        for k, x in pairs(v) do v[k] = round_floats(x) end
        return v
    end
    if math.type(v) == 'float' then
        local r = util_round(v, 4)
        return r
    end
    return v
end

local function percentile_view(p)
    if not p then return nil end
    return { percentile = p.percentile, n = p.n, from = p.from, to = p.to,
             min = p.min, median = p.median, max = p.max }
end

local function build_valuation(data, watch, opts)
    local rows = data.valuation or {}
    local latest = valuation_latest(rows)
    if not latest then return nil end

    local metrics = {}
    for _, m in ipairs(valuation_metrics(rows)) do
        metrics[#metrics + 1] = {
            key = m.key, label = m.label, value = m.value,
            all = percentile_view(m.all), all_note = m.all_note,
            y5 = percentile_view(m.y5), y5_note = m.y5_note,
        }
    end

    local div = dividend_ttm(data.dividends, latest.date, latest.close)

    local np_ttm, np_basis = fin_ttm(data.reports, 'np_parent')
    local dcf, dcf_err = valuation_reverse_dcf(np_ttm, latest.market_cap, opts.dcf)
    local reverse_dcf
    if dcf then
        reverse_dcf = {
            implied_growth = dcf.implied_growth, bound = dcf.bound,
            discount_rate = dcf.discount_rate, terminal_growth = dcf.terminal_growth,
            years = dcf.years, earnings = dcf.earnings, market_cap = dcf.market_cap,
            earnings_label = '归母净利润（TTM）', earnings_basis = fin_ttm_basis(np_basis),
            note = '以归母净利润近似股东盈余。需要大量再投资才能增长的公司，真实可分配现金更少，' ..
                   '隐含增长率应看作下限。',
        }
    else
        reverse_dcf = { error = dcf_err or fin_ttm_basis(np_basis) }
    end

    return {
        date = latest.date, close = latest.close,
        market_cap = latest.market_cap, shares = latest.shares,
        metrics = util_json_array(metrics),
        dividend = {
            dps_ttm = div.dps, yield_ttm = div.yield, from = div.from, to = div.to,
            events = util_json_array(div.events),
        },
        reverse_dcf = reverse_dcf,
        band = watch and valuation_band(rows, watch.band) or nil,
    }
end

local function build_dividends(data)
    local d = dividend_years(data.dividends, data.reports)
    local pending = {}
    for _, ev in ipairs(data.dividends or {}) do
        if dividend_counts(ev) and not ev.ex_date then
            pending[#pending + 1] = { period = ev.period, progress = ev.progress,
                                      plan = ev.plan, dps = ev.dps }
        end
    end
    local years = {}
    for i = 1, math.min(#d.years, 10) do years[i] = d.years[i] end
    return {
        consecutive_years = d.consecutive_years,
        latest_fy = d.latest_fy,
        years = util_json_array(years),
        pending = util_json_array(pending),
    }
end

-- Revenue by product, region and industry from the latest ANNUAL report, with
-- each line's change in share against the year before — computed here, so the
-- model reading this later is handed the change rather than asked to work it
-- out. Interim breakdowns are skipped: a half-year mix is seasonal.
local function build_business(data)
    local b = data.business
    if type(b) ~= 'table' then return nil end
    local segments = type(b.segments) == 'table' and b.segments or {}

    local latest
    for _, s in ipairs(segments) do
        if s.period:sub(6) == '12-31' and (not latest or s.period > latest) then latest = s.period end
    end
    local previous = latest and string.format('%04d-12-31', fin_year_of(latest) - 1) or nil

    local prev_share = {}
    for _, s in ipairs(segments) do
        if s.period == previous then prev_share[s.kind .. '|' .. s.name] = util_num(s.revenue_share) end
    end

    local by = { product = {}, region = {}, industry = {} }
    local has_previous = false
    for _, s in ipairs(segments) do
        if s.period == latest and by[s.kind] then
            local before = prev_share[s.kind .. '|' .. s.name]
            if before then has_previous = true end
            local share = util_num(s.revenue_share)
            local list = by[s.kind]
            list[#list + 1] = {
                name = s.name, revenue = s.revenue, revenue_share = share,
                gross_margin = s.gross_margin,
                share_change = (share and before) and (share - before) or nil,
            }
        end
    end
    for k, list in pairs(by) do
        table.sort(list, function(x, y) return (x.revenue or 0) > (y.revenue or 0) end)
        by[k] = util_json_array(list)
    end

    local review = type(b.reviews) == 'table' and b.reviews[1] or nil
    return {
        scope = b.scope,
        period = latest,
        previous_period = has_previous and previous or nil,
        by = by,
        review = review and { period = review.period, chars = utf8.len(review.text) or #review.text } or nil,
        reviews = util_json_array((function()
            local out = {}
            for _, r in ipairs(type(b.reviews) == 'table' and b.reviews or {}) do out[#out + 1] = r.period end
            return out
        end)()),
    }
end

-- data:  the stored stock record (engine/stock.lua)
-- watch: the watchlist entry, or nil
-- opts:  { dcf = { discount_rate, terminal_growth, years } }
function g_exports.analysis_build(data, watch, opts)
    opts = opts or {}
    local template = data.org_type or 'general'
    local latest = fin_latest(data.reports)

    local notes = {}
    if TEMPLATE_NOTES[template] then notes[#notes + 1] = TEMPLATE_NOTES[template] end
    if not latest then notes[#notes + 1] = '没有取到定期报告数据。' end

    local out = {
        schema = analysis_schema,
        code = data.code, market = data.market, name = data.name,
        industry = data.industry, template = template,
        fetched_at = data.fetched_at,
        latest_report = latest and {
            period = latest.period, period_type = latest.period_type,
            name = latest.report_name, notice_date = latest.notice_date,
        } or nil,
        valuation = build_valuation(data, watch, opts),
        quality = quality_build(data.reports or {}, template),
        dividends = build_dividends(data),
        checks = checks_build(data.reports or {}, data.balance or {}, template),
        business = build_business(data),
        -- Copied: round_floats works in place, and these belong to the store.
        watch = watch and { note = watch.note, added_at = watch.added_at,
                            band = watch.band and util_copy(watch.band) or nil } or nil,
        notes = util_json_array(notes),
        sources = util_json_array(data.sources or {}),
    }
    return round_floats(out)
end
