-- engine/dividend.lua — what shareholders were actually paid.
--
-- Exports: dividend_counts, dividend_ttm, dividend_years
--
-- Pure functions over dividend events (engine/source_em.lua shape):
--   { period, progress, plan, dps, ex_date, record_date, notice_date, ... }
-- `dps` is cash per share, pre-tax, in yuan.

-- Plans that were proposed and then did not happen. Anything else with a cash
-- amount counts as declared for the year it belongs to — including a plan
-- still waiting for its shareholder meeting, which is almost always approved,
-- and without which a stock that has just published its annual report would
-- show a broken dividend streak for the two months until the vote.
local NOT_PAID = { ['停止实施'] = true, ['股东大会否决'] = true, ['不分配'] = true,
                   ['未通过'] = true }

function g_exports.dividend_counts(ev)
    local dps = util_num(ev.dps)
    return dps ~= nil and dps > 0 and not NOT_PAID[ev.progress or '']
end

-- Cash paid per share over the 365 days ending on `as_of`, from events whose
-- ex-dividend date falls in that window, and the yield at `price`.
--
-- Ex-date rather than report period: a yield is about what a holder received
-- in the last year, and a final dividend for 2024 paid in June 2025 belongs to
-- the 2025 holder. Only events with an ex-date count — a declared dividend that
-- has not gone ex is not yet money anyone received.
-- Returns { dps, yield, from, to, events = { {ex_date, dps, period} } }.
function g_exports.dividend_ttm(events, as_of, price)
    local from = util_date_add_days(as_of, -365)
    local sum, used = 0, {}
    for _, ev in ipairs(events or {}) do
        if dividend_counts(ev) and ev.ex_date and ev.ex_date > from and ev.ex_date <= as_of then
            sum = sum + ev.dps
            used[#used + 1] = { ex_date = ev.ex_date, dps = ev.dps, period = ev.period }
        end
    end
    table.sort(used, function(a, b) return a.ex_date < b.ex_date end)
    price = util_num(price)
    return {
        dps = sum,
        yield = (price and price > 0) and (sum / price * 100) or nil,
        from = from, to = as_of,
        events = used,
    }
end

-- Per fiscal year, newest first: cash per share declared for that year (the
-- interim and the final together), and the payout ratio against that year's
-- basic EPS. Plus how many consecutive years, counting back from the latest
-- annual report, paid anything.
--
-- The streak starts at the latest ANNUAL report's year on purpose. Starting at
-- "the latest year that paid" would hide exactly the thing a streak is for: a
-- company that stopped.
-- Returns { years = { {year, dps, payout_ratio, eps} }, consecutive_years,
--           latest_fy }.
function g_exports.dividend_years(events, reports)
    local by_year = {}
    for _, ev in ipairs(events or {}) do
        if dividend_counts(ev) then
            local y = fin_year_of(ev.period)
            if y then by_year[y] = (by_year[y] or 0) + ev.dps end
        end
    end

    local annual = fin_annual(reports)     -- oldest first
    local latest_fy = annual[#annual] and fin_year_of(annual[#annual].period) or nil

    local years = {}
    for i = #annual, 1, -1 do
        local r = annual[i]
        local y = fin_year_of(r.period)
        local dps = by_year[y] or 0
        local eps = util_num(r.eps)
        years[#years + 1] = {
            year = y, dps = dps, eps = eps,
            payout_ratio = (eps and eps > 0) and (dps / eps * 100) or nil,
        }
    end

    local streak = 0
    if latest_fy then
        local y = latest_fy
        while (by_year[y] or 0) > 0 do
            streak = streak + 1
            y = y - 1
        end
    end
    return { years = years, consecutive_years = streak, latest_fy = latest_fy }
end
