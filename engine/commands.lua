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
        summary = '依次刷新全部自选股',
        handler = function()
            local results = {}
            for _, e in ipairs(watch_list()) do
                local rec, ecode, emsg = stock_refresh(e.code)
                results[#results + 1] = rec and { code = e.code, ok = true }
                    or { code = e.code, ok = false, error = { code = ecode, message = emsg } }
            end
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

function g_exports.commands_install()
    install_system()
    install_watchlist()
    install_stock()
end
