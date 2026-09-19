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
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            return watch_add(code, { note = p.note, band = p.band })
        end,
    })

    api_define({
        name = 'watchlist.update', method = 'PATCH', path = '/api/v1/watchlist/:code',
        summary = '修改备注或合理估值区间；传 null 清除',
        params = {
            code = code_param(),
            note = { type = 'string', nullable = true },
            band = { type = 'object', nullable = true,
                     doc = '{metric: pe_ttm|pb|ps_ttm|pcf_ttm, low, high}，字段为 null 表示清除' },
        },
        handler = function(p)
            local code, err = security_code(p.code)
            if not code then return nil, 'bad_request', err end
            return watch_update(code, { note = p.note, band = p.band })
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

function g_exports.commands_install()
    install_system()
    install_market()
    install_watchlist()
    install_stock()
    install_alerts()
    install_insight()
end
