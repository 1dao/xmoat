-- engine/commands.lua — every command a client can call.
--
-- Exports: commands_install
--
-- Thin by design: validate, call the module that owns the work, return its
-- value. The HTTP paths are listed here, next to each command, so the route a
-- client uses and the command it reaches are read in one place; docs/API.md
-- describes the same table for people.

local function code_param(doc)
    return { type = 'string', required = true, doc = doc or '6 位股票代码，如 600519' }
end

-- A code from a client, normalised. Returns the 6-digit code or nil, message.
local function security_code(input)
    local sec, err = source_em_security(input)
    if not sec then return nil, err end
    return sec.code
end

local function install_system()
    api_define({
        name = 'system.info', method = 'GET', path = '/api/v1/system/info',
        summary = '版本、数据源和当前配置',
        handler = function()
            return {
                name = 'xmoat', version = engine_version,
                analysis_schema = analysis_schema,
                data_source = '东方财富',
                dcf = { discount_rate = cfg_num('DCF_DISCOUNT_RATE', 10),
                        terminal_growth = cfg_num('DCF_TERMINAL_GROWTH', 3),
                        years = cfg_int('DCF_YEARS', 10) },
                thresholds = checks_thresholds,
                calendar = calendar_status(),
                time = util_now_iso(),
            }
        end,
    })

    api_define({
        name = 'system.commands', method = 'GET', path = '/api/v1/system/commands',
        summary = '所有命令及其参数',
        handler = function() return util_json_array(api_list()) end,
    })
end

local function install_watchlist()
    api_define({
        name = 'watchlist.list', method = 'GET', path = '/api/v1/watchlist',
        summary = '自选列表，每项附带估值和检查摘要',
        handler = function()
            local out = {}
            for _, e in ipairs(watch_list()) do
                out[#out + 1] = { code = e.code, added_at = e.added_at, note = e.note,
                                  band = e.band and util_copy(e.band) or nil,
                                  summary = stock_summary(e.code) }
            end
            return util_json_array(out)
        end,
    })

    api_define({
        name = 'watchlist.add', method = 'POST', path = '/api/v1/watchlist',
        summary = '加入自选（不会自动抓取数据，随后调用 stock.refresh）',
        params = {
            code = code_param(),
            note = { type = 'string', doc = '备注' },
            band = { type = 'object', doc = '合理估值区间 {metric, low, high}' },
            position = { type = 'object', doc = '持仓 {shares, cost}；设置后才推送点位与技术面提醒' },
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            return watch_add(code, { note = p.note, band = p.band, position = p.position })
        end,
    })

    api_define({
        name = 'watchlist.update', method = 'PATCH', path = '/api/v1/watchlist/:code',
        summary = '修改备注、合理估值区间或持仓；传 null 清除',
        params = {
            code = code_param(),
            note = { type = 'string', nullable = true },
            band = { type = 'object', nullable = true,
                     doc = '{metric: pe_ttm|pb|ps_ttm|pcf_ttm, low, high}，字段为 null 表示清除' },
            position = { type = 'object', nullable = true,
                         doc = '{shares, cost}；设置后才推送点位与技术面提醒，null 表示清仓' },
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            return watch_update(code, { note = p.note, band = p.band, position = p.position })
        end,
    })

    api_define({
        name = 'watchlist.remove', method = 'DELETE', path = '/api/v1/watchlist/:code',
        summary = '移出自选（已抓取的数据保留）',
        params = { code = code_param() },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            local ok, ecode, emsg = watch_remove(code)
            if not ok then return nil, ecode, emsg end
            return { code = code, removed = true }
        end,
    })

    api_define({
        name = 'watchlist.refresh', method = 'POST', path = '/api/v1/watchlist/refresh',
        summary = '依次刷新全部自选股；发现的提醒在后台推送',
        handler = function()
            local results = {}
            for _, e in ipairs(watch_list()) do
                local rec, ecode, emsg = stock_refresh(e.code)
                results[#results + 1] = rec and { code = e.code, ok = true }
                    or { code = e.code, ok = false, error = { code = ecode, message = emsg } }
            end
            alerts_flush_later()
            return util_json_array(results)
        end,
    })
end

local function install_stock()
    api_define({
        name = 'stock.get', method = 'GET', path = '/api/v1/stocks/:code',
        summary = '一只股票的完整分析（来自已保存的数据，不联网）',
        params = { code = code_param() },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            return stock_analysis(code)
        end,
    })

    api_define({
        name = 'stock.refresh', method = 'POST', path = '/api/v1/stocks/:code/refresh',
        summary = '从数据源抓取并保存，返回新的分析',
        params = { code = code_param() },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            local rec, ecode, emsg = stock_refresh(code)
            if not rec then return nil, ecode, emsg end
            alerts_flush_later()
            return stock_analysis(code)
        end,
    })

    api_define({
        name = 'stock.valuation', method = 'GET', path = '/api/v1/stocks/:code/valuation',
        summary = '某个估值指标的历史序列，用于画图',
        params = {
            code = code_param(),
            metric = { type = 'string', enum = { 'pe_ttm', 'pb', 'ps_ttm', 'pcf_ttm', 'close', 'market_cap' },
                       doc = '默认 pe_ttm' },
            years = { type = 'number', doc = '最近几年，不传为全部' },
            max_points = { type = 'integer', doc = '最多返回多少个点，默认 800' },
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            local years = p.years
            if years and years <= 0 then return nil, 'bad_request', 'years 必须大于 0' end
            local maxp = p.max_points
            if maxp and (maxp < 10 or maxp > 5000) then
                return nil, 'bad_request', 'max_points 应在 10 到 5000 之间'
            end
            return stock_valuation_series(code, p.metric or 'pe_ttm', years, maxp)
        end,
    })

    api_define({
        name = 'stock.reports', method = 'GET', path = '/api/v1/stocks/:code/reports',
        summary = '已保存的定期报告主要指标（原始口径）',
        params = {
            code = code_param(),
            period_type = { type = 'string', enum = { 'FY', 'H1', 'Q1', 'Q3', 'all' }, doc = '默认 all' },
            limit = { type = 'integer', doc = '默认 40' },
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            local rec, lerr = stock_load(code)
            if lerr then return nil, 'internal', lerr end
            if not rec then return nil, 'not_fetched', code .. ' 还没有获取过数据，先刷新' end
            local want, limit, out = p.period_type or 'all', p.limit or 40, {}
            for _, r in ipairs(rec.reports or {}) do
                if want == 'all' or r.period_type == want then
                    out[#out + 1] = r
                    if #out >= limit then break end
                end
            end
            return util_json_array(out)
        end,
    })
end

local function install_alerts()
    api_define({
        name = 'alerts.list', method = 'GET', path = '/api/v1/alerts',
        summary = '提醒记录，新的在前',
        params = {
            code = { type = 'string', doc = '只看这只股票' },
            limit = { type = 'integer', doc = '默认 50，最多 500' },
            after_seq = { type = 'integer', doc = '只返回序号大于它的，用于轮询新提醒' },
        },
        handler = function(p)
            local code
            if p.code then
                local err
                code, err = security_code(p.code)
                if not code then return nil, 'bad_request', err end
            end
            local limit = p.limit or 50
            if limit < 1 or limit > 500 then return nil, 'bad_request', 'limit 应在 1 到 500 之间' end
            return util_json_array(alerts_list({ code = code, limit = limit, after_seq = p.after_seq }))
        end,
    })

    api_define({
        name = 'alerts.run', method = 'POST', path = '/api/v1/alerts/run',
        summary = '立即检查：刷新全部自选股，记录变化并推送（与定时检查相同）',
        handler = function() return alerts_run() end,
    })

    api_define({
        name = 'notify.channels', method = 'GET', path = '/api/v1/notify/channels',
        summary = '已配置的推送渠道（不含密钥）',
        handler = function()
            local out = {}
            for _, ch in ipairs(notify_channels()) do
                out[#out + 1] = { kind = ch.kind, name = ch.name }
            end
            return util_json_array(out)
        end,
    })

    api_define({
        name = 'notify.test', method = 'POST', path = '/api/v1/notify/test',
        summary = '向每个已配置的渠道发一条测试消息',
        handler = function()
            if #notify_channels() == 0 then
                return nil, 'bad_request', '还没有配置推送渠道，见 xmoat.local.cfg.example'
            end
            local sample = { {
                id = 'test', code = '000000', name = 'xmoat', kind = 'check', status = 'pass',
                title = '推送测试', detail = '收到这条消息，说明这个渠道配置正确。',
            } }
            local results = notify_send({
                title = 'xmoat 推送测试',
                markdown = report_events_markdown(sample, { title = 'xmoat 推送测试' }),
                text = report_events_text(sample, { title = 'xmoat 推送测试' }),
                events = sample,
            })
            return util_json_array(results)
        end,
    })

    api_define({
        name = 'schedule.status', method = 'GET', path = '/api/v1/schedule',
        summary = '定时检查的配置、上次运行和下次运行时间',
        handler = function() return schedule_status() end,
    })
end

local function install_insight()
    api_define({
        name = 'llm.status', method = 'GET', path = '/api/v1/llm',
        summary = '大模型是否已配置，以及用的是哪个（不含密钥）',
        handler = function() return llm_status() end,
    })

    api_define({
        name = 'insight.get', method = 'GET', path = '/api/v1/stocks/:code/insight',
        summary = '已保存的大模型解读（不联网）',
        params = { code = code_param() },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            local ins = insight_get(code)
            if not ins then return nil, 'not_found', '还没有生成过解读' end
            return ins
        end,
    })

    api_define({
        name = 'insight.generate', method = 'POST', path = '/api/v1/stocks/:code/insight',
        summary = '请大模型基于已算好的事实生成护城河解读（会产生费用）',
        params = { code = code_param() },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            return insight_generate(code)
        end,
    })

    api_define({
        name = 'insight.ask', method = 'POST', path = '/api/v1/stocks/:code/ask',
        summary = '就这只股票提问，回答只依据已算好的事实（会产生费用）',
        params = {
            code = code_param(),
            question = { type = 'string', required = true, doc = '问题，500 字以内' },
            history = { type = 'object', doc = '之前的对话 [{role, content}]，最多 10 条' },
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            if (utf8.len(p.question) or #p.question) > 500 then
                return nil, 'bad_request', '问题太长，请控制在 500 字以内'
            end
            local history = {}
            if p.history then
                for i, m in ipairs(p.history) do
                    if i > 10 then break end
                    if type(m) == 'table' then history[#history + 1] = m end
                end
            end
            return insight_ask(code, p.question, history)
        end,
    })
end

-- A comma-separated list of numbers, as a grid axis arrives from a client.
local function number_list(text, label, lo, hi)
    if text == nil then return nil end
    local out = {}
    for part in tostring(text):gmatch('[^,%s]+') do
        local v = tonumber(part)
        if not v then return nil, label .. ' 里的 ' .. part .. ' 不是数字' end
        if (lo and v < lo) or (hi and v > hi) then
            return nil, string.format('%s 应在 %s 到 %s 之间', label, tostring(lo), tostring(hi))
        end
        out[#out + 1] = v
    end
    if #out == 0 then return nil, label .. ' 是空的' end
    if #out > 20 then return nil, label .. ' 最多 20 个值' end
    return out
end

local function install_backtest()
    api_define({
        name = 'backtest.run', method = 'GET', path = '/api/v1/stocks/:code/backtest',
        summary = '在这只股票自己的历史上回放引擎的信号：方向胜率与止盈止损命中率',
        params = {
            code = code_param(),
            signal = { type = 'string', enum = { 'value', 'trend', 'value_trend', 'band' },
                       doc = '默认 value（估值分位）' },
            percentile = { type = 'number', doc = '估值分位阈值，默认 25' },
            take_profit = { type = 'number', doc = '止盈百分比，默认 20' },
            stop_loss = { type = 'number', doc = '止损百分比，默认 10' },
            horizon = { type = 'integer', doc = '止盈止损最多观察多少个交易日，默认 250' },
            cooldown = { type = 'integer', doc = '两次信号之间至少间隔多少个交易日，默认 20' },
            offline = { type = 'boolean', doc = '只用本地行情缓存' },
        },
        handler = function(p)
            if p.percentile and (p.percentile <= 0 or p.percentile >= 100) then
                return nil, 'bad_request', 'percentile 应在 0 到 100 之间'
            end
            if p.take_profit and (p.take_profit <= 0 or p.take_profit > 500) then
                return nil, 'bad_request', 'take_profit 应在 0 到 500 之间'
            end
            if p.stop_loss and (p.stop_loss <= 0 or p.stop_loss >= 100) then
                return nil, 'bad_request', 'stop_loss 应在 0 到 100 之间'
            end
            if p.horizon and (p.horizon < 5 or p.horizon > 1000) then
                return nil, 'bad_request', 'horizon 应在 5 到 1000 之间'
            end
            if p.cooldown and (p.cooldown < 1 or p.cooldown > 250) then
                return nil, 'bad_request', 'cooldown 应在 1 到 250 之间'
            end
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            local res, ecode, emsg = backtest_run(code, {
                signal = p.signal, percentile = p.percentile,
                take_profit = p.take_profit, stop_loss = p.stop_loss,
                horizon = p.horizon, cooldown = p.cooldown, offline = p.offline,
            })
            if not res then return nil, ecode or 'internal', emsg or '回测失败' end
            return res
        end,
    })
end

local function install_review()
    api_define({
        name = 'review.daily', method = 'GET', path = '/api/v1/review',
        summary = '当日复盘三段：大盘与 regime、板块结构、自选表现',
        params = {
            offline = { type = 'boolean', doc = '只用本地缓存，不联网' },
            force = { type = 'boolean', doc = '强制刷新指数与板块行情' },
            top = { type = 'integer', doc = '领涨/领跌板块各取几个，默认 5' },
        },
        handler = function(p)
            if p.top and (p.top < 1 or p.top > 20) then
                return nil, 'bad_request', 'top 应在 1 到 20 之间'
            end
            return review_build({ offline = p.offline, force = p.force, top = p.top })
        end,
    })

    api_define({
        name = 'review.sectors', method = 'GET', path = '/api/v1/review/sectors',
        summary = '板块涨跌表（东方财富行业板块或概念板块）',
        params = {
            kind = { type = 'string', enum = { 'industry', 'concept' }, doc = '默认 industry' },
            offline = { type = 'boolean', doc = '只用本地缓存，不联网' },
            force = { type = 'boolean', doc = '强制重新抓取' },
        },
        handler = function(p)
            local doc, ecode, emsg = review_sectors({ kind = p.kind, offline = p.offline, force = p.force })
            if not doc then
                if p.offline then return nil, 'not_fetched', '本地没有板块行情缓存' end
                return nil, ecode or 'upstream', emsg or '板块行情获取失败'
            end
            return doc
        end,
    })
end

local function install_market_list()
    api_define({
        name = 'market.list', method = 'GET', path = '/api/v1/market/list',
        summary = '全市场股票列表：代码、名称、行业、市值（来自本地快照，不联网）',
        params = {
            limit = { type = 'integer', doc = '默认全部（约 5500 只）' },
            board = { type = 'string', doc = '板块：main、gem、star、bj' },
            industry = { type = 'string', doc = '行业名包含' },
            keyword = { type = 'string', doc = '名称或代码包含' },
            include_st = { type = 'boolean', doc = '包含 ST（默认排除）' },
        },
        handler = function(p)
            if p.limit and (p.limit < 1 or p.limit > 6000) then
                return nil, 'bad_request', 'limit 应在 1 到 6000 之间'
            end
            local res, ecode, emsg = market_screen({
                limit = p.limit or 6000,
                boards = p.board and { p.board } or nil,
                industry = p.industry, keyword = p.keyword,
                include_st = p.include_st,
                sort = 'market_cap', order = 'desc',
            })
            if not res then return nil, ecode or 'not_fetched', emsg or '还没有全市场快照' end
            local out = {}
            for _, r in ipairs(res.rows or {}) do
                out[#out + 1] = { code = r.code, name = r.name, industry = r.industry,
                                  board = r.board, st = r.st, close = r.close,
                                  market_cap = r.market_cap }
            end
            return { trade_date = res.snapshot and res.snapshot.trade_date,
                     fetched_at = res.snapshot and res.snapshot.fetched_at,
                     matched = res.matched, count = #out,
                     rows = util_json_array(out) }
        end,
    })
end

local function install_quote()
    api_define({
        name = 'quote.get', method = 'GET', path = '/api/v1/stocks/:code/quotes',
        summary = '日线行情（前复权）。本地有且够新就直接返回，否则先补最新的几天',
        params = {
            code = code_param('6 位股票代码，或 idx:000001 这样的指数'),
            days = { type = 'integer', doc = '最多返回多少个交易日，默认 250' },
            offline = { type = 'boolean', doc = '只读本地缓存，不联网' },
        },
        handler = function(p)
            if p.days and (p.days < 1 or p.days > 5000) then
                return nil, 'bad_request', 'days 应在 1 到 5000 之间'
            end
            local doc, ecode, emsg = quote_series(p.code, { offline = p.offline })
            if not doc then
                if p.offline then return nil, 'not_fetched', '本地没有行情缓存，先调用 quote.refresh' end
                return nil, ecode or 'upstream', emsg or '行情获取失败'
            end
            return quote_view(doc, p.days or 250)
        end,
    })

    api_define({
        name = 'quote.refresh', method = 'POST', path = '/api/v1/stocks/:code/quotes/refresh',
        summary = '抓取日线行情：已有缓存时只取最后一天之后的部分',
        params = {
            code = code_param('6 位股票代码，或 idx:000001 这样的指数'),
            full = { type = 'boolean', doc = '忽略缓存，重新抓取全部历史' },
        },
        handler = function(p)
            local doc, ecode, emsg = quote_refresh(p.code, { full = p.full })
            if not doc then return nil, ecode or 'upstream', emsg or '行情获取失败' end
            return quote_view(doc, 0)
        end,
    })
end

local function install_market()
    api_define({
        name = 'market.status', method = 'GET', path = '/api/v1/market',
        summary = '全市场快照的日期、覆盖数量和是否正在刷新',
        handler = function() return market_status() end,
    })

    api_define({
        name = 'market.refresh', method = 'POST', path = '/api/v1/market/refresh',
        summary = '抓取全市场快照：当日估值 + 最近一个年报的业绩（约 15 次请求）',
        handler = function() return market_refresh() end,
    })

    api_define({
        name = 'market.screen', method = 'GET', path = '/api/v1/market/screen',
        summary = '按条件筛选全市场；所有条件都可省略',
        params = {
            roe_min = { type = 'number', doc = 'ROE 下限（%，年报加权）' },
            roe_max = { type = 'number', doc = 'ROE 上限' },
            pe_min = { type = 'number', doc = 'PE(TTM) 下限' },
            pe_max = { type = 'number', doc = 'PE(TTM) 上限；设置后自动排除亏损股' },
            pb_max = { type = 'number', doc = 'PB 上限' },
            ps_max = { type = 'number', doc = 'PS(TTM) 上限' },
            cap_min = { type = 'number', doc = '总市值下限（亿元）' },
            cap_max = { type = 'number', doc = '总市值上限（亿元）' },
            revenue_yoy_min = { type = 'number', doc = '营收同比下限（%）' },
            np_yoy_min = { type = 'number', doc = '归母净利润同比下限（%）' },
            gross_margin_min = { type = 'number', doc = '毛利率下限（%）' },
            ocf_to_eps_min = { type = 'number', doc = '每股经营现金流 / 每股收益 的下限' },
            industry = { type = 'string', doc = '行业名包含' },
            keyword = { type = 'string', doc = '名称或代码包含' },
            boards = { type = 'string', doc = '板块，逗号分隔：main、gem、star、bj' },
            include_st = { type = 'boolean', doc = '包含 ST（默认排除）' },
            sort = { type = 'string', doc = '排序字段，默认 roe' },
            order = { type = 'string', enum = { 'asc', 'desc' }, doc = '默认 desc' },
            limit = { type = 'integer', doc = '返回条数，默认 50，最多 500' },
        },
        handler = function(p)
            if p.sort and not market_sort_keys[p.sort] then
                local names = {}
                for k in pairs(market_sort_keys) do names[#names + 1] = k end
                table.sort(names)
                return nil, 'bad_request', 'sort 只能是 ' .. table.concat(names, '、')
            end
            if p.limit and (p.limit < 1 or p.limit > 500) then
                return nil, 'bad_request', 'limit 应在 1 到 500 之间'
            end
            local filters = util_copy(p)
            filters.boards = nil
            if p.boards then
                local list = {}
                for b in tostring(p.boards):gmatch('[^,%s]+') do
                    if b ~= 'main' and b ~= 'gem' and b ~= 'star' and b ~= 'bj' and b ~= 'other' then
                        return nil, 'bad_request', 'boards 只能是 main、gem、star、bj'
                    end
                    list[#list + 1] = b
                end
                filters.boards = list
            end
            return market_screen(filters)
        end,
    })
end

local function install_sweep()
    api_define({
        name = 'backtest.sweep', method = 'GET', path = '/api/v1/stocks/:code/backtest/sweep',
        summary = '参数网格：横盘后上穿均线，哪一组均线、幅度与横盘振幅在这只股票的历史上最好',
        params = {
            code = code_param(),
            horizon = { type = 'integer', doc = '按持有多少个交易日排名，默认 60' },
            ma_days = { type = 'string', doc = '均线窗口（交易日），逗号分隔，默认 30,40,50,60,70' },
            above_pct = { type = 'string', doc = '高出均线的幅度 %，逗号分隔，默认 3,4,5,6,7,8,10' },
            flat_max = { type = 'string', doc = '横盘振幅上限 %（最高价比最低价高出多少），逗号分隔，默认 8,10,12,15,20' },
            flat_lookback = { type = 'integer', doc = '横盘看前多少个交易日，默认 BREAKOUT_FLAT_LOOKBACK（40，8 周）' },
            min_day_gain = { type = 'number', doc = '当天涨幅下限 %，默认 0（不要求）' },
            cooldown = { type = 'integer', doc = '两次信号之间的最小间隔，默认 20' },
            take_profit = { type = 'number', doc = '止盈 %，默认 20' },
            stop_loss = { type = 'number', doc = '止损 %，默认 10' },
            objective = { type = 'string', enum = { 'median', 'avg', 'win_rate' },
                          doc = '按什么排名，默认 median（中位数收益）' },
            min_entries = { type = 'integer', doc = '至少触发多少次才算数，默认 10' },
            min_win_rate = { type = 'number', doc = '胜率下限 %' },
            max_worst = { type = 'number', doc = '最差一笔的下限 %，如 -15' },
            max_sl = { type = 'integer', doc = '先到止损的次数上限' },
            offline = { type = 'boolean', doc = '只用本地行情缓存' },
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            if p.horizon and (p.horizon < 5 or p.horizon > 500) then
                return nil, 'bad_request', 'horizon 应在 5 到 500 之间'
            end
            if p.flat_lookback and (p.flat_lookback < 5 or p.flat_lookback > 250) then
                return nil, 'bad_request', 'flat_lookback 应在 5 到 250 之间'
            end
            local mas, merr = number_list(p.ma_days, 'ma_days', 2, 500)
            if merr then return nil, 'bad_request', merr end
            local aboves, aerr = number_list(p.above_pct, 'above_pct', 0, 100)
            if aerr then return nil, 'bad_request', aerr end
            local flats, ferr = number_list(p.flat_max, 'flat_max', 0, 50)
            if ferr then return nil, 'bad_request', ferr end
            local res, ecode, emsg = backtest_sweep(code, {
                horizon = p.horizon, ma_days = mas, above_pct = aboves, flat_max = flats,
                flat_lookback = p.flat_lookback, min_day_gain = p.min_day_gain,
                cooldown = p.cooldown, take_profit = p.take_profit, stop_loss = p.stop_loss,
                objective = p.objective, min_entries = p.min_entries,
                min_win_rate = p.min_win_rate, max_worst = p.max_worst, max_sl = p.max_sl,
                offline = p.offline,
            })
            if not res then return nil, ecode or 'internal', emsg or '网格回测失败' end
            return res
        end,
    })
end

-- The grid axes and the rule's own numbers, shared by the two strategy
-- commands so they cannot drift apart.
local function strategy_params(with_grid)
    local p = {
        codes = { type = 'string', doc = '股票代码，逗号分隔；给了就用它，不看 universe' },
        universe = { type = 'string', enum = { 'watchlist', 'screen', 'market' },
                     doc = '默认 watchlist；screen 按下面的条件筛；market 是全市场每一只' },
        limit = { type = 'integer', doc = '最多看多少只，默认 30；universe=market 时可到 6000（全市场）' },
        bars_days = { type = 'integer', doc = '每只股票抓多少个交易日，默认按 QUOTE_MAX_DAYS' },
        force = { type = 'boolean', doc = '忽略缓存，重新抓一遍' },
        workers = { type = 'integer', doc = '并发连接数，默认 TDX_CONNECTIONS' },
        roe_min = { type = 'number', doc = 'universe=screen 时的筛选条件' },
        pe_max = { type = 'number' }, pb_max = { type = 'number' },
        cap_min = { type = 'number', doc = '总市值下限（亿元）' },
        industry = { type = 'string' },
        include_st = { type = 'boolean' },
        flat_lookback = { type = 'integer', doc = '横盘看前多少个交易日，默认 BREAKOUT_FLAT_LOOKBACK（40，8 周）' },
        min_day_gain = { type = 'number', doc = '当天涨幅下限 %，默认 0' },
        month_up = { type = 'boolean', doc = '要求个股月线向上（收盘在上升的 10 月均线之上），默认 BREAKOUT_MONTH_UP（开）' },
        offline = { type = 'boolean', doc = '只用本地行情缓存，不联网' },
        price_source = { type = 'string', enum = { 'tdx', 'em' },
                         doc = '行情来源，默认 tdx（通达信协议，可并发）' },
    }
    if with_grid then
        p.horizon = { type = 'integer', doc = '按持有多少个交易日排名，默认 60' }
        p.ma_days = { type = 'string', doc = '均线窗口，逗号分隔，默认 30,40,50,60,70' }
        p.above_pct = { type = 'string', doc = '高出均线的幅度 %，逗号分隔，默认 3,4,5,6,7,8,10' }
        p.flat_max = { type = 'string', doc = '横盘振幅上限 %，逗号分隔，默认 8,10,12,15,20' }
        p.cooldown = { type = 'integer', doc = '两次信号之间的最小间隔，默认 20' }
        p.take_profit = { type = 'number', doc = '止盈 %，默认 20' }
        p.stop_loss = { type = 'number', doc = '止损 %，默认 10' }
        p.objective = { type = 'string', enum = { 'median', 'avg', 'win_rate' }, doc = '默认 median' }
        p.min_entries = { type = 'integer', doc = '至少触发多少次才算数，默认 10' }
        p.min_win_rate = { type = 'number', doc = '胜率下限 %' }
        p.max_worst = { type = 'number', doc = '最差一笔的下限 %，如 -15' }
        p.max_sl = { type = 'integer', doc = '先到止损的次数上限' }
    else
        p.ma_days = { type = 'integer', doc = '均线窗口（交易日），默认 BREAKOUT_MA_DAYS（50，10 周）' }
        p.ma_weeks = { type = 'number', doc = '均线窗口按周说，一周 5 个交易日；和 ma_days 只给一个' }
        p.flat_weeks = { type = 'number', doc = '横盘按周说；和 flat_lookback 只给一个' }
        p.above_pct = { type = 'number', doc = '上穿时高出均线的幅度 %，默认 BREAKOUT_ABOVE_PCT（0，即上穿即可）' }
        p.flat_max = { type = 'number', doc = '横盘振幅上限 %，默认 BREAKOUT_FLAT_MAX（10）' }
        p.days = { type = 'integer', doc = '最近几个交易日内出现的信号都算，默认 1' }
        p.rule = { type = 'string', enum = { 'breakout' }, doc = '内置规则，见 strategy.rules；默认 breakout' }
        p.bull_only = { type = 'boolean',
                        doc = '沪深300 不在多头的日子，信号标成 held、不推送，默认 BREAKOUT_BULL_ONLY（开）' }
        p.cooldown = { type = 'integer',
                       doc = '两次信号至少隔几个交易日，默认 BACKTEST_COOLDOWN（20），即只看突破第一天；1 = 条件成立的每一天' }
        p.record = { type = 'boolean',
                     doc = '按内置默认参数扫描时，把新发现的记入信号记录（signals.list）并推送' }
    end
    return p
end

-- codes / screen filters, shared too.
local function strategy_common(p)
    local codes
    if p.codes then
        codes = {}
        for c in tostring(p.codes):gmatch('[^,%s]+') do codes[#codes + 1] = c end
        if #codes == 0 then codes = nil end
    end
    return {
        codes = codes, universe = p.universe, limit = p.limit,
        price_source = p.price_source, bars_days = p.bars_days,
        filters = { roe_min = p.roe_min, pe_max = p.pe_max, pb_max = p.pb_max,
                    cap_min = p.cap_min, industry = p.industry, include_st = p.include_st,
                    sort = 'roe', order = 'desc' },
        flat_lookback = p.flat_lookback, min_day_gain = p.min_day_gain,
        month_up = p.month_up, offline = p.offline,
    }
end

local function install_strategy()
    api_define({
        name = 'strategy.sweep', method = 'GET', path = '/api/v1/strategy/sweep',
        summary = '在一组股票上一起拟合参数：横盘后上穿均线，哪组均线、幅度与横盘振幅最好',
        params = strategy_params(true),
        handler = function(p)
            if p.limit and (p.limit < 1 or p.limit > 6000) then
                return nil, 'bad_request', 'limit 应在 1 到 6000 之间'
            end
            if p.bars_days and (p.bars_days < 60 or p.bars_days > 5000) then
                return nil, 'bad_request', 'bars_days 应在 60 到 5000 之间'
            end
            if p.horizon and (p.horizon < 5 or p.horizon > 500) then
                return nil, 'bad_request', 'horizon 应在 5 到 500 之间'
            end
            local mas, merr = number_list(p.ma_days, 'ma_days', 2, 500)
            if merr then return nil, 'bad_request', merr end
            local aboves, aerr = number_list(p.above_pct, 'above_pct', 0, 100)
            if aerr then return nil, 'bad_request', aerr end
            local flats, ferr = number_list(p.flat_max, 'flat_max', 0, 50)
            if ferr then return nil, 'bad_request', ferr end
            local opts = strategy_common(p)
            opts.horizon, opts.ma_days, opts.above_pct, opts.flat_max = p.horizon, mas, aboves, flats
            opts.cooldown, opts.take_profit, opts.stop_loss = p.cooldown, p.take_profit, p.stop_loss
            opts.objective, opts.min_entries = p.objective, p.min_entries
            opts.min_win_rate, opts.max_worst, opts.max_sl = p.min_win_rate, p.max_worst, p.max_sl
            local res, ecode, emsg = strategy_sweep(opts)
            if not res then return nil, ecode or 'internal', emsg or '网格回测失败' end
            return res
        end,
    })

    api_define({
        name = 'strategy.prefetch', method = 'POST', path = '/api/v1/strategy/prefetch',
        summary = '批量把一组股票的日线抓到本地（通达信协议，多连接并行）',
        params = strategy_params(false),
        handler = function(p)
            if p.limit and (p.limit < 1 or p.limit > 6000) then
                return nil, 'bad_request', 'limit 应在 1 到 6000 之间'
            end
            if p.bars_days and (p.bars_days < 60 or p.bars_days > 5000) then
                return nil, 'bad_request', 'bars_days 应在 60 到 5000 之间'
            end
            local opts = strategy_common(p)
            local list, kind = strategy_universe(opts)
            if #list == 0 then return nil, 'bad_request', '没有可用的股票' end
            local codes = {}
            for _, item in ipairs(list) do codes[#codes + 1] = item.code end
            local t0 = util_now_ms()
            local res = quote_prefetch(codes, {
                source = p.price_source or cfg_get('STRATEGY_PRICE_SOURCE', 'tdx'),
                max_days = p.bars_days, force = p.force, workers = p.workers,
            })
            res.ms = util_now_ms() - t0
            res.universe = kind
            return res
        end,
    })

    api_define({
        name = 'strategy.attribute', method = 'GET', path = '/api/v1/strategy/attribute',
        summary = '按行业、板块、地域分组看这条规则在哪里更有效（每组和自己的基准比）',
        params = (function()
            local p = strategy_params(false)
            p.horizon = { type = 'integer', doc = '持有多少个交易日，默认 60' }
            p.cooldown = { type = 'integer', doc = '两次信号之间的最小间隔，默认 20' }
            p.min_signals = { type = 'integer', doc = '一组至少多少次信号才参与排名，默认 30' }
            p.group = { type = 'string', enum = { 'industry', 'board', 'region' },
                        doc = '只看某一种分组；默认三种都给' }
            p.top = { type = 'integer', doc = '每种分组返回前后各几行，默认全给' }
            return p
        end)(),
        handler = function(p)
            if p.limit and (p.limit < 1 or p.limit > 6000) then
                return nil, 'bad_request', 'limit 应在 1 到 6000 之间'
            end
            if p.horizon and (p.horizon < 5 or p.horizon > 500) then
                return nil, 'bad_request', 'horizon 应在 5 到 500 之间'
            end
            if p.min_signals and (p.min_signals < 5 or p.min_signals > 100000) then
                return nil, 'bad_request', 'min_signals 应在 5 到 100000 之间'
            end
            local opts = strategy_common(p)
            opts.ma_days, opts.above_pct, opts.flat_max = p.ma_days, p.above_pct, p.flat_max
            opts.horizon, opts.cooldown = p.horizon, p.cooldown
            opts.min_signals, opts.group = p.min_signals, p.group
            local res, ecode, emsg = strategy_attribute(opts)
            if not res then return nil, ecode or 'internal', emsg or '分组归因失败' end
            return res
        end,
    })

    api_define({
        name = 'groups.regions', method = 'GET', path = '/api/v1/groups/regions',
        summary = '股票的地域归属（东方财富地域板块），首次会抓一次并缓存',
        params = {
            refresh = { type = 'boolean', doc = '强制重新抓取' },
            offline = { type = 'boolean', doc = '只读缓存' },
        },
        handler = function(p)
            local doc, ecode, emsg
            if p.refresh then doc, ecode, emsg = groups_regions_refresh()
            else doc, ecode, emsg = groups_regions({ offline = p.offline }) end
            if not doc then return nil, ecode or 'upstream', emsg or '地域映射获取失败' end
            local counts = {}
            for _, region in pairs(doc.by_code or {}) do
                counts[region] = (counts[region] or 0) + 1
            end
            local rows = {}
            for region, n in pairs(counts) do rows[#rows + 1] = { region = region, stocks = n } end
            table.sort(rows, function(a, b) return a.stocks > b.stocks end)
            return { fetched_at = doc.fetched_at, regions = #rows, stocks = doc.stocks,
                     rows = util_json_array(rows) }
        end,
    })

    api_define({
        name = 'strategy.scan', method = 'GET', path = '/api/v1/strategy/scan',
        summary = '扫描刚刚横盘突破的股票：前几周振幅很小，今天收盘上穿均线',
        params = strategy_params(false),
        handler = function(p)
            if p.limit and (p.limit < 1 or p.limit > 6000) then
                return nil, 'bad_request', 'limit 应在 1 到 6000 之间'
            end
            if p.bars_days and (p.bars_days < 60 or p.bars_days > 5000) then
                return nil, 'bad_request', 'bars_days 应在 60 到 5000 之间'
            end
            if p.ma_days and (p.ma_days < 2 or p.ma_days > 500) then
                return nil, 'bad_request', 'ma_days 应在 2 到 500 之间'
            end
            if p.days and (p.days < 1 or p.days > 20) then
                return nil, 'bad_request', 'days 应在 1 到 20 之间'
            end
            if p.ma_weeks and p.ma_days then
                return nil, 'bad_request', 'ma_days 和 ma_weeks 只给一个'
            end
            if p.flat_weeks and p.flat_lookback then
                return nil, 'bad_request', 'flat_lookback 和 flat_weeks 只给一个'
            end
            if p.ma_weeks and (p.ma_weeks < 1 or p.ma_weeks > 100) then
                return nil, 'bad_request', 'ma_weeks 应在 1 到 100 之间'
            end
            if p.flat_weeks and (p.flat_weeks < 1 or p.flat_weeks > 52) then
                return nil, 'bad_request', 'flat_weeks 应在 1 到 52 之间'
            end
            if p.above_pct and (p.above_pct < 0 or p.above_pct > 50) then
                return nil, 'bad_request', 'above_pct 应在 0 到 50 之间'
            end
            if p.flat_max and (p.flat_max < 1 or p.flat_max > 50) then
                return nil, 'bad_request', 'flat_max 应在 1 到 50 之间'
            end
            if p.cooldown and (p.cooldown < 1 or p.cooldown > 250) then
                return nil, 'bad_request', 'cooldown 应在 1 到 250 之间'
            end
            local opts = strategy_common(p)
            opts.ma_days, opts.above_pct, opts.flat_max = p.ma_days, p.above_pct, p.flat_max
            opts.ma_weeks, opts.flat_weeks = p.ma_weeks, p.flat_weeks
            opts.days, opts.cooldown, opts.bull_only = p.days, p.cooldown, p.bull_only
            -- A scan of the rule as configured over the whole market is the same
            -- thing the daily check runs: it keeps its finds, and the new ones
            -- are pushed. A variation being tried out is only shown.
            local keep = p.record and opts.universe == 'market'
            if keep then opts.on_bars = signals_price_updater() end
            local res, ecode, emsg = strategy_scan(opts)
            if not res then return nil, ecode or 'internal', emsg or '扫描失败' end
            if keep then
                if res.configured then
                    local added, held = signals_record(res, 'web')
                    res.recorded = { added = added, held = held, pushing = #notify_channels() > 0 }
                    if added > held then alerts_flush_later() end
                else
                    signals_save()
                    res.recorded = { added = 0, note = '参数和内置默认不同，这次的结果不记入信号记录' }
                end
            end
            return res
        end,
    })

    api_define({
        name = 'strategy.rules', method = 'GET', path = '/api/v1/strategy/rules',
        summary = '内置的选股规则，以及它们的参数和当前默认值（来自配置）',
        handler = function() return strategy_rules() end,
    })

    api_define({
        name = 'signals.list', method = 'GET', path = '/api/v1/signals',
        summary = '内置规则的信号记录：每只首日突破的发现时间、价格，以及之后涨了多少',
        params = {
            days = { type = 'integer', doc = '最近多少天的信号（按信号日），默认 30' },
            limit = { type = 'integer', doc = '最多返回多少条，默认 500' },
        },
        handler = function(p)
            if p.days and (p.days < 1 or p.days > 3650) then
                return nil, 'bad_request', 'days 应在 1 到 3650 之间'
            end
            if p.limit and (p.limit < 1 or p.limit > 5000) then
                return nil, 'bad_request', 'limit 应在 1 到 5000 之间'
            end
            return signals_list({ days = p.days, limit = p.limit })
        end,
    })

    api_define({
        name = 'signals.run', method = 'POST', path = '/api/v1/signals/run',
        summary = '现在就按内置默认参数把全市场跑一遍，记下新发现的并推送；每日检查也做这件事',
        handler = function()
            local res, ecode, emsg = signals_run('manual')
            if not res then return nil, ecode or 'internal', emsg or '运行失败' end
            if res.added > 0 then alerts_flush_later() end
            return res
        end,
    })
end

function g_exports.commands_install()
    install_system()
    install_market()
    install_quote()
    install_market_list()
    install_review()
    install_backtest()
    install_sweep()
    install_strategy()
    install_watchlist()
    install_stock()
    install_alerts()
    install_insight()
end
