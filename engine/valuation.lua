-- engine/valuation.lua — how expensive a stock is, against its own history.
--
-- Exports: valuation_latest, valuation_percentile, valuation_quantile, valuation_metrics,
--          valuation_reverse_dcf, valuation_band, valuation_band_metrics
--
-- Pure functions over the daily rows a source produces (oldest first):
--   { date, close, pe_ttm, pb, ps_ttm, pcf_ttm, market_cap, ... }

local FIELDS = {
    { key = 'pe_ttm',  label = 'PE（TTM）' },
    { key = 'pb',      label = 'PB（MRQ）' },
    { key = 'ps_ttm',  label = 'PS（TTM）' },
    { key = 'pcf_ttm', label = 'PCF（经营现金流 TTM）' },
}

-- Fewer points than this and a percentile says more about the sample than the
-- stock: a company listed six months ago is "at its 90th percentile" of almost
-- nothing. About one year of trading days.
local MIN_POINTS = 240

-- The newest row that has a price. The last row can be a holiday placeholder.
function g_exports.valuation_latest(rows)
    for i = #(rows or {}), 1, -1 do
        if util_num(rows[i].close) then return rows[i] end
    end
    return nil
end

-- Where the latest value of `field` sits in its history since `since` (a date,
-- or nil for everything). Returns
--   { value, percentile, n, from, to, min, median, max }
-- or nil plus a reason.
--
-- Only positive values count, on both sides. A negative PE is a loss, not a
-- cheap price, and letting loss years into the history would make any
-- profitable year look expensive by comparison.
--
-- The percentile is the share of the window strictly below the current value
-- plus half of the ties, so a value equal to every point is the 50th, not the
-- 0th or the 100th.
function g_exports.valuation_percentile(rows, field, since)
    local latest = valuation_latest(rows)
    if not latest then return nil, '没有估值数据' end
    local current = util_num(latest[field])
    if not current then return nil, '最新交易日没有该指标' end
    if current <= 0 then return nil, '当前值为负（亏损或净资产为负），分位没有意义' end

    local vals, from = {}, nil
    for _, r in ipairs(rows) do
        local v = util_num(r[field])
        if v and v > 0 and (not since or r.date >= since) and r.date <= latest.date then
            vals[#vals + 1] = v
            from = from or r.date
        end
    end
    if #vals < MIN_POINTS then
        return nil, string.format('样本只有 %d 个交易日，不足 %d 个', #vals, MIN_POINTS)
    end

    local below, equal = 0, 0
    for _, v in ipairs(vals) do
        if v < current then below = below + 1
        elseif v == current then equal = equal + 1 end
    end
    return {
        value = current,
        percentile = (below + equal / 2) / #vals * 100,
        n = #vals, from = from, to = latest.date,
        min = fin_min(vals), median = fin_median(vals), max = fin_max(vals),
    }
end

-- The value of `field` at percentile `p` (0-100) of its own history: the
-- inverse of valuation_percentile, and the reason engine/levels.lua can turn
-- "the 25th percentile" into a price. Same window and same filtering, so the
-- two always speak about the same sample. Returns the value or nil plus a
-- reason.
function g_exports.valuation_quantile(rows, field, p, since)
    local latest = valuation_latest(rows)
    if not latest then return nil, '没有估值数据' end
    local vals = {}
    for _, r in ipairs(rows) do
        local v = util_num(r[field])
        if v and v > 0 and (not since or r.date >= since) and r.date <= latest.date then
            vals[#vals + 1] = v
        end
    end
    if #vals < MIN_POINTS then
        return nil, string.format('样本只有 %d 个交易日，不足 %d 个', #vals, MIN_POINTS)
    end
    table.sort(vals)
    -- Linear interpolation between the two neighbouring points, so a
    -- percentile between samples does not jump.
    local pos = math.max(0, math.min(100, p)) / 100 * (#vals - 1) + 1
    local lo = math.floor(pos)
    local hi = math.min(#vals, lo + 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (pos - lo)
end

-- Every metric, each over the whole history and over the last five years.
function g_exports.valuation_metrics(rows)
    local latest = valuation_latest(rows)
    if not latest then return {} end
    local five_years_ago = util_date_add_days(latest.date, -365 * 5 - 1)
    local out = {}
    for _, f in ipairs(FIELDS) do
        local all, all_err = valuation_percentile(rows, f.key, nil)
        local y5, y5_err = valuation_percentile(rows, f.key, five_years_ago)
        out[#out + 1] = {
            key = f.key, label = f.label,
            value = util_num(latest[f.key]),
            all = all, all_note = all_err,
            y5 = y5, y5_note = y5_err,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Reverse DCF
--
-- A DCF asks "given a growth rate, what is it worth". Every input to that is a
-- guess, and the guess about growth dominates the answer. Turned around, the
-- question has one guess fewer: given today's price, what growth is the market
-- already paying for? Whether that growth is plausible is then a question about
-- the business, which is the question worth thinking about.
--
-- Model, all rates per year:
--   value(g) = sum_{t=1..n} E(1+g)^t / (1+r)^t
--            + E(1+g)^n (1+tg) / (r - tg) / (1+r)^n
-- solved for value(g) = market cap by bisection; value is increasing in g.
--
-- E is what the caller passes — engine/analysis.lua uses parent net profit
-- (TTM) as a stand-in for owner earnings, and says so in its output. That
-- overstates what an owner can take out of a business that must reinvest
-- heavily to grow, which is a reason to read the implied growth as a floor.
-- ---------------------------------------------------------------------------

local G_LOW, G_HIGH = -0.5, 1.0

local function dcf_value(e, g, r, tg, n)
    local v, grown, disc = 0, e, 1
    for _ = 1, n do
        grown = grown * (1 + g)
        disc = disc * (1 + r)
        v = v + grown / disc
    end
    return v + grown * (1 + tg) / (r - tg) / disc
end

-- params: { discount_rate = 10, terminal_growth = 3, years = 10 } in percent.
-- Returns { implied_growth (percent), bound = nil|'below'|'above', ... } or
-- nil plus a reason.
function g_exports.valuation_reverse_dcf(earnings, market_cap, params)
    earnings, market_cap = util_num(earnings), util_num(market_cap)
    params = params or {}
    local r = (params.discount_rate or 10) / 100
    local tg = (params.terminal_growth or 3) / 100
    local n = params.years or 10
    if not earnings or earnings <= 0 then return nil, '盈利为负或缺失，无法反推增长率' end
    if not market_cap or market_cap <= 0 then return nil, '缺少市值' end
    if r <= tg then return nil, '折现率必须大于永续增长率' end

    local result = { discount_rate = r * 100, terminal_growth = tg * 100, years = n,
                     earnings = earnings, market_cap = market_cap }
    if market_cap <= dcf_value(earnings, G_LOW, r, tg, n) then
        result.implied_growth, result.bound = G_LOW * 100, 'below'
        return result
    end
    if market_cap >= dcf_value(earnings, G_HIGH, r, tg, n) then
        result.implied_growth, result.bound = G_HIGH * 100, 'above'
        return result
    end
    local lo, hi = G_LOW, G_HIGH
    for _ = 1, 100 do
        local mid = (lo + hi) / 2
        if dcf_value(earnings, mid, r, tg, n) < market_cap then lo = mid else hi = mid end
        if hi - lo < 1e-7 then break end
    end
    result.implied_growth = (lo + hi) / 2 * 100
    return result
end

-- The user's own fair-value band for one metric. band = { metric, low, high }.
-- Returns { metric, low, high, value, position = 'below'|'inside'|'above' }
-- or nil.
function g_exports.valuation_band(rows, band)
    if type(band) ~= 'table' then return nil end
    local low, high = util_num(band.low), util_num(band.high)
    if not low and not high then return nil end
    local latest = valuation_latest(rows)
    local value = latest and util_num(latest[band.metric])
    if not value then return nil end
    local position = 'inside'
    if low and value < low then position = 'below'
    elseif high and value > high then position = 'above' end
    return { metric = band.metric, low = low, high = high, value = value, position = position }
end

-- The metrics a band may be set on, for validation at the API edge.
g_exports.valuation_band_metrics = { pe_ttm = true, pb = true, ps_ttm = true, pcf_ttm = true }
