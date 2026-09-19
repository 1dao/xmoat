-- engine/insight.lua — asking a language model about one company, carefully.
--
-- Exports: insight_facts, insight_schema, insight_request, insight_parse,
--          insight_numbers, insight_unverified, insight_generate, insight_get,
--          insight_ask, insight_summary_line
--
-- The rule from the README, made mechanical: the numbers are the engine's, the
-- model only reads and writes. Three things enforce it.
--
--   1. The model is handed FACTS, not data to compute from. insight_facts
--      renders the analysis object — the same figures the page shows — plus
--      the management's own review text and the business breakdown. Every
--      change worth mentioning (share of revenue, percentile, implied growth)
--      is already computed there.
--   2. The instructions forbid calculating or introducing any number.
--   3. Nobody has to trust 2. insight_unverified pulls every figure out of the
--      answer and checks it against the facts the model was given; anything it
--      cannot find is returned alongside the answer and shown as unverified.
--      A model that turned 32.56% into 35.6% is caught; one that rounded it to
--      32.6% is not flagged, because that is the same number.
--
-- Stored per stock as data/insights/<code>.json: the latest answer and a few
-- before it, so a reader can see how the judgement moved between annual
-- reports.

local MAX_HISTORY = 5
local REVIEW_CHARS = 6000        -- per review; two are sent when available

local inflight = {}

local TEMPLATE_NAMES = { general = '一般企业', bank = '银行', insurance = '保险', broker = '证券', other = '其他' }
local KIND_NAMES = { product = '按产品', region = '按地区', industry = '按行业' }
local STATUS_NAMES = { pass = '通过', warn = '注意', na = '数据不足' }

local function has(v) return v ~= nil and v ~= util_null end

local function pct(v, d) return has(v) and report_pct(v, d or 1) or '—' end

local function num(v, d)
    if not has(v) then return '—' end
    return string.format('%.' .. (d or 2) .. 'f', v)
end

local function fmt_unit(v, unit, digits)
    if unit == '%' then return pct(v, digits) end
    if unit == 'pt' then return has(v) and string.format('%.1f 个百分点', v) or '—' end
    if unit == 'x' then return num(v, 2) end
    if unit == 'CNY' then return report_money(v) end
    return num(v)
end

-- Cut to at most `n` characters (not bytes), marking the cut.
local function clip_chars(s, n)
    if (utf8.len(s) or #s) <= n then return s end
    local cut = utf8.offset(s, n + 1)
    return s:sub(1, (cut or (#s + 1)) - 1) .. '……（后略）'
end

-- ---------------------------------------------------------------------------
-- Facts
-- ---------------------------------------------------------------------------

-- a: the analysis object. record: the stored stock record (for the review
-- texts, which the analysis object deliberately does not carry).
-- Returns the facts as one block of text.
function g_exports.insight_facts(a, record)
    local L = {}
    local function line(s) L[#L + 1] = s end
    local function f(...) line(string.format(...)) end

    f('公司：%s（%s.%s）；行业：%s；指标模板：%s', a.name or a.code, a.code, a.market or '',
        a.industry or '未知', TEMPLATE_NAMES[a.template] or a.template)
    local lr = a.latest_report
    if lr then f('最新定期报告：%s（报告期 %s，公告日 %s）', lr.name or lr.period, lr.period, lr.notice_date or '未知') end

    local v = a.valuation
    if v then
        line('')
        f('【估值】（%s，收盘价 %s，总市值 %s）', v.date, num(v.close), report_money(v.market_cap))
        for _, m in ipairs(v.metrics or {}) do
            local parts = { string.format('- %s：%s', m.label, num(m.value)) }
            if m.all then
                parts[#parts + 1] = string.format('%s 以来历史分位 %s，历史中位数 %s，历史区间 %s 至 %s',
                    m.all.from, pct(m.all.percentile, 0), num(m.all.median), num(m.all.min), num(m.all.max))
            end
            if m.y5 then parts[#parts + 1] = '近 5 年分位 ' .. pct(m.y5.percentile, 0) end
            line(table.concat(parts, '；'))
        end
        if v.dividend then f('- 近 12 个月股息率：%s', pct(v.dividend.yield_ttm, 2)) end
        local dcf = v.reverse_dcf
        if dcf and dcf.implied_growth then
            f('- 反向 DCF：按现价，市场隐含%s未来 %d 年年化增长 %s（折现率 %s，永续增长 %s）',
                dcf.earnings_label, dcf.years, pct(dcf.implied_growth), pct(dcf.discount_rate), pct(dcf.terminal_growth))
        end
        if v.band then
            f('- 投资者自设的合理区间（%s）：%s 至 %s，当前 %s', v.band.metric,
                num(v.band.low), num(v.band.high), num(v.band.value))
        end
    end

    local q = a.quality
    if q and #(q.periods or {}) > 0 then
        line('')
        line('【经营质量（年报口径）】')
        for _, s in ipairs(q.summary or {}) do
            f('- %s：%s', s.label, fmt_unit(s.value, s.unit, s.digits))
        end
        local years = {}
        for i, p in ipairs(q.periods) do years[i] = p:sub(1, 4) end
        f('- 逐年序列（%s）：', table.concat(years, '、'))
        for _, s in ipairs(q.series or {}) do
            local vals = {}
            for i = 1, #q.periods do vals[i] = fmt_unit(s.values[i], s.unit, s.digits) end
            f('  %s：%s', s.label, table.concat(vals, '、'))
        end
    end

    local b = a.business
    if b and b.period then
        line('')
        f('【主营构成】（%s 年报%s）', b.period, b.previous_period and ('，占比变化对比 ' .. b.previous_period) or '')
        for _, kind in ipairs({ 'product', 'region', 'industry' }) do
            local list = b.by and b.by[kind] or {}
            if #list > 0 then
                local items = {}
                for _, s in ipairs(list) do
                    local item = string.format('%s 收入 %s，占 %s，毛利率 %s', s.name, report_money(s.revenue),
                        pct(s.revenue_share), pct(s.gross_margin))
                    if has(s.share_change) then
                        item = item .. string.format('，占比变化 %+.1f 个百分点', s.share_change)
                    end
                    items[#items + 1] = item
                end
                f('- %s：%s', KIND_NAMES[kind], table.concat(items, '；'))
            end
        end
    end

    local d = a.dividends
    if d and d.latest_fy then
        line('')
        f('【分红】截至 %d 年报连续 %d 年分红', d.latest_fy, d.consecutive_years or 0)
        for i = 1, math.min(5, #(d.years or {})) do
            local y = d.years[i]
            f('- %d 年：每股派现 %s 元，分红率 %s', y.year, num(y.dps, 3), pct(y.payout_ratio))
        end
    end

    if a.checks and #a.checks > 0 then
        line('')
        line('【检查清单】（程序按固定阈值判断）')
        for _, c in ipairs(a.checks) do
            f('- [%s] %s：%s', STATUS_NAMES[c.status] or c.status, c.title, c.detail or '')
        end
    end

    local biz = record and record.business or {}
    if has(biz.scope) then
        line('')
        f('【经营范围】%s', clip_chars(biz.scope, 400))
    end
    local reviews = type(biz.reviews) == 'table' and biz.reviews or {}
    for i = 1, math.min(2, #reviews) do
        line('')
        f('【管理层经营评述】（%s 报告%s）', reviews[i].period, i > 1 and '，较早的一期' or '')
        line(clip_chars(reviews[i].text, REVIEW_CHARS))
    end
    for _, n in ipairs(a.notes or {}) do
        line('')
        f('【说明】%s', n)
    end
    return table.concat(L, '\n')
end

-- ---------------------------------------------------------------------------
-- The question and the answer's shape
-- ---------------------------------------------------------------------------

local MOAT_SOURCES = { '品牌', '成本优势', '网络效应', '转换成本', '特许经营与牌照', '规模效应',
                       '技术与专利', '渠道', '无明显护城河', '无法判断' }

function g_exports.insight_schema()
    local strings = { type = 'array', items = { type = 'string' } }
    return {
        type = 'object',
        properties = {
            summary = { type = 'string', description = '一到两句话的总体判断' },
            moat = {
                type = 'object',
                properties = {
                    sources = { type = 'array', items = { type = 'string', enum = MOAT_SOURCES } },
                    strength = { type = 'string', enum = { '强', '中', '弱', '无法判断' } },
                    evidence = strings,
                },
                required = { 'sources', 'strength', 'evidence' },
                additionalProperties = false,
            },
            changes = strings,
            risks = strings,
            questions = strings,
        },
        required = { 'summary', 'moat', 'changes', 'risks', 'questions' },
        additionalProperties = false,
    }
end

local SYSTEM = table.concat({
    '你是一名严谨的基本面研究助理，帮助长期投资者理解一家公司。',
    '只依据用户提供的【事实】作答。事实里的数字由程序根据公开财报计算，是唯一可信的数字来源：',
    '不要自己计算、估算、换算或补充任何数字；需要引用数字时，照抄事实中出现的写法。',
    '事实里没有依据的判断，写“无法判断”，不要猜。',
    '管理层经营评述是公司的自我陈述，引用时说明这是公司的说法，不要当作已被证实。',
    '不给出买入、卖出、持有或目标价建议。用简体中文，语气平实。',
}, '\n')

local MOAT_TASK = table.concat({
    '请基于以上事实，判断这家公司的护城河，并按要求的 JSON 结构回答：',
    '- summary：一到两句话的总体判断',
    '- moat.sources：护城河来源，从给定选项中选择，可多选',
    '- moat.strength：强 / 中 / 弱 / 无法判断',
    '- moat.evidence：支撑判断的证据，每条注明来自哪部分事实（如“主营构成”“经营质量”“经营评述”）',
    '- changes：从逐年序列、主营构成占比变化和两期经营评述（如有）看到的变化',
    '- risks：从事实中能看到的风险，包括检查清单里标为“注意”的项目',
    '- questions：值得打开年报核实的问题',
}, '\n')

-- The JSON shape spelled out for providers that cannot enforce a schema.
local SHAPE_HINT = '只输出一个 JSON 对象，不要输出其他文字，结构为：' ..
    '{"summary": string, "moat": {"sources": [string], "strength": "强|中|弱|无法判断", "evidence": [string]}, ' ..
    '"changes": [string], "risks": [string], "questions": [string]}。moat.sources 的可选值：' ..
    table.concat(MOAT_SOURCES, '、') .. '。'

-- Build the moat request for a provider. Returns the llm_chat request.
function g_exports.insight_request(facts, provider)
    local task = MOAT_TASK
    if provider ~= 'anthropic' then task = task .. '\n' .. SHAPE_HINT end
    return {
        system = SYSTEM,
        schema = insight_schema(),
        messages = { { role = 'user', content = '【事实】\n' .. facts .. '\n\n' .. task } },
    }
end

-- The model's text as the answer table, or nil plus a message. Tolerates the
-- code fence an OpenAI-compatible model may wrap JSON in, and checks the shape
-- those providers do not enforce.
function g_exports.insight_parse(text)
    local s = util_str_trim(text)
    s = s:gsub('^```%w*%s*', ''):gsub('%s*```$', '')
    local first, last = s:find('{', 1, true), nil
    for i = #s, 1, -1 do if s:sub(i, i) == '}' then last = i; break end end
    if not first or not last then return nil, '回答不是 JSON' end
    local doc = util_json_decode(s:sub(first, last))
    if type(doc) ~= 'table' then return nil, '回答不是合法的 JSON' end
    if type(doc.summary) ~= 'string' or type(doc.moat) ~= 'table' then
        return nil, '回答缺少 summary 或 moat'
    end
    local function list(v)
        local out = {}
        for _, x in ipairs(type(v) == 'table' and v or {}) do
            if type(x) == 'string' and x ~= '' then out[#out + 1] = x end
        end
        return util_json_array(out)
    end
    return {
        summary = doc.summary,
        moat = { sources = list(doc.moat.sources),
                 strength = type(doc.moat.strength) == 'string' and doc.moat.strength or '无法判断',
                 evidence = list(doc.moat.evidence) },
        changes = list(doc.changes), risks = list(doc.risks), questions = list(doc.questions),
    }
end

-- ---------------------------------------------------------------------------
-- Checking the numbers
-- ---------------------------------------------------------------------------

-- Every figure in `text` that says something: anything with a decimal point,
-- a percent or a money/multiple unit after it, or at least 100. Bare small
-- integers ("3 项风险", "5 年") and years are not claims about the company's
-- numbers and are skipped. Returns a list of { text, value, decimals }.
-- Units that make a bare integer a claim. Checked as string prefixes, not a
-- Lua character class: a class matches BYTES, and each of these is three.
local UNITS = { '%', '亿', '万', '元', '倍', '个百分点', 'pt' }

local function unit_after(text, pos)
    local rest = text:sub(pos, pos + 16):gsub('^%s+', '')
    for _, u in ipairs(UNITS) do
        if rest:sub(1, #u) == u then return u end
    end
    return nil
end

function g_exports.insight_numbers(text)
    text = tostring(text)
    local out, pos = {}, 1
    while true do
        local s, e, int, frac = text:find('(%d[%d,]*)%.?(%d*)', pos)
        if not s then break end
        pos = e + 1
        local digits = int:gsub(',', '')
        local value = tonumber(digits .. (frac ~= '' and ('.' .. frac) or ''))
        if value then
            local unit = unit_after(text, e + 1)
            local significant = frac ~= '' or unit ~= nil or value >= 100
            local is_year = frac == '' and unit == nil and value >= 1990 and value <= 2100
            if significant and not is_year then
                out[#out + 1] = { text = int .. (frac ~= '' and ('.' .. frac) or ''),
                                  value = value, decimals = #frac }
            end
        end
    end
    return out
end

-- Figures in `answer` that do not appear in `facts`, allowing for rounding to
-- the precision the answer states (32.6 matches 32.56; 35.6 does not).
-- Returns a list of the offending texts, without duplicates.
function g_exports.insight_unverified(answer, facts)
    local known = insight_numbers(facts)
    local out, seen = {}, {}
    for _, n in ipairs(insight_numbers(answer)) do
        local tolerance = 0.5 * 10 ^ (-n.decimals) + 1e-9
        local found = false
        for _, k in ipairs(known) do
            if math.abs(math.abs(k.value) - math.abs(n.value)) <= tolerance then found = true; break end
        end
        if not found and not seen[n.text] then
            seen[n.text] = true
            out[#out + 1] = n.text
        end
    end
    return util_json_array(out)
end

-- ---------------------------------------------------------------------------
-- Generating, storing, asking
-- ---------------------------------------------------------------------------

local function load_doc(code)
    local doc, err = store_load('insight:' .. code)
    if err then return nil, err end
    return type(doc) == 'table' and doc or { version = 1, code = code, history = {} }
end

-- The stored latest insight, or nil.
function g_exports.insight_get(code)
    local doc = load_doc(code)
    return doc and doc.latest or nil
end

-- A one-line rendering for an alert.
function g_exports.insight_summary_line(ins)
    local r = ins.result or {}
    local moat = r.moat or {}
    local sources = table.concat(moat.sources or {}, '、')
    return string.format('护城河：%s%s。%s', moat.strength or '无法判断',
        sources ~= '' and ('（' .. sources .. '）') or '', r.summary or '')
end

-- COROUTINE-ONLY. Build the facts, ask, check, store. Returns the insight, or
-- nil plus (code, message).
function g_exports.insight_generate(code)
    if not llm_config() then return nil, 'unavailable', llm_status().hint end
    if inflight[code] then return nil, 'conflict', '这只股票的解读正在生成' end
    local record, lerr = stock_load(code)
    if lerr then return nil, 'internal', lerr end
    if not record then return nil, 'not_fetched', code .. ' 还没有获取过数据，先刷新' end

    inflight[code] = true
    local ok, result, ecode, emsg = pcall(function()
        local a = stock_analysis(code)
        local facts = insight_facts(a, record)
        local conf = llm_config()
        local answer, cerr_code, cerr = llm_chat(insight_request(facts, conf.provider))
        if not answer then return nil, cerr_code, cerr end
        local parsed, perr = insight_parse(answer.text)
        local reviews = record.business and record.business.reviews or {}
        local insight = {
            code = code, name = record.name,
            created_at = util_now_iso(),
            provider = answer.provider, model = answer.model, usage = answer.usage,
            report_period = a.latest_report and a.latest_report.period,
            review_period = reviews[1] and reviews[1].period,
            valuation_date = a.valuation and a.valuation.date,
            result = parsed,
            raw = not parsed and answer.text or nil,
            parse_error = perr,
            unverified = insight_unverified(answer.text, facts),
        }
        local doc = load_doc(code) or { version = 1, code = code, history = {} }
        if doc.latest then table.insert(doc.history, 1, doc.latest) end
        while #doc.history > MAX_HISTORY do table.remove(doc.history) end
        doc.latest = insight
        util_json_array(doc.history)
        local sok, serr = store_save('insight:' .. code, doc)
        if not sok then cfg_log_error('%s: insight not saved: %s', code, tostring(serr)) end
        cfg_log_info('%s insight by %s/%s: %s unverified figure(s)', code, tostring(answer.provider),
            tostring(answer.model), #insight.unverified)
        return insight
    end)
    inflight[code] = nil
    if not ok then
        cfg_log_error('%s insight raised: %s', code, tostring(result))
        return nil, 'internal', '生成解读时出错'
    end
    return result, ecode, emsg
end

-- COROUTINE-ONLY. One question about one stock, answered from the same facts.
-- history: earlier turns { {role = 'user'|'assistant', content}, ... }, oldest
-- first, at most a few. Returns { answer, unverified, model, usage } or nil
-- plus (code, message).
function g_exports.insight_ask(code, question, history)
    if not llm_config() then return nil, 'unavailable', llm_status().hint end
    local record, lerr = stock_load(code)
    if lerr then return nil, 'internal', lerr end
    if not record then return nil, 'not_fetched', code .. ' 还没有获取过数据，先刷新' end
    local facts = insight_facts(stock_analysis(code), record)

    -- Earlier turns, kept only while they alternate user/assistant starting
    -- with the user — the shape both protocols require — and ending with an
    -- assistant turn, so the new question follows it.
    local messages = {}
    for _, m in ipairs(history or {}) do
        local want = (#messages % 2 == 0) and 'user' or 'assistant'
        if m.role == want and type(m.content) == 'string' and m.content ~= '' then
            messages[#messages + 1] = { role = m.role, content = m.content }
        end
    end
    if #messages % 2 == 1 then table.remove(messages) end
    messages[#messages + 1] = { role = 'user', content = question .. '\n\n请用简体中文回答，300 字以内。' }
    -- The facts ride on the first user turn, so the conversation reads in order.
    messages[1].content = '【事实】\n' .. facts .. '\n\n' .. messages[1].content

    local answer, ecode, emsg = llm_chat({ system = SYSTEM, messages = messages })
    if not answer then return nil, ecode, emsg end
    return {
        answer = answer.text,
        unverified = insight_unverified(answer.text, facts),
        provider = answer.provider, model = answer.model, usage = answer.usage,
    }
end
