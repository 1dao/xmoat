-- engine/checks.lua — the checklist: red flags, and the ones that came back clean.
--
-- Exports: checks_build, checks_thresholds
--
-- Every check answers pass / warn / na, and says why in a sentence that names
-- the figures and the periods. 'na' is not a pass: it means the data needed was
-- missing, and a checklist that quietly skipped it would read as clean.
--
-- Thresholds are rules of thumb, stated here in one table so they can be read,
-- argued with and changed in one place. None is a verdict; each is a reason to
-- open the annual report and look.

local T = {
    ocf_to_np_min = 0.8,          -- 3-year mean of operating cash flow / net profit
    deducted_share_min = 80,      -- deducted / parent net profit, percent
    receivables_gap_max = 20,     -- receivables growth minus revenue growth, pt
    receivables_material = 5,     -- ... only when receivables >= this % of revenue
    inventory_gap_max = 30,       -- inventory growth minus revenue growth, pt
    inventory_material = 10,      -- ... only when inventory >= this % of revenue
    goodwill_max = 30,            -- goodwill / parent equity, percent
    cash_high = 15,               -- 存贷双高: cash / total assets, percent
    debt_high = 15,               --           interest-bearing debt / total assets
    gross_margin_drop_max = 5,    -- year-on-year fall, pt
    debt_ratio_max = 70,          -- total liabilities / total assets, percent
    -- banks
    npl_max = 2,                  -- non-performing loan ratio, percent
    npl_rise_max = 0.1,           -- year-on-year rise, pt
    provision_coverage_min = 150, -- percent (the regulatory floor is 120-150)
    core_t1_min = 8.5,            -- percent (7.5 minimum plus buffers)
}
g_exports.checks_thresholds = T

local function pct(v) return string.format('%.1f%%', v) end
local function pt(v) return string.format('%+.1fpt', v) end

local function yi(v)
    if math.abs(v) >= 1e8 then return string.format('%.2f 亿', v / 1e8) end
    return string.format('%.0f 万', v / 1e4)
end

local function check(key, title, status, detail, extra)
    local c = { key = key, title = title, status = status, detail = detail }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function na(key, title, why)
    return check(key, title, 'na', why)
end

-- Interest-bearing debt as the balance sheet shows it. Approximate by
-- construction: lease liabilities are left out, and "non-current liabilities
-- due within a year" can include items that bear no interest.
local function interest_debt(b)
    local sum, any = 0, false
    for _, k in ipairs({ 'short_loan', 'long_loan', 'bonds_payable', 'noncurrent_liab_1y' }) do
        local v = util_num(b[k])
        if v then sum = sum + v; any = true end
    end
    return any and sum or 0
end

local function growth(now, before)
    now, before = util_num(now), util_num(before)
    if not now or not before or before <= 0 then return nil end
    return (now / before - 1) * 100
end

-- ---------------------------------------------------------------------------
-- Checks every template runs
-- ---------------------------------------------------------------------------

local function check_loss(annual)
    local title = '最近一个财年盈利'
    local fy = annual[#annual]
    if not fy then return na('profitable', title, '没有年报数据') end
    local np = util_num(fy.np_parent)
    if not np then return na('profitable', title, fy.period .. ' 年报缺少归母净利润') end
    if np <= 0 then
        return check('profitable', title, 'warn',
            string.format('%s 年报归母净利润 %s，亏损', fy.period, yi(np)),
            { value = np, period = fy.period })
    end
    return check('profitable', title, 'pass',
        string.format('%s 年报归母净利润 %s', fy.period, yi(np)),
        { value = np, period = fy.period })
end

-- ---------------------------------------------------------------------------
-- General companies
-- ---------------------------------------------------------------------------

local function check_ocf(annual)
    local key, title = 'ocf_quality', '利润有现金流支撑'
    local span = {}
    for i = math.max(1, #annual - 2), #annual do span[#span + 1] = annual[i] end
    local vals = {}
    for _, r in ipairs(span) do vals[#vals + 1] = util_num(r.ocf_to_np) or util_null end
    local avg = fin_mean(vals)
    if not avg or #fin_values(vals) < #span or #span < 3 then
        return na(key, title, '近 3 个年报的经营现金流 / 净利润数据不全')
    end
    local detail = string.format('经营现金流 / 净利润 近 3 年均值 %.2f（%s → %s），阈值 %.1f',
        avg, span[1].period, span[#span].period, T.ocf_to_np_min)
    return check(key, title, avg < T.ocf_to_np_min and 'warn' or 'pass', detail,
        { value = avg, threshold = T.ocf_to_np_min })
end

local function check_deducted(annual)
    local key, title = 'recurring_profit', '利润主要来自主业'
    local fy = annual[#annual]
    if not fy then return na(key, title, '没有年报数据') end
    local np, ded = util_num(fy.np_parent), util_num(fy.np_deducted)
    if not np or not ded or np <= 0 then
        return na(key, title, fy.period .. ' 年报缺少净利润数据或亏损')
    end
    local share = ded / np * 100
    local detail = string.format('%s 扣非净利润占归母净利润 %s（扣非 %s / 归母 %s），阈值 %s',
        fy.period, pct(share), yi(ded), yi(np), pct(T.deducted_share_min))
    return check(key, title, share < T.deducted_share_min and 'warn' or 'pass', detail,
        { value = share, threshold = T.deducted_share_min, period = fy.period })
end

-- Balance-sheet item growing much faster than revenue, when the item is large
-- enough to matter. Compares the last two annual balance sheets.
local function check_outpacing(key, title, field, label, gap_max, material,
                               annual, balance_by_period)
    local fy, prev = annual[#annual], annual[#annual - 1]
    if not fy or not prev then return na(key, title, '需要连续两个年报') end
    local b, pb = balance_by_period[fy.period], balance_by_period[prev.period]
    if not b or not pb then return na(key, title, '缺少资产负债表数据') end
    local item, revenue = util_num(b[field]), util_num(fy.revenue)
    if not revenue or revenue <= 0 then return na(key, title, fy.period .. ' 年报缺少营收') end
    if not item or item == 0 then
        return check(key, title, 'pass', string.format('%s 年报%s为 0', fy.period, label))
    end
    local share = item / revenue * 100
    if share < material then
        return check(key, title, 'pass', string.format('%s 年报%s %s，占营收 %s，规模不大',
            fy.period, label, yi(item), pct(share)))
    end
    local item_g = growth(item, pb[field])
    local rev_g = util_num(fy.revenue_yoy) or growth(fy.revenue, prev.revenue)
    if not item_g or not rev_g then return na(key, title, '无法计算同比增速') end
    local gap = item_g - rev_g
    local detail = string.format('%s 年报%s同比 %s，营收同比 %s，相差 %s（阈值 %s），%s占营收 %s',
        fy.period, label, pct(item_g), pct(rev_g), pt(gap), pt(gap_max), label, pct(share))
    return check(key, title, gap > gap_max and 'warn' or 'pass', detail,
        { value = gap, threshold = gap_max, period = fy.period })
end

local function check_goodwill(latest_balance)
    local key, title = 'goodwill', '商誉占净资产比例不高'
    local b = latest_balance
    if not b then return na(key, title, '缺少资产负债表数据') end
    local eq = util_num(b.equity_parent)
    if not eq or eq <= 0 then return na(key, title, b.period .. ' 归母净资产缺失或为负') end
    local gw = util_num(b.goodwill) or 0
    local share = gw / eq * 100
    local detail = string.format('%s 商誉 %s，占归母净资产 %s（阈值 %s）',
        b.period, yi(gw), pct(share), pct(T.goodwill_max))
    return check(key, title, share > T.goodwill_max and 'warn' or 'pass', detail,
        { value = share, threshold = T.goodwill_max, period = b.period })
end

local function check_cash_and_debt(latest_balance)
    local key, title = 'cash_and_debt', '没有"存贷双高"'
    local b = latest_balance
    if not b then return na(key, title, '缺少资产负债表数据') end
    local ta = util_num(b.total_assets)
    if not ta or ta <= 0 then return na(key, title, b.period .. ' 缺少总资产') end
    local cash = util_num(b.cash) or 0
    local debt = interest_debt(b)
    local cash_share, debt_share = cash / ta * 100, debt / ta * 100
    local detail = string.format('%s 货币资金占总资产 %s，有息负债占总资产 %s（两者都超过 %s 才提示）',
        b.period, pct(cash_share), pct(debt_share), pct(T.cash_high))
    local both = cash_share >= T.cash_high and debt_share >= T.debt_high
    return check(key, title, both and 'warn' or 'pass', detail,
        { values = { cash = cash_share, debt = debt_share }, threshold = T.cash_high,
          period = b.period })
end

local function check_short_debt(latest_balance)
    local key, title = 'short_debt_cover', '现金能覆盖短期有息负债'
    local b = latest_balance
    if not b then return na(key, title, '缺少资产负债表数据') end
    local short = (util_num(b.short_loan) or 0) + (util_num(b.noncurrent_liab_1y) or 0)
    local cash = util_num(b.cash) or 0
    if short <= 0 then
        return check(key, title, 'pass', string.format('%s 没有短期借款和一年内到期的非流动负债', b.period))
    end
    local cover = cash / short
    local detail = string.format('%s 货币资金 %s，短期借款 + 一年内到期非流动负债 %s，覆盖 %.2f 倍',
        b.period, yi(cash), yi(short), cover)
    return check(key, title, cover < 1 and 'warn' or 'pass', detail,
        { value = cover, threshold = 1, period = b.period })
end

local function check_margin(annual)
    local key, title = 'gross_margin_stable', '毛利率没有明显下滑'
    local fy, prev = annual[#annual], annual[#annual - 1]
    if not fy or not prev then return na(key, title, '需要连续两个年报') end
    local now, before = util_num(fy.gross_margin), util_num(prev.gross_margin)
    if not now or not before then return na(key, title, '缺少毛利率数据') end
    local change = now - before
    local detail = string.format('毛利率 %s → %s（%s → %s），变化 %s，阈值 −%.0fpt',
        pct(before), pct(now), prev.period, fy.period, pt(change), T.gross_margin_drop_max)
    return check(key, title, change < -T.gross_margin_drop_max and 'warn' or 'pass', detail,
        { value = change, threshold = -T.gross_margin_drop_max, period = fy.period })
end

local function check_debt_ratio(reports)
    local key, title = 'debt_ratio', '资产负债率不高'
    local r = fin_latest(reports)
    local v = r and util_num(r.debt_ratio)
    if not v then return na(key, title, '缺少资产负债率') end
    local detail = string.format('%s 资产负债率 %s（阈值 %s）', r.period, pct(v), pct(T.debt_ratio_max))
    return check(key, title, v > T.debt_ratio_max and 'warn' or 'pass', detail,
        { value = v, threshold = T.debt_ratio_max, period = r.period })
end

-- ---------------------------------------------------------------------------
-- Banks
-- ---------------------------------------------------------------------------

-- `digits`: NPL ratios move in hundredths of a point, and 1.05% printed as
-- "1.1%" hides exactly the change a reader is looking for.
local function check_bank_latest(reports, key, title, field, label, bound, is_max, digits)
    local r = fin_latest(reports)
    local v = r and util_num(r[field])
    if not v then return na(key, title, '缺少' .. label) end
    local bad = is_max and v > bound or (not is_max and v < bound)
    local f = '%.' .. (digits or 1) .. 'f%%'
    local detail = string.format('%s %s %s（%s %s）', r.period, label, string.format(f, v),
        is_max and '上限' or '下限', string.format(f, bound))
    return check(key, title, bad and 'warn' or 'pass', detail,
        { value = v, threshold = bound, period = r.period })
end

local function check_npl_trend(annual)
    local key, title = 'npl_trend', '不良率没有上升'
    local fy, prev = annual[#annual], annual[#annual - 1]
    if not fy or not prev then return na(key, title, '需要连续两个年报') end
    local now, before = util_num(fy.npl_ratio), util_num(prev.npl_ratio)
    if not now or not before then return na(key, title, '缺少不良贷款率') end
    local change = now - before
    local detail = string.format('不良贷款率 %.2f%% → %.2f%%（%s → %s）', before, now,
        prev.period, fy.period)
    return check(key, title, change > T.npl_rise_max and 'warn' or 'pass', detail,
        { value = change, threshold = T.npl_rise_max, period = fy.period })
end

-- ---------------------------------------------------------------------------

-- template: see engine/quality.lua. balance: newest first, may be empty.
-- Returns a list of checks.
function g_exports.checks_build(reports, balance, template)
    local annual = fin_annual(reports, 10)
    local out = { check_loss(annual) }
    local function add(c) out[#out + 1] = c end

    if template == 'bank' then
        add(check_bank_latest(reports, 'npl_ratio', '不良贷款率不高', 'npl_ratio',
            '不良贷款率', T.npl_max, true, 2))
        add(check_npl_trend(annual))
        add(check_bank_latest(reports, 'provision_coverage', '拨备覆盖率充足',
            'provision_coverage', '拨备覆盖率', T.provision_coverage_min, false))
        add(check_bank_latest(reports, 'core_t1', '核心一级资本充足', 'core_t1',
            '核心一级资本充足率', T.core_t1_min, false))
        return util_json_array(out)
    end
    if template ~= 'general' then
        return util_json_array(out)
    end

    local by_period = {}
    for _, b in ipairs(balance or {}) do by_period[b.period] = b end
    local latest_balance = balance and balance[1] or nil

    add(check_ocf(annual))
    add(check_deducted(annual))
    add(check_margin(annual))
    add(check_outpacing('receivables', '应收账款没有远快于营收', 'receivables', '应收账款',
        T.receivables_gap_max, T.receivables_material, annual, by_period))
    add(check_outpacing('inventory', '存货没有远快于营收', 'inventory', '存货',
        T.inventory_gap_max, T.inventory_material, annual, by_period))
    add(check_goodwill(latest_balance))
    add(check_cash_and_debt(latest_balance))
    add(check_short_debt(latest_balance))
    add(check_debt_ratio(reports))
    return util_json_array(out)
end
