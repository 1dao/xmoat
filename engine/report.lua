-- engine/report.lua — the analysis object as Markdown text.
--
-- Exports: report_markdown, report_money, report_pct
--
-- For the CLI now, and for push channels (WeCom, Feishu, Telegram) later: those
-- run on the backend with no client to render for them, which is why text
-- rendering lives in the engine. It reads the analysis object and nothing
-- else, exactly as the web page does, so the two cannot disagree on a number.

local null = util_null

local function has(v) return v ~= nil and v ~= null end

function g_exports.report_money(v)
    if not has(v) then return '—' end
    local a = math.abs(v)
    if a >= 1e12 then return string.format('%.2f 万亿', v / 1e12) end
    if a >= 1e8 then return string.format('%.2f 亿', v / 1e8) end
    if a >= 1e4 then return string.format('%.2f 万', v / 1e4) end
    return string.format('%.2f', v)
end

function g_exports.report_pct(v, digits)
    if not has(v) then return '—' end
    return string.format('%.' .. (digits or 1) .. 'f%%', v)
end

local function num(v, digits)
    if not has(v) then return '—' end
    return string.format('%.' .. (digits or 2) .. 'f', v)
end

local function fmt_unit(v, unit, digits)
    if unit == '%' then return report_pct(v, digits) end
    if unit == 'pt' then return has(v) and string.format('%.1fpt', v) or '—' end
    if unit == 'x' then return num(v, 2) end
    if unit == 'CNY' then return report_money(v) end
    return num(v)
end

local STATUS = { pass = '✅', warn = '⚠️', na = '➖' }
local POSITION = { below = '低于', inside = '位于', above = '高于' }
local METRIC_LABEL = { pe_ttm = 'PE(TTM)', pb = 'PB', ps_ttm = 'PS(TTM)', pcf_ttm = 'PCF(TTM)' }

function g_exports.report_markdown(a)
    local L = {}
    local function line(s) L[#L + 1] = s or '' end
    local function f(...) line(string.format(...)) end

    f('# %s（%s.%s）', a.name or a.code, a.code, a.market or '')
    local lr = a.latest_report
    local sub = {}
    if has(a.industry) then sub[#sub + 1] = a.industry end
    if lr then sub[#sub + 1] = string.format('最新报告 %s（公告 %s）', lr.name or lr.period,
        lr.notice_date or '—') end
    if #sub > 0 then line(table.concat(sub, ' · ')) end
    for _, n in ipairs(a.notes or {}) do f('> %s', n) end
    line()

    local v = a.valuation
    if v then
        f('## 估值（%s 收盘 %s，市值 %s）', v.date, num(v.close), report_money(v.market_cap))
        line()
        line('| 指标 | 当前 | 全部历史分位 | 近 5 年分位 | 历史中位数 |')
        line('|---|---|---|---|---|')
        for _, m in ipairs(v.metrics or {}) do
            local all = m.all and report_pct(m.all.percentile, 0) or '—'
            local y5 = m.y5 and report_pct(m.y5.percentile, 0) or '—'
            local range = m.all and string.format(' (%s 起)', m.all.from) or ''
            f('| %s | %s | %s%s | %s | %s |', m.label, num(m.value), all, range, y5,
                m.all and num(m.all.median) or '—')
        end
        line()
        local d = v.dividend
        if d then
            f('- 股息率（近 12 个月）：%s，每股派现 %s 元', report_pct(d.yield_ttm, 2), num(d.dps_ttm, 3))
        end
        local dcf = v.reverse_dcf
        if dcf and dcf.implied_growth then
            local bound = dcf.bound == 'below' and '低于 ' or (dcf.bound == 'above' and '高于 ' or '')
            f('- 反向 DCF：现价隐含%s未来 %d 年年化增长 %s%s（折现率 %s，永续增长 %s）',
                dcf.earnings_label, dcf.years, bound, report_pct(dcf.implied_growth),
                report_pct(dcf.discount_rate), report_pct(dcf.terminal_growth))
        elseif dcf and dcf.error then
            f('- 反向 DCF：%s', dcf.error)
        end
        if v.band then
            local b = v.band
            f('- 你的区间：%s %s–%s，当前 %s，%s区间', METRIC_LABEL[b.metric] or b.metric,
                num(b.low), num(b.high), num(b.value), POSITION[b.position] or '')
        end
        line()
    end

    local q = a.quality
    if q and #(q.periods or {}) > 0 then
        line('## 质量（年报）')
        line()
        for _, s in ipairs(q.summary or {}) do
            f('- %s：%s', s.label, fmt_unit(s.value, s.unit, s.digits))
        end
        line()
        local k = math.max(1, #q.periods - 4)
        local head, sep = { '| 指标 ' }, { '|---' }
        for i = k, #q.periods do
            head[#head + 1] = '| ' .. q.periods[i]:sub(1, 4) .. ' '
            sep[#sep + 1] = '|---'
        end
        line(table.concat(head) .. '|')
        line(table.concat(sep) .. '|')
        for _, s in ipairs(q.series or {}) do
            local row = { '| ' .. s.label .. ' ' }
            for i = k, #q.periods do row[#row + 1] = '| ' .. fmt_unit(s.values[i], s.unit, s.digits) .. ' ' end
            line(table.concat(row) .. '|')
        end
        line()
    end

    local dv = a.dividends
    if dv and dv.latest_fy then
        f('## 分红（连续 %d 年）', dv.consecutive_years or 0)
        line()
        for i = 1, math.min(5, #(dv.years or {})) do
            local y = dv.years[i]
            f('- %d：每股 %s 元，分红率 %s', y.year, num(y.dps, 3), report_pct(y.payout_ratio))
        end
        line()
    end

    if a.checks and #a.checks > 0 then
        line('## 检查清单')
        line()
        for _, c in ipairs(a.checks) do
            f('- %s %s：%s', STATUS[c.status] or c.status, c.title, c.detail or '')
        end
        line()
    end

    local src = {}
    for _, s in ipairs(a.sources or {}) do src[#src + 1] = s.item end
    if #src > 0 then f('数据来源：东方财富（%s），获取于 %s', table.concat(src, '、'), a.fetched_at or '—') end
    line('仅供研究，不构成投资建议。')
    return table.concat(L, '\n')
end
