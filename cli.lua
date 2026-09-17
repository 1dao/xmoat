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
