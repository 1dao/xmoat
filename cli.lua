-- cli.lua — xmoat from a terminal.
--
--   bin/xnet cli.lua report 600519          analysis as Markdown (fetches if needed)
--   bin/xnet cli.lua report 600519 refresh  fetch first, then report
--   bin/xnet cli.lua refresh 600519
--   bin/xnet cli.lua list                   the watchlist
--   bin/xnet cli.lua add 600519 | remove 600519
--   bin/xnet cli.lua call stock.get code=600519     any command, JSON out
--   bin/xnet cli.lua commands               every command
--
-- A host like main.lua, without a socket: it loads the same engine and calls
-- the same commands. Output goes through io.write because print() is routed
-- to the log under this runtime.
--
-- Runs twice, like main.lua: the first pass loads the loader and hands this
-- file back to it, the second arrives inside a module environment.

local boot = ...
if type(boot) ~= 'table' then
    boot = dofile('engine/boot.lua')
    return boot.run_script('cli.lua', boot)
end

for _, path in ipairs(boot.run_script('engine/manifest.lua')) do boot.load_script(path) end

-- Keep the terminal for the report: raise the runtime's log threshold to WARN
-- (6 in xlog's numbering; xthread exposes no constant for it). The threshold is
-- process-wide, so VERBOSE=1 keeps everything for when a refresh misbehaves.
if not cfg_bool('VERBOSE', false) then xthread.set_log_level(6) end

local args = {}
for i = 1, #(arg or {}) do args[i] = arg[i] end

local function out(s) io.write(s, '\n'); io.flush() end
local function err(s) io.stderr:write(s, '\n'); io.stderr:flush() end

local USAGE = [[
用法: bin/xnet cli.lua <命令> [参数]

  report <代码> [refresh]   输出分析报告（Markdown）；没有数据或带 refresh 时先抓取
  refresh <代码>            抓取并保存
  list                      自选列表
  add <代码>                加入自选
  remove <代码>             移出自选
  check                     立即检查：刷新全部自选股，记录变化并推送
  alerts [代码]             最近的提醒
  notify-test               向已配置的推送渠道发送测试消息
  market-refresh            抓取全市场快照（约 15 次请求）
  review [offline]          当日复盘：大盘与 regime、板块结构、自选表现
  backtest <代码> [信号]    在这只股票的历史上回放信号：value/trend/value_trend/band/breakout
  sweep <代码> [k=v ...]    参数网格（单只股票）：均线走平后突破，哪组窗口和幅度最好
                            如 sweep 600519 horizon=60 max_worst=-15 min_entries=15
  stocks [k=v ...]          全市场股票列表（本地快照），如 stocks board=star industry=半导体
  prefetch [k=v ...]        批量抓日线备好本地，如 prefetch universe=market limit=500 bars_days=400
  fit [k=v ...]             在一组股票上一起拟合参数，如 fit universe=screen roe_min=15 limit=30
  scan [k=v ...]            扫描现在正在发信号的股票，如 scan universe=screen roe_min=15 limit=50
  groups [k=v ...]          分组归因：这条规则在哪些行业/板块/地域更有效
                            如 groups universe=market limit=6000 offline=true
  screen [k=v ...]          筛选全市场，如 screen roe_min=15 pe_max=20 cap_min=100
  insight <代码> [refresh]  大模型解读；带 refresh 时重新生成（会产生费用）
  ask <代码> <问题>         就这只股票提问（会产生费用）
  call <命令名> [k=v ...]   调用任意命令，输出 JSON，如 call stock.valuation code=600519 years=5
  commands                  列出全部命令
]]

-- Returns the envelope's data, or prints the error and returns nil.
local function call(name, params)
    local res = api_call(name, params, { host = 'cli' })
    if not res.ok then
        err(string.format('错误 [%s]: %s', res.error.code, res.error.message))
        return nil
    end
    return res.data
end

local function fmt_pct(v)
    if type(v) ~= 'number' then return '—' end
    return string.format('%.0f%%', v)
end

local function run()
    local cmd = args[1]
    if cmd == 'report' then
        if not args[2] then err(USAGE); return 2 end
        local a
        if args[3] ~= 'refresh' then
            local res = api_call('stock.get', { code = args[2] }, { host = 'cli' })
            if res.ok then a = res.data
            elseif res.error.code ~= 'not_fetched' then
                err(string.format('错误 [%s]: %s', res.error.code, res.error.message))
                return 1
            end
        end
        if not a then
            a = call('stock.refresh', { code = args[2] })
            if not a then return 1 end
        end
        out(report_markdown(a))
        return 0
    elseif cmd == 'review' then
        local r = call('review.daily', { offline = args[2] == 'offline' })
        if not r then return 1 end
        out(report_review_markdown(r))
        return 0
    elseif cmd == 'stocks' then
        local params = {}
        for i = 2, #args do
            local k, v = args[i]:match('^([%w_]+)=(.*)$')
            if k then params[k] = v end
        end
        local r = call('market.list', params)
        if not r then return 1 end
        out(string.format('| 代码 | 名称 | 行业 | 板块 | 市值(亿) |'))
        out('|---|---|---|---|---|')
        for _, x in ipairs(r.rows) do
            out(string.format('| %s | %s | %s | %s | %s |', x.code, x.name or '—',
                x.industry or '—', x.board or '—',
                type(x.market_cap) == 'number' and string.format('%.0f', x.market_cap / 1e8) or '—'))
        end
        out(string.format('\n%s 收盘的快照：符合条件 %d 只，列出 %d 只', r.trade_date or '—',
            r.matched or 0, r.count or 0))
        return 0
    elseif cmd == 'prefetch' then
        local params = {}
        for i = 2, #args do
            local k, v = args[i]:match('^([%w_]+)=(.*)$')
            if k then params[k] = v end
        end
        local r = call('strategy.prefetch', params)
        if not r then return 1 end
        out(string.format('%d 只：缓存命中 %d，新抓 %d，失败 %d，用时 %.1f 秒',
            r.total or 0, r.cached or 0, r.fetched or 0, #(r.failed or {}), (r.ms or 0) / 1000))
        for i = 1, math.min(5, #(r.failed or {})) do
            out(string.format('  %s %s', r.failed[i].code, r.failed[i].error))
        end
        return 0
    elseif cmd == 'groups' then
        local params = {}
        for i = 2, #args do
            local k, v = args[i]:match('^([%w_]+)=(.*)$')
            if k then params[k] = v end
        end
        local r = call('strategy.attribute', params)
        if not r then return 1 end
        out(report_attribute_markdown(r, tonumber(params.top) or 10))
        return 0
    elseif cmd == 'fit' or cmd == 'scan' then
        local params = {}
        for i = 2, #args do
            local k, v = args[i]:match('^([%w_]+)=(.*)$')
            if k then params[k] = v end
        end
        local r = call(cmd == 'fit' and 'strategy.sweep' or 'strategy.scan', params)
        if not r then return 1 end
        out(cmd == 'fit' and report_sweep_markdown(r) or report_scan_markdown(r))
        return 0
    elseif cmd == 'sweep' then
        if not args[2] then err(USAGE); return 2 end
        local params = { code = args[2] }
        for i = 3, #args do
            local k, v = args[i]:match('^([%w_]+)=(.*)$')
            if k then params[k] = v end
        end
        local r = call('backtest.sweep', params)
        if not r then return 1 end
        out(report_sweep_markdown(r))
        return 0
    elseif cmd == 'backtest' then
        if not args[2] then err(USAGE); return 2 end
        local r = call('backtest.run', { code = args[2], signal = args[3] })
        if not r then return 1 end
        out(report_backtest_markdown(r))
        return 0
    elseif cmd == 'refresh' then
        if not args[2] then err(USAGE); return 2 end
        local a = call('stock.refresh', { code = args[2] })
        if not a then return 1 end
        out(string.format('%s %s 已更新：最新报告 %s，估值日期 %s', a.code, a.name or '',
            a.latest_report and a.latest_report.period or '—',
            a.valuation and a.valuation.date or '—'))
        return 0
    elseif cmd == 'list' then
        local items = call('watchlist.list', {})
        if not items then return 1 end
        if #items == 0 then out('自选为空。用 add <代码> 加入。'); return 0 end
        out('| 代码 | 名称 | 收盘 | PE(TTM) | PE 分位(全部) | PB | 股息率 | 警示 |')
        out('|---|---|---|---|---|---|---|---|')
        for _, it in ipairs(items) do
            local s = it.summary or {}
            local pe, pb = s.pe_ttm or {}, s.pb or {}
            out(string.format('| %s | %s | %s | %s | %s | %s | %s | %s |', it.code,
                s.name or '（未抓取）',
                type(s.close) == 'number' and string.format('%.2f', s.close) or '—',
                type(pe.value) == 'number' and string.format('%.1f', pe.value) or '—',
                fmt_pct(pe.percentile_all),
                type(pb.value) == 'number' and string.format('%.2f', pb.value) or '—',
                type(s.dividend_yield) == 'number' and string.format('%.2f%%', s.dividend_yield) or '—',
                s.warnings or '—'))
        end
        return 0
    elseif cmd == 'add' or cmd == 'remove' then
        if not args[2] then err(USAGE); return 2 end
        local data = call(cmd == 'add' and 'watchlist.add' or 'watchlist.remove', { code = args[2] })
        if not data then return 1 end
        out((cmd == 'add' and '已加入 ' or '已移出 ') .. data.code)
        return 0
    elseif cmd == 'call' then
        if not args[2] then err(USAGE); return 2 end
        local params = {}
        for i = 3, #args do
            local k, v = args[i]:match('^([%w_]+)=(.*)$')
            if not k then err('参数应为 key=value：' .. args[i]); return 2 end
            -- A value that parses as JSON (a number, an object for `band`) is
            -- passed as that; anything else as the string it is.
            local decoded = util_json_decode(v)
            params[k] = decoded ~= nil and decoded or v
        end
        local res = api_call(args[2], params, { host = 'cli' })
        out(util_json_encode(res) or '{}')
        return res.ok and 0 or 1
    elseif cmd == 'check' then
        local r = call('alerts.run', {})
        if not r then return 1 end
        local failed = 0
        for _, x in ipairs(r.refreshed) do
            if not x.ok then
                failed = failed + 1
                err(string.format('%s 刷新失败：%s', x.code, x.error.message))
            end
        end
        out(string.format('刷新 %d 只，新提醒 %d 条，推送 %d 条', #r.refreshed, r.new_events,
            r.push and r.push.sent or 0))
        -- A failed refresh is already printed above; the rest went on without
        -- some of its data, and that is worth a line each.
        for _, p in ipairs(r.problems or {}) do
            if p.kind ~= 'refresh' then
                err(string.format('%s 没取到（%s）：%s', p.code or '复盘', p.kind, tostring(p.error)))
            end
        end
        for _, ch in ipairs(r.push and r.push.channels or {}) do
            out(string.format('  %s：%s', ch.name, ch.ok and '成功' or tostring(ch.error)))
        end
        return failed > 0 and 1 or 0
    elseif cmd == 'alerts' then
        local items = call('alerts.list', { code = args[2], limit = 30 })
        if not items then return 1 end
        if #items == 0 then out('没有提醒。'); return 0 end
        for _, e in ipairs(items) do
            out(string.format('%s  %s %s  %s', tostring(e.created_at):sub(1, 10), e.code,
                e.name or '', e.title))
            if e.detail and e.detail ~= '' then out('    ' .. e.detail) end
        end
        return 0
    elseif cmd == 'notify-test' then
        local results = call('notify.test', {})
        if not results then return 1 end
        local bad = 0
        for _, r in ipairs(results) do
            out(string.format('%s：%s', r.name, r.ok and '成功' or tostring(r.error)))
            if not r.ok then bad = bad + 1 end
        end
        return bad > 0 and 1 or 0
    elseif cmd == 'market-refresh' then
        local st = call('market.refresh', {})
        if not st then return 1 end
        out(string.format('全市场快照已更新：%d 只，估值日期 %s，业绩期 %s（%d 只有业绩数据）',
            st.total or 0, tostring(st.trade_date), tostring(st.report_period), st.with_reports or 0))
        return 0
    elseif cmd == 'screen' then
        local params = {}
        for i = 2, #args do
            local k, v = args[i]:match('^([%w_]+)=(.*)$')
            if not k then err('参数应为 key=value：' .. args[i]); return 2 end
            params[k] = v
        end
        local res = call('market.screen', params)
        if not res then return 1 end
        local snap = res.snapshot or {}
        out(string.format('%d 只符合条件（共 %d 只，估值 %s，业绩 %s），按 %s %s 排序，显示前 %d 只',
            res.matched or 0, snap.total or 0, tostring(snap.trade_date), tostring(snap.report_period),
            res.sort, res.order, #res.rows))
        if #res.rows == 0 then return 0 end
        out('')
        out('| 代码 | 名称 | 行业 | 市值 | PE(TTM) | PB | ROE | 营收同比 | 净利同比 | 毛利率 | 现金流/EPS |')
        out('|---|---|---|---|---|---|---|---|---|---|---|')
        local function n(v, d)
            if type(v) ~= 'number' then return '—' end
            return string.format('%.' .. (d or 2) .. 'f', v)
        end
        -- A missing value prints as a dash and nothing else: a bank has no
        -- gross margin, and "—%" reads as a number that failed to format.
        local function pc(v) return type(v) == 'number' and report_pct(v) or '—' end
        for _, r in ipairs(res.rows) do
            out(string.format('| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |',
                r.code, r.name or '', r.industry or '',
                type(r.market_cap) == 'number' and report_money(r.market_cap) or '—',
                n(r.pe_ttm, 1), n(r.pb), pc(r.roe), pc(r.revenue_yoy),
                pc(r.np_parent_yoy), pc(r.gross_margin), n(r.ocf_to_eps)))
        end
        return 0
    elseif cmd == 'insight' then
        if not args[2] then err(USAGE); return 2 end
        local ins
        if args[3] ~= 'refresh' then
            local res = api_call('insight.get', { code = args[2] }, { host = 'cli' })
            if res.ok then ins = res.data end
        end
        if not ins then
            ins = call('insight.generate', { code = args[2] })
            if not ins then return 1 end
        end
        local r = ins.result
        out(string.format('# %s（%s）大模型解读', ins.name or args[2], ins.code or args[2]))
        out(string.format('%s %s · %s · 依据 %s 报告', ins.provider or '', ins.model or '',
            tostring(ins.created_at), tostring(ins.report_period)))
        out('')
        if not r then
            out('模型没有按格式回答：' .. tostring(ins.parse_error))
            out(tostring(ins.raw))
        else
            out(r.summary)
            out('')
            out(string.format('护城河：%s（%s）', r.moat.strength, table.concat(r.moat.sources, '、')))
            local function section(title, items)
                if #items == 0 then return end
                out('')
                out('## ' .. title)
                for _, x in ipairs(items) do out('- ' .. x) end
            end
            section('证据', r.moat.evidence)
            section('变化', r.changes)
            section('风险', r.risks)
            section('值得核实的问题', r.questions)
        end
        if #(ins.unverified or {}) > 0 then
            out('')
            out('⚠ 未在事实中找到的数字（勿直接采信）：' .. table.concat(ins.unverified, '、'))
        end
        return 0
    elseif cmd == 'ask' then
        if not args[2] or not args[3] then err(USAGE); return 2 end
        local words = {}
        for i = 3, #args do words[#words + 1] = args[i] end
        local res = call('insight.ask', { code = args[2], question = table.concat(words, ' ') })
        if not res then return 1 end
        out(res.answer)
        if #(res.unverified or {}) > 0 then
            out('')
            out('⚠ 未在事实中找到的数字（勿直接采信）：' .. table.concat(res.unverified, '、'))
        end
        return 0
    elseif cmd == 'commands' then
        for _, c in ipairs(api_list()) do
            out(string.format('%-20s %-6s %-36s %s', c.name, c.method or '', c.path or '', c.summary or ''))
        end
        return 0
    end
    err(USAGE)
    return cmd and 2 or 0
end

local function __init()
    assert(xnet.init())
    xtimer.init(16)
    local ok, e = engine_start()
    if not ok then
        err('启动失败: ' .. tostring(e))
        xthread.stop(1)
        return
    end
    sched_spawn('cli', function()
        local okr, code = pcall(run)
        if not okr then
            err('出错: ' .. tostring(code))
            code = 1
        end
        xthread.stop(code or 0)
    end)
end

local function __uninit()
    engine_stop()
    xnet.uninit()
end

return { __thread_handle = function() end, __init = __init, __uninit = __uninit }
