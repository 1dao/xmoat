-- engine/commodity.lua — commodities watched for a turn: gold, futures, memory chips.
--
-- Exports: commodity_load, commodity_list, commodity_get, commodity_add,
--          commodity_update, commodity_remove, commodity_judge, commodity_step,
--          commodity_refresh, commodity_run, commodity_running, commodity_tick,
--          commodity_catalog, commodity_search, commodity_market_open,
--          commodity_defaults
--
-- WHY. A stock that makes memory chips moves with what memory sells for, and
-- the contract and spot prices turn before the reports do. The same goes for
-- a gold miner and gold. So the thing worth a push is the commodity's own
-- trend turning — not every tick of it.
--
-- WHAT IS WATCHED, three sources:
--   em           anything Eastmoney's quote server carries by secid: futures
--                (113.aum 沪金主连), Shanghai Gold Exchange spot (118.AUTD),
--                COMEX (101.GC00Y), forex. Daily bars with history, and during
--                a session the newest bar is the day so far.
--   dx_spot      DRAMeXchange spot prices (engine/source_dx.lua): DRAM chips
--                daily, flash, wafers and modules about weekly. NO history is
--                free, so the series here starts the day the item is added.
--   dx_contract  DRAMeXchange contract prices, about once a month, each
--                published with its change on the period before.
--
-- THE RULES, one per source, each producing an up or a down event:
--   ma      the price crossing its own N-observation moving average: under
--           it after being over it is 掉头, over it after being under is 转涨.
--           A band of band_pct% either side is a no-man's-land: inside it the
--           side does not change, so a price hugging its average does not
--           push every fifteen minutes. N counts observations, not calendar
--           days — for a weekly wafer price, ten of them is ten weeks.
--   change  a contract publication's change on the last one: rising (转涨 or
--           续涨), or falling after it was not (掉头). A fall that continues a
--           fall is not news.
--
-- THE FIRST JUDGEMENT IS A BASELINE. Adding an item, or changing its rule,
-- records which side it is on and pushes nothing: "it is above its average"
-- is not a turn, it is where things stand.
--
-- WHEN. The host's one ticker (engine/schedule.lua) calls commodity_tick every
-- 30 s; a run happens every COMMODITY_INTERVAL_MIN minutes. Eastmoney items
-- are skipped while every market they could trade on is shut (the weekend);
-- DRAMeXchange is asked at most every COMMODITY_DX_TTL_MIN, since it
-- publishes once a day at most. The daily check runs the same thing, so a
-- host with the interval switched off still judges once a day.
--
-- Events go into the alert log (engine/alerts.lua) with kind 'commodity' and
-- the item's id as their code, and are pushed the way every alert is. An
-- intraday run pushes at once; what it could not fetch is kept on the item
-- for the page to show, not pushed — every fifteen minutes it would be noise.
--
-- Stored as data/commodities.json (what and its state) plus one series per
-- item under data/commodities/.

local SOURCES = {
    em          = { prefix = 'em',  rule = 'ma',     label = '东方财富',          unit = '日' },
    dx_spot     = { prefix = 'dxs', rule = 'ma',     label = 'DRAMeXchange 现货', unit = '期' },
    dx_contract = { prefix = 'dxc', rule = 'change', label = 'DRAMeXchange 合约价', unit = '期' },
}
local OVERLAP_DAYS = 10
local SLOPE_SPAN = 5

local doc = nil          -- { version = 1, items = {...}, dx = {...}, last_run = {...} }
local running = false
local last_tick = nil    -- epoch seconds of the last tick-started run

local function save()
    util_json_array(doc.items)
    local ok, err = store_save('commodities', doc)
    if not ok then cfg_log_error('commodities: save failed: %s', tostring(err)) end
    return ok, err
end

function g_exports.commodity_load()
    local loaded, err = store_load('commodities')
    if err then return nil, err end
    if loaded == nil then
        doc = { version = 1, items = {}, dx = {} }
        return true
    end
    if type(loaded) ~= 'table' or type(loaded.items) ~= 'table' then
        return nil, 'commodities.json has no items list'
    end
    doc = loaded
    doc.dx = type(doc.dx) == 'table' and doc.dx or {}
    return true
end

function g_exports.commodity_defaults()
    return {
        ma_days = cfg_int('COMMODITY_MA_DAYS', 20),
        spot_ma_days = cfg_int('COMMODITY_SPOT_MA_DAYS', 10),
        band_pct = cfg_num('COMMODITY_BAND_PCT', 0.5),
        interval_min = cfg_int('COMMODITY_INTERVAL_MIN', 15),
        dx_ttl_min = cfg_int('COMMODITY_DX_TTL_MIN', 60),
        max_rows = cfg_int('COMMODITY_MAX_ROWS', 500),
    }
end

local function index_of(id)
    for i, it in ipairs(doc.items) do
        if it.id == id then return i end
    end
    return nil
end

local function valid_ref(source, ref)
    if type(ref) ~= 'string' then return false end
    if source == 'em' then return source_em_valid_secid(ref) end
    return ref:match('^%a+%.%d+$') ~= nil and #ref <= 40
end

-- ── the series ─────────────────────────────────────────────────────────────

local function series_load(id)
    local s = store_load('cseries:' .. id)
    return type(s) == 'table' and type(s.rows) == 'table' and s or { id = id, rows = {} }
end

-- Rows by date, a newer copy of a day replacing the older (the day's bar
-- keeps moving until the close; a spot table is re-published under the same
-- date), oldest first, the newest `max` kept.
local function merge(rows, fresh, max)
    local by_date = {}
    for _, r in ipairs(rows or {}) do by_date[r.date] = r end
    for _, r in ipairs(fresh or {}) do
        if r.date and util_num(r.close) then by_date[r.date] = r end
    end
    local out = {}
    for _, r in pairs(by_date) do out[#out + 1] = r end
    table.sort(out, function(a, b) return a.date < b.date end)
    if max and max > 0 and #out > max then
        local cut = {}
        for i = #out - max + 1, #out do cut[#cut + 1] = out[i] end
        out = cut
    end
    return out
end

-- ── judging (pure) ─────────────────────────────────────────────────────────

local function sign(v)
    v = util_num(v)
    if not v then return nil end
    return v > 0 and 'up' or v < 0 and 'down' or 'flat'
end

-- What the series says now, under the item's rule. `prev` is the item's
-- stored state (for the band's hold). Pure: rows in, a judgement out.
--   ma:     { rule, ready, have, need, date, close, ma, ma_days, dist_pct, slope_pct, side,
--             since (the first day of the current run on that side) }
--   change: { rule, ready, date, close, change_pct, dir, prev_dir, prev_date }
function g_exports.commodity_judge(rows, conf, prev)
    prev = prev or {}
    rows = rows or {}
    local last = rows[#rows]
    if conf.rule == 'change' then
        if not last then return { rule = 'change', ready = false, have = 0, need = 1 } end
        local before = rows[#rows - 1]
        return { rule = 'change', ready = true, date = last.date, close = util_num(last.close),
                 change_pct = util_num(last.change_pct), dir = sign(last.change_pct),
                 prev_dir = before and sign(before.change_pct) or nil,
                 prev_date = before and before.date or nil }
    end
    local n = conf.ma_days
    local out = { rule = 'ma', ma_days = n, have = #rows, need = n, ready = false,
                  date = last and last.date, close = last and util_num(last.close) }
    if not last or #rows < n then return out end
    local ma = tech_ma(rows, n)
    if not ma or ma <= 0 or not out.close then return out end
    local earlier = #rows - SLOPE_SPAN >= n and tech_ma(rows, n, #rows - SLOPE_SPAN) or nil
    local band = (conf.band_pct or 0) / 100
    local side
    if out.close > ma * (1 + band) then side = 'above'
    elseif out.close < ma * (1 - band) then side = 'below'
    else side = prev.side or (out.close >= ma and 'above' or 'below') end
    out.ready, out.ma, out.side = true, ma, side
    out.dist_pct = (out.close / ma - 1) * 100
    -- How long it has been on this side, from the series itself: what a
    -- baseline says instead of "since the day you added it".
    for i = #rows, n, -1 do
        local m, c = tech_ma(rows, n, i), util_num(rows[i].close)
        if not m or not c or (c >= m) ~= (side == 'above') then break end
        out.since = rows[i].date
    end
    out.slope_pct = earlier and earlier > 0 and (ma / earlier - 1) * 100 or nil
    return out
end

local function fmt(v)
    v = util_num(v)
    if not v then return '—' end
    local a = math.abs(v)
    return string.format(a >= 1000 and '%.1f' or a >= 10 and '%.2f' or '%.3f', v)
end

local function signed_pct(v, d)
    v = util_num(v)
    if not v then return '—' end
    return string.format('%+.' .. (d or 1) .. 'f%%', v)
end

-- The next state and any event, from the stored state and a judgement.
-- Pure. `opts.live` marks a price from a session still trading.
function g_exports.commodity_step(item, j, prev, opts)
    prev = prev or {}
    opts = opts or {}
    local state = util_copy(prev)
    state.date, state.close, state.ready = j.date, j.close, j.ready
    state.have, state.need = j.have, j.need
    state.error, state.error_at = nil, nil
    local ev
    local src = SOURCES[item.source] or SOURCES.em
    local when = tostring(j.date) .. (opts.live and '，盘中' or '')

    if j.rule == 'ma' then
        state.ma, state.dist_pct, state.slope_pct = j.ma, j.dist_pct, j.slope_pct
        if not j.ready then return state, nil end
        if prev.side and j.side ~= prev.side then
            local up = j.side == 'above'
            local slope = j.slope_pct and string.format('；均线%s（%d 期 %s）',
                j.slope_pct >= 0 and '仍在上行' or '仍在下行', SLOPE_SPAN, signed_pct(j.slope_pct, 2)) or ''
            local before = prev.side_since and string.format('此前自 %s 起在均线%s。', prev.side_since,
                prev.side == 'above' and '之上' or '之下') or ''
            ev = {
                dir = up and 'up' or 'down',
                title = up and string.format('转为上涨：站上 %d %s均线', j.ma_days, src.unit)
                            or string.format('走势掉头：跌破 %d %s均线', j.ma_days, src.unit),
                detail = string.format('最新 %s（%s），%d %s均线 %s，%s均线 %s%s。%s', fmt(j.close), when,
                    j.ma_days, src.unit, fmt(j.ma), up and '高于' or '低于',
                    signed_pct(j.dist_pct, 2), slope, before),
            }
        end
        if j.side ~= prev.side then state.side_since = prev.side and j.date or (j.since or j.date) end
        state.side = j.side
    else
        state.change_pct, state.dir = j.change_pct, j.dir
        -- A publication already judged is not news again; the first one seen
        -- is where things stand.
        if j.ready and prev.judged_date and j.date ~= prev.judged_date then
            local title
            if j.dir == 'up' then title = j.prev_dir == 'up' and '合约价续涨' or '合约价转涨'
            elseif j.dir == 'down' and j.prev_dir ~= 'down' then title = '合约价掉头下跌' end
            if title then
                ev = {
                    dir = j.dir, title = title,
                    detail = string.format('%s 合约均价 %s，较上期 %s%s。', tostring(j.date), fmt(j.close),
                        signed_pct(j.change_pct, 2),
                        j.prev_date and string.format('（上期 %s %s）', j.prev_date,
                            j.prev_dir == 'up' and '上涨' or j.prev_dir == 'down' and '下跌' or '持平') or ''),
                }
            end
        end
        if j.ready then state.judged_date = j.date end
    end
    if ev then
        ev.id = events_id(item.id, 'commodity|' .. ev.dir .. '|' .. tostring(j.date))
        ev.code, ev.name, ev.kind = item.id, item.name or item.ref, 'commodity'
        ev.price, ev.date = j.close, j.date
        state.last_event = { dir = ev.dir, title = ev.title, date = j.date, at = util_now_iso() }
    end
    return state, ev
end

-- ── when ───────────────────────────────────────────────────────────────────

-- Whether any market an Eastmoney item could trade on is open, by the
-- schedule's clock (Beijing by default). COMEX runs from Monday morning to
-- Saturday morning Beijing time and the Shanghai night session ends at 02:30
-- on Saturday, so the only certain silence is Saturday 06:00 to Monday 06:00.
-- Holidays are not known; a run on one finds the same bar and says nothing.
function g_exports.commodity_market_open(clock)
    if clock.iso_wday == 7 then return false end
    if clock.iso_wday == 6 and clock.hm >= '06:00' then return false end
    if clock.iso_wday == 1 and clock.hm < '06:00' then return false end
    return true
end

local function clock_now()
    return schedule_clock(cfg_num('SCHEDULE_UTC_OFFSET', 8))
end

-- ── fetching ───────────────────────────────────────────────────────────────

-- COROUTINE-ONLY. Bring one item's series up to date. `ctx` shares the
-- DRAMeXchange pages across the items of one run: one request answers every
-- spot item. Returns the rows, or nil plus a message.
local function refresh(item, ctx)
    local conf = commodity_defaults()
    local series = series_load(item.id)
    local fresh
    if item.source == 'em' then
        local last = series.rows[#series.rows]
        local res, err = source_em_fetch_kline_secid(item.ref, last
            and { from = util_date_add_days(last.date, -OVERLAP_DAYS) }
            or { limit = conf.max_rows })
        if not res then return nil, '行情获取失败：' .. tostring(err) end
        if #res.rows == 0 and #series.rows == 0 then return nil, item.ref .. ' 没有行情数据' end
        if res.name and not item.name then item.name = res.name end
        fresh = {}
        for _, r in ipairs(res.rows) do
            fresh[#fresh + 1] = { date = r.date, open = r.open, close = r.close, high = r.high,
                                  low = r.low, change_pct = r.change_pct }
        end
    else
        local key = item.source == 'dx_spot' and 'spot' or 'contract'
        if ctx[key] == nil then
            local res, err
            if key == 'spot' then res, err = source_dx_fetch_spot() else res, err = source_dx_fetch_contract() end
            ctx[key] = res or false
            ctx[key .. '_err'] = err
            if res then doc.dx[key .. '_at'] = util_now_iso() end
        end
        if not ctx[key] then return nil, 'DRAMeXchange 获取失败：' .. tostring(ctx[key .. '_err']) end
        local hit
        for _, it in ipairs(ctx[key].items) do
            if it.id == item.ref then hit = it; break end
        end
        if not hit then return nil, 'DRAMeXchange 页面上已经没有这一项（' .. item.ref .. '）' end
        item.name = item.name or hit.name
        item.group = hit.group
        fresh = { { date = hit.date, close = hit.avg, high = hit.high, low = hit.low,
                    change_pct = hit.change_pct } }
    end
    series.rows = util_json_array(merge(series.rows, fresh, conf.max_rows))
    series.fetched_at = util_now_iso()
    local ok, err = store_save('cseries:' .. item.id, series)
    if not ok then return nil, '保存失败：' .. tostring(err) end
    return series.rows
end

local function conf_of(item)
    return { rule = item.rule, ma_days = item.ma_days, band_pct = item.band_pct }
end

-- COROUTINE-ONLY. Refresh and judge one item; returns the event if any.
-- Does not save the list — the caller does, once.
local function check_item(item, ctx, clock)
    local rows, err = refresh(item, ctx)
    local prev = type(item.state) == 'table' and item.state or {}
    if not rows then
        item.state = util_copy(prev)
        item.state.error, item.state.error_at = tostring(err), util_now_iso()
        return nil, err
    end
    local j = commodity_judge(rows, conf_of(item), prev)
    -- The newest bar is still moving when its day has not closed: today
    -- before the afternoon close, or tomorrow's date (a night session).
    local live = item.source == 'em' and j.date
        and (j.date > clock.date or (j.date == clock.date and clock.hm < '15:30'))
    local state, ev = commodity_step(item, j, prev, { live = live })
    state.checked_at = util_now_iso()
    item.state = state
    return ev
end

-- COROUTINE-ONLY. Refresh one item now and save. Returns the item.
function g_exports.commodity_refresh(id)
    local i = index_of(id)
    if not i then return nil, 'not_found', '没有这个监控项：' .. tostring(id) end
    local item = doc.items[i]
    local ev, err = check_item(item, {}, clock_now())
    save()
    if ev then
        alerts_record({ ev })
        alerts_flush_later()
    end
    if err then return nil, 'upstream', err end
    return item
end

function g_exports.commodity_running()
    return running
end

-- COROUTINE-ONLY. Check every enabled item. opts = {
--   source = 'tick' | 'daily' | 'manual',
--   flush  = push what was found straight away (the daily check pushes it
--            in its own digest instead),
--   force  = ask every source now, whatever the clock and the TTL }
-- Returns { checked, skipped, events, problems = { {code, name, error} } }.
function g_exports.commodity_run(opts)
    opts = opts or {}
    if running then
        if opts.source == 'daily' then
            sched_wait_until(function() return not running end, 300000)
            if running then return nil, 'conflict', '商品检查正在进行' end
        else
            return nil, 'conflict', '商品检查正在进行'
        end
    end
    running = true
    local ok, res = pcall(function()
        local conf = commodity_defaults()
        local clock = clock_now()
        local em_open = opts.force or commodity_market_open(clock)
        local now = os.time()
        local dx_due = opts.force or not doc.dx.checked_epoch
            or now - doc.dx.checked_epoch >= conf.dx_ttl_min * 60
        local ctx, events, problems = {}, {}, {}
        local checked, skipped, asked_dx = 0, 0, false
        for _, item in ipairs(doc.items) do
            local due = item.enabled ~= false
                and (item.source == 'em' and em_open or item.source ~= 'em' and dx_due)
            if not due then
                skipped = skipped + 1
            else
                if item.source ~= 'em' then asked_dx = true
                elseif checked > 0 then sched_sleep(cfg_int('NET_PACE_MS', 200)) end
                checked = checked + 1
                local ev, err = check_item(item, ctx, clock)
                if ev then events[#events + 1] = ev end
                if err then
                    problems[#problems + 1] = { kind = 'commodity', code = item.id,
                                                name = item.name or item.ref, error = tostring(err) }
                end
            end
        end
        if asked_dx then doc.dx.checked_epoch = now end
        doc.last_run = { at = util_now_iso(), source = opts.source or 'manual', checked = checked,
                         skipped = skipped, events = #events, problems = #problems }
        save()
        local added = alerts_record(events)
        return { checked = checked, skipped = skipped, events = added,
                 problems = util_json_array(problems) }
    end)
    running = false
    if not ok then
        cfg_log_error('commodity run raised: %s', tostring(res))
        return nil, 'internal', '商品检查时出错'
    end
    if res.checked > 0 then
        cfg_log_info('commodity check (%s): %d checked, %d skipped, %d event(s), %d problem(s)',
            tostring(opts.source), res.checked, res.skipped, res.events, #res.problems)
    end
    if opts.flush and res.events > 0 then
        sched_wait_until(function() return not alerts_running() end, 600000)
        res.push = alerts_flush()
    end
    return res
end

-- MAIN STATE: called by the schedule's ticker. Starts a run on a coroutine
-- of its own when the interval has passed; never yields.
function g_exports.commodity_tick(now_s)
    local interval = cfg_int('COMMODITY_INTERVAL_MIN', 15)
    if interval <= 0 or running or not doc or #doc.items == 0 then return false end
    now_s = now_s or os.time()
    if last_tick and now_s - last_tick < interval * 60 then return false end
    last_tick = now_s
    sched_spawn('commodity check', commodity_run, { source = 'tick', flush = true })
    return true
end

-- ── the list ───────────────────────────────────────────────────────────────

local function view(item)
    local out = util_copy(item)
    out.label = (SOURCES[item.source] or {}).label
    out.unit = (SOURCES[item.source] or {}).unit
    return out
end

function g_exports.commodity_list()
    local items = {}
    for _, it in ipairs(doc.items) do items[#items + 1] = view(it) end
    local conf = commodity_defaults()
    return {
        items = util_json_array(items),
        defaults = conf,
        running = running,
        market_open = commodity_market_open(clock_now()),
        last_run = doc.last_run,
        dx = { spot_at = doc.dx.spot_at, contract_at = doc.dx.contract_at },
    }
end

-- One item with its newest `days` rows (all of them by default).
function g_exports.commodity_get(id, days)
    local i = index_of(id)
    if not i then return nil, 'not_found', '没有这个监控项：' .. tostring(id) end
    local rows = series_load(id).rows
    local out = view(doc.items[i])
    local from = days and math.max(1, #rows - days + 1) or 1
    local cut = {}
    for k = from, #rows do cut[#cut + 1] = rows[k] end
    out.rows = util_json_array(cut)
    out.total_rows = #rows
    return out
end

local function valid_params(ma_days, band_pct)
    if ma_days ~= nil and (math.floor(ma_days) ~= ma_days or ma_days < 2 or ma_days > 250) then
        return false, 'ma_days 应为 2 到 250 之间的整数'
    end
    if band_pct ~= nil and (band_pct < 0 or band_pct > 20) then
        return false, 'band_pct 应在 0 到 20 之间'
    end
    return true
end

-- fields = { source, ref, name?, ma_days?, band_pct?, note? }. Returns the
-- item (not yet fetched), or nil plus (code, message).
function g_exports.commodity_add(fields)
    local src = SOURCES[fields.source or '']
    if not src then return nil, 'bad_request', 'source 只能是 em、dx_spot、dx_contract' end
    if not valid_ref(fields.source, fields.ref) then
        return nil, 'bad_request', fields.source == 'em'
            and 'ref 应为东方财富的行情代码，如 113.aum、118.AUTD'
            or 'ref 应为 DRAMeXchange 的条目，如 dram.475'
    end
    local ok, perr = valid_params(fields.ma_days, fields.band_pct)
    if not ok then return nil, 'bad_request', perr end
    local id = src.prefix .. '.' .. fields.ref
    if index_of(id) then return nil, 'conflict', '已在监控中：' .. (fields.name or fields.ref) end
    local conf = commodity_defaults()
    local item = {
        id = id, source = fields.source, ref = fields.ref, rule = src.rule,
        name = type(fields.name) == 'string' and fields.name ~= '' and fields.name or nil,
        note = type(fields.note) == 'string' and fields.note or nil,
        ma_days = fields.ma_days or (fields.source == 'em' and conf.ma_days or conf.spot_ma_days),
        band_pct = fields.band_pct or conf.band_pct,
        enabled = true, added_at = util_now_iso(), state = {},
    }
    doc.items[#doc.items + 1] = item
    local sok, err = save()
    if not sok then
        table.remove(doc.items)
        return nil, 'internal', tostring(err)
    end
    return view(item)
end

-- patch = { name?, note?, ma_days?, band_pct?, enabled? }; util_null clears
-- name and note. Changing the rule's numbers starts it from a new baseline:
-- a side judged on 20 days is not the same claim as one judged on 60, and
-- the switch itself must not read as a turn.
function g_exports.commodity_update(id, patch)
    local i = index_of(id)
    if not i then return nil, 'not_found', '没有这个监控项：' .. tostring(id) end
    local ok, perr = valid_params(patch.ma_days, patch.band_pct)
    if not ok then return nil, 'bad_request', perr end
    local item = util_copy(doc.items[i])
    for _, k in ipairs({ 'name', 'note' }) do
        if patch[k] == util_null then item[k] = nil
        elseif patch[k] ~= nil then
            if type(patch[k]) ~= 'string' then return nil, 'bad_request', k .. ' 必须是字符串' end
            item[k] = patch[k] ~= '' and patch[k] or nil
        end
    end
    local rebase = false
    if patch.ma_days ~= nil and patch.ma_days ~= item.ma_days then item.ma_days = patch.ma_days; rebase = true end
    if patch.band_pct ~= nil and patch.band_pct ~= item.band_pct then item.band_pct = patch.band_pct; rebase = true end
    if patch.enabled ~= nil then item.enabled = patch.enabled and true or false end
    if rebase and type(item.state) == 'table' then
        item.state.side, item.state.side_since = nil, nil
    end
    local before = doc.items[i]
    doc.items[i] = item
    local sok, err = save()
    if not sok then
        doc.items[i] = before
        return nil, 'internal', tostring(err)
    end
    return view(item)
end

-- Removes the item and its series.
function g_exports.commodity_remove(id)
    local i = index_of(id)
    if not i then return nil, 'not_found', '没有这个监控项：' .. tostring(id) end
    local item = table.remove(doc.items, i)
    local ok, err = save()
    if not ok then
        table.insert(doc.items, i, item)
        return nil, 'internal', tostring(err)
    end
    util_file_remove(util_path_join(store_dir(), 'commodities', id .. '.json'))
    return true
end

-- COROUTINE-ONLY. What DRAMeXchange lists today, for choosing an item.
function g_exports.commodity_catalog()
    local spot, serr = source_dx_fetch_spot()
    local contract, cerr = source_dx_fetch_contract()
    if not spot and not contract then
        return nil, 'upstream', 'DRAMeXchange 获取失败：' .. tostring(serr) .. '；' .. tostring(cerr)
    end
    local errors = {}
    if not spot then errors[#errors + 1] = '现货：' .. tostring(serr) end
    if not contract then errors[#errors + 1] = '合约价：' .. tostring(cerr) end
    for _, e in ipairs(contract and contract.errors or {}) do errors[#errors + 1] = '合约价 ' .. e end
    return {
        spot = util_json_array(spot and spot.items or {}),
        contract = util_json_array(contract and contract.items or {}),
        errors = #errors > 0 and util_json_array(errors) or nil,
    }
end

-- COROUTINE-ONLY. Eastmoney's search, narrowed to what can be watched here.
--
-- The continuous contract (沪金主连) is what a trend is read on — a month's
-- contract expires, and its first weeks are thin — but "沪金" alone lists
-- the months and not it. So when none came back, the 主连 is asked for too,
-- and continuous contracts lead the list.
function g_exports.commodity_search(q)
    local res, err = source_em_search(q)
    if not res then return nil, 'upstream', '搜索失败：' .. tostring(err) end
    local function continuous(x) return tostring(x.name):find('主连', 1, true) or tostring(x.name):find('连续', 1, true) end
    local any = false
    for _, x in ipairs(res) do any = any or continuous(x) end
    if not any and not q:find('主连', 1, true) then
        local more = source_em_search(q .. '主连')
        local seen = {}
        for _, x in ipairs(res) do seen[x.secid] = true end
        for _, x in ipairs(more or {}) do
            if not seen[x.secid] then seen[x.secid] = true; res[#res + 1] = x end
        end
    end
    local lead, rest = {}, {}
    for _, x in ipairs(res) do
        if continuous(x) then lead[#lead + 1] = x else rest[#rest + 1] = x end
    end
    for _, x in ipairs(rest) do lead[#lead + 1] = x end
    return util_json_array(lead)
end
