-- engine/report.lua — the analysis object as Markdown text.
--
-- Exports: report_markdown, report_money, report_pct,
--          report_events_markdown, report_events_text,
--          report_review_markdown, report_backtest_markdown
--
-- For the CLI now, and for push channels (WeCom, Feishu, Telegram) later: those
-- run on the backend with no client to render for them, which is why text
-- rendering lives in the engine. It reads the analysis object and nothing
-- else, exactly as the web page does, so the two cannot disagree on a number.

local null = util_null

local ALIGNMENT = { bull = '多头排列', bear = '空头排列', none = '未形成排列' }

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
local KIND_ICON = { report = '📄', dividend = '💰', band = '🎯', percentile = '📉', check = '🔎', insight = '🧠' }
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
        for _, x in ipairs(v.extras or {}) do
            f('- %s：%s（%s）', x.label, num(x.value), x.basis or '')
        end
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

    local lv = a.levels
    if lv and not lv.note then
        f('## 点位（按规则计算，不是建议）')
        line()
        f('锚：%s，当前 %s，全历史 %s 个交易日（%s 起），中位数 %s', lv.metric_label,
            num(lv.metric_now), lv.window and lv.window.n or '—',
            lv.window and lv.window.from or '—', num(lv.window and lv.window.median))
        line()
        if lv.buy and lv.buy.high then
            if lv.buy.low then
                f('- 买入区间：%s – %s（%s）', num(lv.buy.low), num(lv.buy.high), lv.buy.basis or '')
            else
                f('- 买入价：%s 以下（%s）', num(lv.buy.high), lv.buy.basis or '')
            end
        end
        if lv.target then
            f('- 目标价：%s，较现价 %s（%s）', num(lv.target.price), report_pct(lv.target.upside, 1),
                lv.target.basis or '')
        end
        if lv.stop then
            f('- 止损价：%s，较现价 %s（%s）', num(lv.stop.price), report_pct(lv.stop.downside, 1),
                lv.stop.basis or '')
        end
        if lv.reward_risk then
            f('- 盈亏比：%s（到目标价的空间 / 到止损价的空间）', num(lv.reward_risk, 2))
        end
        line()
        for _, n in ipairs(lv.notes or {}) do f('> %s', n) end
        line()
    elseif lv and lv.note then
        line('## 点位')
        line()
        f('- 算不出来：%s', lv.note)
        line()
    end

    local t = a.technical
    if t then
        f('## 技术面（%s 收盘 %s）', t.as_of or '—', num(t.close))
        line()
        if t.note then
            f('- %s', t.note)
        else
            local mas = {}
            for _, n in ipairs(tech_periods.ma) do
                local v = t.ma and t.ma[tostring(n)]
                if v then mas[#mas + 1] = string.format('MA%d %s', n, num(v)) end
            end
            if #mas > 0 then
                f('- 均线：%s', table.concat(mas, ' · '))
            end
            local tr = t.trend or {}
            f('- 排列：%s；收盘价在 %d/%d 条均线上方', ALIGNMENT[tr.alignment] or '—',
                tr.above_ma or 0, tr.ma_count or 0)
            local bs = {}
            for _, n in ipairs(tech_periods.bias) do
                local v = t.bias and t.bias[tostring(n)]
                if v then bs[#bs + 1] = string.format('BIAS%d %s', n, report_pct(v, 1)) end
            end
            if #bs > 0 then f('- 乖离率：%s', table.concat(bs, ' · ')) end
            local r = t.range_250
            if r and r.high and r.low then
                f('- 位置：近 %d 个交易日 %s–%s，当前分位 %s，距高点 %s', r.days,
                    num(r.low), num(r.high), report_pct(r.position, 0), report_pct(r.from_high, 1))
            end
            if t.volume_ratio then
                f('- 量能：5 日均量 / 60 日均量 = %s', num(t.volume_ratio, 2))
            end
            local c = t.chips
            if c then
                f('- 筹码：平均成本 %s，获利比例 %s，90%% 成本区间 %s–%s（集中度 %s，%d 个交易日）',
                    num(c.avg_cost), report_pct(c.profit_ratio, 0), num(c.low_90), num(c.high_90),
                    report_pct(c.concentration_90, 0), c.days or 0)
            elseif t.chips_note then
                f('- 筹码：%s', t.chips_note)
            end
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

    local b = a.business
    if b and b.period then
        f('## 主营构成（%s 年报）', b.period)
        line()
        local names = { product = '产品', region = '地区', industry = '行业' }
        for _, kind in ipairs({ 'product', 'region' }) do
            local list = b.by and b.by[kind] or {}
            if #list > 0 then
                local items = {}
                for _, s in ipairs(list) do
                    local change = has(s.share_change) and string.format('，%+.1fpt', s.share_change) or ''
                    items[#items + 1] = string.format('%s %s%s（毛利率 %s）', s.name, report_pct(s.revenue_share),
                        change, report_pct(s.gross_margin))
                end
                f('- 按%s：%s', names[kind], table.concat(items, '；'))
            end
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

-- ---------------------------------------------------------------------------
-- Alert digests, for push channels
--
-- One message per push, events grouped by stock in the order they arrived.
-- Two renderings of the same content: Markdown for WeCom and DingTalk, plain
-- text for Feishu and Telegram, whose Markdown dialects reject characters that
-- company names and dividend plans routinely contain.
-- ---------------------------------------------------------------------------

-- A backtest result as Markdown. The baseline sits in the same table as the
-- signal, column by column, because the two numbers only mean something next
-- to each other.
function g_exports.report_backtest_markdown(r)
    local L = {}
    local function line(s) L[#L + 1] = s or '' end
    local function f(...) line(string.format(...)) end

    f('# 回测 %s %s', r.code or '', r.name or '')
    line()
    f('信号：%s', r.signal_note or r.signal or '')
    if r.note then
        line()
        f('- %s', r.note)
        return table.concat(L, '\n')
    end
    f('区间：%s – %s，行情 %s – %s；触发 %d 次（可判定的交易日 %d 个，两次信号至少间隔 %d 个交易日）',
        r.from or '—', r.to or '—', r.price_from or '—', r.price_to or '—',
        r.entries or 0, r.tested or 0, r.cooldown or 0)
    line()

    line('## 方向胜率')
    line()
    line('| 持有 | 次数 | 胜率 | 基准胜率 | 平均收益 | 基准平均 | 中位数 | 最好 | 最差 |')
    line('|---|---|---|---|---|---|---|---|---|')
    local base = {}
    for _, b in ipairs((r.baseline or {}).horizons or {}) do base[b.days] = b end
    for _, hz in ipairs(r.horizons or {}) do
        local b = base[hz.days] or {}
        f('| %d 日 | %d | %s | %s | %s | %s | %s | %s | %s |', hz.days, hz.n or 0,
            report_pct(hz.win_rate, 0), report_pct(b.win_rate, 0),
            report_pct(hz.avg, 1), report_pct(b.avg, 1), report_pct(hz.median, 1),
            report_pct(hz.best, 1), report_pct(hz.worst, 1))
    end
    line()

    local br = r.barrier or {}
    local bb = (r.baseline or {}).barrier or {}
    f('## 止盈止损（止盈 %s，止损 %s，最多观察 %d 个交易日）',
        report_pct(br.take_profit, 0), report_pct(br.stop_loss, 0), br.horizon or 0)
    line()
    line('| | 信号 | 基准 |')
    line('|---|---|---|')
    f('| 先到止盈 | %d（%s） | %d（%s） |', br.hit_tp or 0, report_pct(br.tp_rate, 0),
        bb.hit_tp or 0, report_pct(bb.tp_rate, 0))
    f('| 先到止损 | %d（%s） | %d（%s） |', br.hit_sl or 0, report_pct(br.sl_rate, 0),
        bb.hit_sl or 0, report_pct(bb.sl_rate, 0))
    f('| 都没到 | %d | %d |', br.neither or 0, bb.neither or 0)
    f('| 止盈命中率 | %s | %s |', report_pct(br.win_rate, 0), report_pct(bb.win_rate, 0))
    f('| 平均到达天数 | 止盈 %s / 止损 %s | 止盈 %s / 止损 %s |',
        num(br.avg_days_tp, 0), num(br.avg_days_sl, 0), num(bb.avg_days_tp, 0), num(bb.avg_days_sl, 0))
    line()
    if (br.both_same_day or 0) > 0 then
        f('> 其中 %d 次在同一天既触及止盈也触及止损，按止损计：日线看不出谁先到，' ..
          '算成赢是那种让回测都好看的假设。', br.both_same_day)
        line()
    end
    for _, n in ipairs(r.notes or {}) do f('> %s', n) end
    line()
    return table.concat(L, '\n')
end

local REGIME = { bull = '多头（指数在上升的长期均线之上）', bear = '空头（指数在下降的长期均线之下）',
                 range = '震荡（指数与长期均线方向不一致）', unknown = '未知' }

-- The daily review as Markdown: the same three parts the object has.
function g_exports.report_review_markdown(r)
    local L = {}
    local function line(s) L[#L + 1] = s or '' end
    local function f(...) line(string.format(...)) end

    f('# 复盘 %s', r.as_of or util_today())
    line()

    local m = r.market or {}
    line('## 一、大盘')
    line()
    line('| 指数 | 收盘 | 涨跌 | 近 250 日分位 | 距高点 | 量能 |')
    line('|---|---|---|---|---|---|')
    for _, ix in ipairs(m.indexes or {}) do
        f('| %s | %s | %s | %s | %s | %s |', ix.name or ix.code, num(ix.close),
            report_pct(ix.change_pct, 2), report_pct(ix.position_250, 0),
            report_pct(ix.from_high, 1), num(ix.volume_ratio, 2))
    end
    line()
    local rg = m.regime or {}
    f('- 状态（%s）：%s', m.regime_index or '—', REGIME[rg.state] or '—')
    for _, why in ipairs(rg.reasons or {}) do f('  - %s', why) end
    local st = m.stance or {}
    if st.position then
        f('- 机械仓位区间：%s。%s', st.position, st.text or '')
        f('  > %s', st.note or '')
    end
    line()

    local sct = r.structure or {}
    line('## 二、结构')
    line()
    if sct.note then
        f('- %s', sct.note)
    else
        local b = sct.breadth or {}
        f('- 板块涨跌：%d 涨 / %d 跌 / %d 平，共 %d 个行业板块，上涨占 %s',
            b.up or 0, b.down or 0, b.flat or 0, sct.sector_count or 0, report_pct(b.ratio, 0))
        line()
        line('| 领涨板块 | 涨跌 | 涨/跌家数 | 领涨股 |')
        line('|---|---|---|---|')
        for _, x in ipairs(sct.leaders or {}) do
            f('| %s | %s | %d/%d | %s %s |', x.name, report_pct(x.change_pct, 2),
                x.up or 0, x.down or 0, x.leader or '—', report_pct(x.leader_change, 1))
        end
        line()
        line('| 领跌板块 | 涨跌 | 涨/跌家数 |')
        line('|---|---|---|')
        for _, x in ipairs(sct.laggards or {}) do
            f('| %s | %s | %d/%d |', x.name, report_pct(x.change_pct, 2), x.up or 0, x.down or 0)
        end
    end
    line()

    local w = r.watchlist or {}
    line('## 三、自选')
    line()
    if (w.count or 0) == 0 then
        line('- 自选为空。')
    else
        line('| 代码 | 名称 | 收盘 | 涨跌 | 估值分位 | 警示 | 提示 |')
        line('|---|---|---|---|---|---|---|')
        for _, x in ipairs(w.rows or {}) do
            f('| %s | %s | %s | %s | %s | %s | %s |', x.code, x.name or '—', num(x.close),
                report_pct(x.change_pct, 2), report_pct(x.percentile, 0),
                x.warnings or 0, #(x.flags or {}) > 0 and table.concat(x.flags, '、') or '—')
        end
    end
    line()
    return table.concat(L, '\n')
end

local function group_events(events, max)
    local groups, by_code, shown = {}, {}, 0
    for _, e in ipairs(events) do
        if shown >= max then break end
        local g = by_code[e.code]
        if not g then
            g = { code = e.code, name = e.name, items = {} }
            by_code[e.code] = g
            groups[#groups + 1] = g
        end
        g.items[#g.items + 1] = e
        shown = shown + 1
    end
    return groups, #events - shown
end

local function event_icon(e)
    if e.kind == 'check' then return e.status == 'warn' and '⚠️' or '✅' end
    if e.kind == 'percentile' then return e.title:find('高位', 1, true) and '📈' or '📉' end
    return KIND_ICON[e.kind] or '•'
end

-- opts: { max = 20, title = 'xmoat 提醒' }
function g_exports.report_events_markdown(events, opts)
    opts = opts or {}
    local groups, rest = group_events(events, opts.max or 20)
    local L = { string.format('### %s（%d 条）', opts.title or 'xmoat 提醒', #events) }
    for _, g in ipairs(groups) do
        L[#L + 1] = ''
        L[#L + 1] = string.format('**%s**（%s）', g.name or g.code, g.code)
        for _, e in ipairs(g.items) do
            L[#L + 1] = string.format('- %s %s', event_icon(e), e.title)
            if e.detail and e.detail ~= '' then L[#L + 1] = '  ' .. e.detail end
        end
    end
    if rest > 0 then
        L[#L + 1] = ''
        L[#L + 1] = string.format('还有 %d 条，见 xmoat 提醒页。', rest)
    end
    L[#L + 1] = ''
    L[#L + 1] = '仅供研究，不构成投资建议。'
    return table.concat(L, '\n')
end

function g_exports.report_events_text(events, opts)
    opts = opts or {}
    local groups, rest = group_events(events, opts.max or 20)
    local L = { string.format('%s（%d 条）', opts.title or 'xmoat 提醒', #events) }
    for _, g in ipairs(groups) do
        L[#L + 1] = ''
        L[#L + 1] = string.format('【%s %s】', g.name or g.code, g.code)
        for _, e in ipairs(g.items) do
            L[#L + 1] = string.format('%s %s', event_icon(e), e.title)
            if e.detail and e.detail ~= '' then L[#L + 1] = '   ' .. e.detail end
        end
    end
    if rest > 0 then
        L[#L + 1] = ''
        L[#L + 1] = string.format('还有 %d 条，见 xmoat 提醒页。', rest)
    end
    L[#L + 1] = ''
    L[#L + 1] = '仅供研究，不构成投资建议。'
    return table.concat(L, '\n')
end
