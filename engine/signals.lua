-- engine/signals.lua — what the built-in rules found, kept.
--
-- Exports: signals_load, signals_save, signals_record, signals_list,
--          signals_pending, signals_mark, signals_price_updater, signals_run,
--          signals_rule_ids, signals_daily, __signals_set_daily
--
-- A scan answers "who fired just now" and forgets. Kept, the same answers
-- become a record that can be checked against what happened next: when each
-- stock was found, at what price, and how far it has gone since. That is the
-- only honest test of a rule after it was fitted — the future it did not see.
--
-- ONE STORE, EVERY RULE. `RULES` below is the one place a rule's daily-push
-- wiring lives: how to run its market-wide scan, which field of that result
-- is "what to record" (a rule's scan may answer a different question too —
-- subnew.scan's own `hits` are "who is down right now", not "who just
-- crossed", which is `events`), which of its fields are worth keeping, and
-- its own definition version (so a later change to the rule's meaning drops
-- the old entries rather than mixing two rules' numbers under one id). Adding
-- a rule here is the only change this file needs; storage, pushing, pruning
-- and the record's own definition-version guard are all shared.
--
-- WHAT GOES IN. Only a rule as configured (its scan says whether a run was
-- that, as `configured`): a variation being tried out on the screen page
-- would mix two parameter sets in one record. One entry per rule, stock and
-- signal day, so running twice, or with overlapping windows, adds nothing
-- twice — ids are namespaced by rule (`rule|code|date`), so two rules firing
-- on the same stock the same day are two entries, not a collision.
--
-- TWO PRICES, because a signal can be found days after it happened (the host
-- was off, or the window is several days): the signal day's close, and the
-- last close when it was added. "Since the signal" is the rule's own result;
-- "since it was added" is what acting on the list would have got. The latest
-- close is kept current by every scan that reads the bars anyway.
--
-- PUSHING follows the alert log: `pushed` is false until a digest carrying
-- it reached a channel, 'skipped' when none was configured, 'failed' after
-- MAX_ATTEMPTS refusals. So each push carries only what is new. 'held' is a
-- signal a rule itself asks to keep back (breakout: the market index was not
-- in its 多头 state while BREAKOUT_BULL_ONLY is on) — kept, never pushed.
--
-- Stored as data/signals.json, newest first, pruned to SIGNALS_KEEP_DAYS.

local MAX_ATTEMPTS = 3

-- opts passed to `scan` always carries `on_bars`, built once per run so every
-- rule's scan updates the SAME kept entries' latest prices off the bars it
-- reads anyway, rather than each rule re-reading the whole market's bars a
-- second time just for that. An ARRAY, not a keyed table: order here is the
-- order the daily check and 'signals.run' run rules in, and it is what
-- signals_rule_ids() hands a client — genuinely the only place to touch for
-- one more rule.
local RULES = {
    { id = 'breakout',
      def = backtest_breakout_version,
      title = function() local r = strategy_rules()[1]; return r and r.title end,
      hits_field = 'hits',
      scan = function(opts)
          return strategy_scan({ universe = 'market', limit = 6000,
              days = math.max(1, math.min(cfg_int('SIGNALS_DAYS', 3), 20)),
              on_bars = opts.on_bars })
      end,
      fields = function(h) return { ma = h.ma, above = h.above, width = h.width, day_gain = h.day_gain,
                                    regime = h.regime } end,
      held = function(h) return h.held end },
    { id = 'subnew',
      def = subnew_def_version,
      title = function() return '次新股，跌破首日开盘价' end,
      -- subnew.scan answers two questions on one pass of the bars: `hits` is
      -- who is down enough RIGHT NOW (the web card's own question), `events`
      -- is who just CROSSED the line within `days` — the one worth a push,
      -- the same unit breakout's own `hits` already are.
      hits_field = 'events',
      scan = function(opts)
          return subnew_scan({ universe = 'market', limit = 6000,
              days = math.max(1, math.min(cfg_int('SIGNALS_DAYS', 3), 20)),
              on_bars = opts.on_bars })
      end,
      fields = function(h) return { age = h.age, first_open = h.first_open, line = h.line,
                                    drop_pct = h.drop_pct } end,
      held = function(h) return false end },
}
local BY_ID = {}
for _, r in ipairs(RULES) do BY_ID[r.id] = r end

function g_exports.signals_rule_ids()
    local out = {}
    for _, r in ipairs(RULES) do out[#out + 1] = r.id end
    return out
end

local doc = nil           -- { version = 1, seq = n, items = {...}, last_run = { [rule] = {...} } }
local daily_override = nil

local function empty() return { version = 1, seq = 0, items = {}, last_run = {} } end

function g_exports.signals_load()
    local loaded, err = store_load('signals')
    if err then return nil, err end
    if loaded == nil then doc = empty(); return true end
    if type(loaded) ~= 'table' or type(loaded.items) ~= 'table' then
        return nil, 'signals.json has no items list'
    end
    doc = loaded
    doc.seq = tonumber(doc.seq) or #doc.items
    -- Before rules were namespaced, last_run was one flat object ({at=...}),
    -- not one per rule; that shape means nothing keyed by a rule that did not
    -- exist yet, so it starts over rather than being misread as one rule's.
    if type(doc.last_run) ~= 'table' or doc.last_run.at ~= nil then doc.last_run = {} end
    local kept, dropped = {}, {}
    for _, s in ipairs(doc.items) do
        local R = BY_ID[s.rule]
        if R and s.def == R.def then kept[#kept + 1] = s
        else dropped[s.rule] = (dropped[s.rule] or 0) + 1 end
    end
    for rule, n in pairs(dropped) do
        doc.last_run[rule] = nil
        cfg_log_info('signals: %d %s entr%s of an earlier definition dropped', n, tostring(rule),
            n == 1 and 'y' or 'ies')
    end
    doc.items = kept
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
-- late still leaves when its signal is that old.
local function prune()
    local keep = cfg_int('SIGNALS_KEEP_DAYS', 180)
    if keep <= 0 then return end
    local cut = util_date_add_days(util_today(), -keep)
    for i = #doc.items, 1, -1 do
        if tostring(doc.items[i].signal_date) < cut then table.remove(doc.items, i) end
    end
end

-- A function for a rule's scan `on_bars`: it moves each kept signal's latest
-- close to the newest bar read, by code — the same for every rule, since a
-- stock's price does not belong to one rule. Reading five thousand series
-- once is the expensive part of a scan; doing it again for the record would
-- be the same cost again.
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

-- Keep the new ones from a scan of `rule` as configured. `source` says what
-- ran it ('daily', 'web', 'cli'). Returns how many were added, and how many
-- of those are held back (the rule's own switch). Saves either way: the scan
-- may have moved the latest closes.
function g_exports.signals_record(rule, scan, source)
    local R = BY_ID[rule]
    if not R then return 0, 0 end
    local known, added = {}, {}
    for _, s in ipairs(doc.items) do known[s.id] = true end
    local now = util_now_iso()
    if type(scan) == 'table' and scan.configured then
        for _, h in ipairs(scan[R.hits_field] or {}) do
            local id = rule .. '|' .. h.code .. '|' .. tostring(h.date)
            if not known[id] then
                known[id] = true
                doc.seq = doc.seq + 1
                local item = {
                    seq = doc.seq, id = id, rule = rule, def = R.def,
                    code = h.code, name = h.name, industry = h.industry,
                    signal_date = h.date, signal_close = h.close,
                    added_at = now, added_date = h.last_date, added_close = h.last_close,
                    last_date = h.last_date, last_close = h.last_close,
                    pe_ttm = h.pe_ttm, pb = h.pb, roe = h.roe, market_cap = h.market_cap,
                    source = source, pushed = R.held(h) and 'held' or false,
                }
                for k, v in pairs(R.fields(h)) do item[k] = v end
                added[#added + 1] = item
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
        doc.last_run[rule] = { at = now, source = source, checked = scan.checked,
                               found = #(scan[R.hits_field] or {}), added = #added, held = held,
                               days = scan.days or (scan.params and scan.params.days),
                               regime = scan.regime and scan.regime.state }
    end
    prune()
    signals_save()
    if #added > 0 then cfg_log_info('signals: %d new %s from %s', #added, rule, tostring(source)) end
    return #added, held
end

local function pct(now, base)
    now, base = util_num(now), util_num(base)
    if not now or not base or base <= 0 then return nil end
    return (now / base - 1) * 100
end

-- The record by signal day, newest first, with the two gains worked out on
-- read. Stored order is the order things were ADDED, and a wider window adds
-- older signals after newer ones; within one day, the order the scan gave.
-- opts = { days = 30 (by signal day), limit = 500, rule? }: `rule` narrows to
-- one rule's entries (and its own last_run/title); left out, every rule's
-- entries come back mixed, newest first, each carrying its own `rule` field,
-- and `last_run` is the per-rule table rather than one summary.
function g_exports.signals_list(opts)
    opts = opts or {}
    local days = opts.days or 30
    local limit = opts.limit or 500
    local cut = util_date_add_days(util_today(), -days)
    local within = {}
    for _, s in ipairs(doc.items) do
        if (not opts.rule or s.rule == opts.rule) and tostring(s.signal_date) >= cut then
            within[#within + 1] = s
        end
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
    local R = opts.rule and BY_ID[opts.rule]
    -- Not `opts.rule and doc.last_run[opts.rule] or doc.last_run`: a rule that
    -- has never run has no entry, and that falls through to the whole
    -- per-rule table — which a client then reads as one rule's summary.
    local last_run = doc.last_run
    if opts.rule then last_run = doc.last_run[opts.rule] end
    return {
        rule = opts.rule, title = R and R.title() or nil, days = days,
        total = total, count = #out, items = util_json_array(out),
        last_run = last_run,
        daily = signals_daily(),
    }
end

-- Waiting to be pushed, oldest first, every rule mixed — a digest is one
-- message regardless of which rule found what.
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

-- Whether the daily check runs the built-in rules at all. Tests turn it off
-- for every check but their own: a whole-market scan is not what a test of
-- the watchlist asks. One switch for every rule, not one per rule — a check
-- either does this work or it does not.
function g_exports.signals_daily()
    if daily_override ~= nil then return daily_override end
    return cfg_bool('SIGNALS_DAILY', true)
end

function g_exports.__signals_set_daily(v)
    daily_override = v
end

-- COROUTINE-ONLY. The daily run for one rule: it as configured over the
-- whole market, the new finds kept. A few days of window, so a check that was
-- missed (the host was off, a holiday was mistaken for a trading day) still
-- finds what fired meanwhile — kept once each, whatever the overlap.
-- Returns the scan's summary with `added`, or nil plus (code, message).
function g_exports.signals_run(rule, source)
    local R = BY_ID[rule]
    if not R then return nil, 'bad_request', '未知规则：' .. tostring(rule) end
    local status = market_status()
    if not status or not status.ready then
        -- The universe is the snapshot's list of stocks. Without one there is
        -- nothing to scan; fetching it is about fifteen requests.
        local got, _, err = market_refresh()
        if not got then return nil, 'upstream', '没有全市场快照，抓取也失败了：' .. tostring(err) end
    end
    local res, ecode, emsg = R.scan({ on_bars = signals_price_updater() })
    if not res then return nil, ecode, emsg end
    local added, held = signals_record(rule, res, source or 'daily')
    local hits = res[R.hits_field] or {}
    return { rule = rule, checked = res.checked, found = #hits, added = added, held = held,
             days = res.days or (res.params and res.params.days),
             regime = res.regime and res.regime.state, fetch = res.fetch, params = res.params }
end
