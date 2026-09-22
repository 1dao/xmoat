-- engine/signals.lua — what the built-in rule found, kept.
--
-- Exports: signals_load, signals_save, signals_record, signals_list,
--          signals_pending, signals_mark, signals_price_updater, signals_run,
--          signals_daily, __signals_set_daily
--
-- A scan answers "who broke out just now" and forgets. Kept, the same answers
-- become a record that can be checked against what happened next: when each
-- stock was found, at what price, and how far it has gone since. That is the
-- only honest test of a rule after it was fitted — the future it did not see.
--
-- WHAT GOES IN. Only the rule as configured (strategy_scan says whether a run
-- was that, as `configured`): a variation being tried out on the screen page
-- would mix two rules in one record. One entry per first-day breakout, by
-- stock and signal day, so running twice, or with overlapping windows, adds
-- nothing twice.
--
-- TWO PRICES, because a breakout can be found days after it happened (the
-- host was off, or the window is several days): the signal day's close, and
-- the last close when it was added. "Since the signal" is the rule's own
-- result; "since it was added" is what acting on the list would have got.
-- The latest close is kept current by every scan that reads the bars anyway.
--
-- PUSHING follows the alert log: `pushed` is false until a digest carrying
-- it reached a channel, 'skipped' when none was configured, 'failed' after
-- MAX_ATTEMPTS refusals. So each push carries only what is new. 'held' is a
-- signal on a day the market index was not in its 多头 state while the rule
-- asks for that (BREAKOUT_BULL_ONLY): kept, with the day's `regime`, so the
-- record can later say whether the switch was worth it — never pushed.
--
-- Stored as data/signals.json, newest first, pruned to SIGNALS_KEEP_DAYS.

local MAX_ATTEMPTS = 3
local RULE = 'breakout'
-- Which definition of the rule an entry was found by. 1 was "the 40-day
-- average flat over five weeks, close 3% above it", which let through prices
-- swinging 20% around a flat average and ran behind the market; 2 is a real
-- base (the price within 10% for eight weeks) and a cross of the 10-week line;
-- 3 adds the stock's own monthly trend. Entries of another definition are
-- dropped on load: two rules in one record say nothing about either.
local DEF = backtest_breakout_version

local doc = nil           -- { version = 1, seq = n, items = {...}, last_run = {...} }
local daily_override = nil

local function empty() return { version = 1, seq = 0, items = {} } end

function g_exports.signals_load()
    local loaded, err = store_load('signals')
    if err then return nil, err end
    if loaded == nil then doc = empty(); return true end
    if type(loaded) ~= 'table' or type(loaded.items) ~= 'table' then
        return nil, 'signals.json has no items list'
    end
    doc = loaded
    doc.seq = tonumber(doc.seq) or #doc.items
    local kept, dropped = {}, 0
    for _, s in ipairs(doc.items) do
        if s.def == DEF then kept[#kept + 1] = s else dropped = dropped + 1 end
    end
    if dropped > 0 then
        doc.items, doc.last_run = kept, nil
        cfg_log_info('signals: %d entries of an earlier definition of the rule dropped', dropped)
    end
    return true
end

function g_exports.signals_save()
    if not doc then return true end
    util_json_array(doc.items)
    local ok, err = store_save('signals', doc)
    if not ok then cfg_log_error('signals: save failed: %s', tostring(err)) end
    return ok, err
end

-- Drop what is older than the record keeps. By signal day, so a stock found
-- late still leaves when its breakout is that old.
local function prune()
    local keep = cfg_int('SIGNALS_KEEP_DAYS', 180)
    if keep <= 0 then return end
    local cut = util_date_add_days(util_today(), -keep)
    for i = #doc.items, 1, -1 do
        if tostring(doc.items[i].signal_date) < cut then table.remove(doc.items, i) end
    end
end

-- A function for strategy_scan's on_bars: it moves each kept signal's latest
-- close to the newest bar read. Reading five thousand series once is the
-- expensive part of a scan; doing it a second time for the record would be
-- the same cost again.
function g_exports.signals_price_updater()
    local by_code = {}
    for _, s in ipairs(doc.items) do
        by_code[s.code] = by_code[s.code] or {}
        table.insert(by_code[s.code], s)
    end
    return function(code, bars)
        local list = by_code[code]
        local last = list and bars and bars[#bars]
        if not last then return end
        for _, s in ipairs(list) do
            if not s.last_date or last.date >= s.last_date then
                s.last_date, s.last_close = last.date, util_num(last.close)
            end
        end
    end
end

-- Keep the new ones from a scan of the rule as configured. `source` says what
-- ran it ('daily', 'web', 'cli'). Returns how many were added, and how many of
-- those are held back by the market switch. Saves either way: the scan may
-- have moved the latest closes.
function g_exports.signals_record(scan, source)
    local known, added = {}, {}
    for _, s in ipairs(doc.items) do known[s.id] = true end
    local now = util_now_iso()
    if type(scan) == 'table' and scan.configured then
        for _, h in ipairs(scan.hits or {}) do
            local id = RULE .. '|' .. h.code .. '|' .. tostring(h.date)
            if not known[id] then
                known[id] = true
                doc.seq = doc.seq + 1
                added[#added + 1] = {
                    seq = doc.seq, id = id, rule = RULE, def = DEF,
                    code = h.code, name = h.name, industry = h.industry,
                    signal_date = h.date, signal_close = h.close,
                    ma = h.ma, above = h.above, width = h.width, day_gain = h.day_gain,
                    added_at = now, added_date = h.last_date, added_close = h.last_close,
                    last_date = h.last_date, last_close = h.last_close,
                    pe_ttm = h.pe_ttm, pb = h.pb, roe = h.roe, market_cap = h.market_cap,
                    regime = h.regime, source = source, pushed = h.held and 'held' or false,
                }
            end
        end
    end
    -- Newest first; within one run the order the scan gave, strongest first.
    for i = #added, 1, -1 do table.insert(doc.items, 1, added[i]) end
    local held = 0
    for _, s in ipairs(added) do
        if s.pushed == 'held' then held = held + 1 end
    end
    if type(scan) == 'table' and scan.configured then
        doc.last_run = { at = now, source = source, checked = scan.checked,
                         found = #(scan.hits or {}), added = #added, held = held, days = scan.days,
                         regime = scan.regime and scan.regime.state }
    end
    prune()
    signals_save()
    if #added > 0 then cfg_log_info('signals: %d new from %s', #added, tostring(source)) end
    return #added, held
end

local function pct(now, base)
    now, base = util_num(now), util_num(base)
    if not now or not base or base <= 0 then return nil end
    return (now / base - 1) * 100
end

-- The record by signal day, newest first, with the two gains worked out on
-- read. Stored order is the order things were ADDED, and a wider window adds
-- older breakouts after newer ones; within one day, the order the scan gave.
-- opts = { days = 30 (by signal day), limit = 500 }
function g_exports.signals_list(opts)
    opts = opts or {}
    local days = opts.days or 30
    local limit = opts.limit or 500
    local cut = util_date_add_days(util_today(), -days)
    local within = {}
    for _, s in ipairs(doc.items) do
        if tostring(s.signal_date) >= cut then within[#within + 1] = s end
    end
    table.sort(within, function(a, b)
        if a.signal_date ~= b.signal_date then return tostring(a.signal_date) > tostring(b.signal_date) end
        return (a.seq or 0) < (b.seq or 0)
    end)
    local out, total = {}, #within
    for i = 1, math.min(limit, total) do
        local s = within[i]
        local row = util_copy(s)
        row.since_signal_pct = pct(s.last_close, s.signal_close)
        row.since_added_pct = pct(s.last_close, s.added_close)
        out[#out + 1] = row
    end
    local rule = strategy_rules()[1]
    return {
        rule = RULE, title = rule and rule.title, days = days,
        total = total, count = #out, items = util_json_array(out),
        last_run = doc.last_run,
        daily = signals_daily(),
    }
end

-- Waiting to be pushed, oldest first.
function g_exports.signals_pending()
    local out = {}
    for i = #doc.items, 1, -1 do
        if doc.items[i].pushed == false then out[#out + 1] = doc.items[i] end
    end
    return out
end

-- After a flush: delivered, skipped for want of a channel, or one more refusal.
-- how = true | 'skipped' | false
function g_exports.signals_mark(list, how)
    if not list or #list == 0 then return end
    local now = util_now_iso()
    for _, s in ipairs(list) do
        if how == true then
            s.pushed, s.pushed_at = true, now
        elseif how == 'skipped' then
            s.pushed = 'skipped'
        else
            s.push_attempts = (s.push_attempts or 0) + 1
            if s.push_attempts >= MAX_ATTEMPTS then s.pushed = 'failed' end
        end
    end
    signals_save()
end

-- Whether the daily check runs the rule. Tests turn it off for every check
-- but their own: a whole-market scan is not what a test of the watchlist asks.
function g_exports.signals_daily()
    if daily_override ~= nil then return daily_override end
    return cfg_bool('SIGNALS_DAILY', true)
end

function g_exports.__signals_set_daily(v)
    daily_override = v
end

-- COROUTINE-ONLY. The daily run: the rule as configured over the whole
-- market, the new finds kept. A few days of window, so a check that was
-- missed (the host was off, a holiday was mistaken for a trading day) still
-- finds what broke out meanwhile — kept once each, whatever the overlap.
-- Returns the scan's summary with `added`, or nil plus (code, message).
function g_exports.signals_run(source)
    local status = market_status()
    if not status or not status.ready then
        -- The universe is the snapshot's list of stocks. Without one there is
        -- nothing to scan; fetching it is about fifteen requests.
        local got, _, err = market_refresh()
        if not got then return nil, 'upstream', '没有全市场快照，抓取也失败了：' .. tostring(err) end
    end
    local res, ecode, emsg = strategy_scan({
        universe = 'market', limit = 6000,
        days = math.max(1, math.min(cfg_int('SIGNALS_DAYS', 3), 20)),
        on_bars = signals_price_updater(),
    })
    if not res then return nil, ecode, emsg end
    local added, held = signals_record(res, source or 'daily')
    return { checked = res.checked, found = #res.hits, added = added, held = held, days = res.days,
             regime = res.regime and res.regime.state, fetch = res.fetch, params = res.params }
end
