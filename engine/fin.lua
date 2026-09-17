-- engine/fin.lua — periodic reports as series: annual picks, TTM, statistics.
--
-- Exports: fin_latest, fin_find, fin_annual, fin_ttm, fin_ttm_basis, fin_year_of,
--          fin_mean, fin_min, fin_max, fin_median, fin_values, fin_cagr
--
-- Pure functions over the report records engine/source_*.lua produce (newest
-- first). No I/O, no clock, no config: every result depends only on the
-- arguments, which is what makes the numbers testable against hand-worked
-- examples in test/unit.lua.
--
-- THE CUMULATIVE TRAP. A Q1/H1/Q3 report's revenue and profit are year-to-date,
-- not the quarter alone. Comparing an H1 profit with an annual one, or summing
-- four cumulative figures, silently gives a wrong answer that looks plausible.
-- Anything that needs twelve months of a flow item goes through fin_ttm.

function g_exports.fin_latest(reports)
    return reports and reports[1] or nil
end

function g_exports.fin_find(reports, period)
    for _, r in ipairs(reports or {}) do
        if r.period == period then return r end
    end
    return nil
end

function g_exports.fin_year_of(period)
    return tonumber(tostring(period or ''):sub(1, 4))
end

-- The last n annual reports, OLDEST first (the order a series is drawn in).
function g_exports.fin_annual(reports, n)
    local picked = {}
    for _, r in ipairs(reports or {}) do
        if r.period_type == 'FY' then
            picked[#picked + 1] = r
            if n and #picked >= n then break end
        end
    end
    local out = {}
    for i = #picked, 1, -1 do out[#out + 1] = picked[i] end
    return out
end

-- Trailing-twelve-month value of a flow field as of the newest report.
--
--   annual report  : the annual figure
--   otherwise      : latest YTD + last annual - same YTD a year earlier
--
-- Returns value, basis — basis names the periods used, so a reader can check
-- the arithmetic — or nil, reason when a needed report is missing.
function g_exports.fin_ttm(reports, field)
    local latest = fin_latest(reports)
    if not latest then return nil, 'no reports' end
    local v = util_num(latest[field])
    if latest.period_type == 'FY' then
        if not v then return nil, latest.period .. ' has no ' .. field end
        return v, { latest.period }
    end

    local year = fin_year_of(latest.period)
    local prev_fy_period = string.format('%04d-12-31', year - 1)
    local prev_same_period = string.format('%04d%s', year - 1, latest.period:sub(5))
    local fy = fin_find(reports, prev_fy_period)
    local same = fin_find(reports, prev_same_period)
    local fy_v = fy and util_num(fy[field])
    local same_v = same and util_num(same[field])
    if not v or not fy_v or not same_v then
        return nil, string.format('TTM needs %s, %s and %s', latest.period,
            prev_fy_period, prev_same_period)
    end
    return v + fy_v - same_v, { latest.period, prev_fy_period, prev_same_period }
end

-- The arithmetic behind a fin_ttm result, as a reader would check it. Passes a
-- failure reason (a string) straight through.
function g_exports.fin_ttm_basis(basis)
    if type(basis) ~= 'table' then return basis end
    if #basis == 1 then return basis[1] .. ' 年报' end
    return string.format('%s 累计 + %s 年报 − %s 累计', basis[1], basis[2], basis[3])
end

-- ---------------------------------------------------------------------------
-- Statistics. Each takes a list that may contain nils or util_null and ignores
-- them; each returns nil for a list with no values.
-- ---------------------------------------------------------------------------

function g_exports.fin_values(list)
    local out = {}
    for i = 1, (list and (list.n or #list)) or 0 do
        local v = util_num(list[i])
        if v then out[#out + 1] = v end
    end
    return out
end

function g_exports.fin_mean(list)
    local vs = fin_values(list)
    if #vs == 0 then return nil end
    local s = 0
    for _, v in ipairs(vs) do s = s + v end
    return s / #vs
end

-- Loops rather than math.min(table.unpack(vs)): a valuation history is
-- thousands of points, and unpack puts every one of them on the C stack.
function g_exports.fin_min(list)
    local m = nil
    for _, v in ipairs(fin_values(list)) do
        if not m or v < m then m = v end
    end
    return m
end

function g_exports.fin_max(list)
    local m = nil
    for _, v in ipairs(fin_values(list)) do
        if not m or v > m then m = v end
    end
    return m
end

function g_exports.fin_median(list)
    local vs = fin_values(list)
    if #vs == 0 then return nil end
    table.sort(vs)
    local mid = (#vs + 1) / 2
    if mid % 1 == 0 then return vs[mid] end
    return (vs[math.floor(mid)] + vs[math.ceil(mid)]) / 2
end

-- Compound annual growth, as a percent. Undefined unless both ends are
-- positive: growth "from a loss" has no rate, and pretending otherwise is how
-- a turnaround reads as 900% a year.
function g_exports.fin_cagr(first, last, years)
    first, last = util_num(first), util_num(last)
    if not first or not last or first <= 0 or last <= 0 or not years or years <= 0 then
        return nil
    end
    return ((last / first) ^ (1 / years) - 1) * 100
end
