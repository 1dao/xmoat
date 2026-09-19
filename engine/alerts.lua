-- engine/alerts.lua — the alert log, pushing it, and the check that fills it.
--
-- Exports: alerts_load, alerts_record, alerts_list, alerts_pending,
--          alerts_flush, alerts_flush_later, alerts_run, alerts_running
--
-- Events are recorded wherever a refresh happens — a scheduled run, the
-- "refresh" button, the CLI — because the comparison that finds them is
-- between the stored copy and the new one. A refresh that recorded nothing
-- would consume the difference, and the next scheduled run would find none.
-- Recording and pushing are therefore separate: every event lands here with
-- pushed = false, and a flush sends whatever is pending.
--
-- An event's `pushed` is one of:
--   false      waiting
--   true       delivered to at least one channel
--   'skipped'  no channel was configured when it was flushed — so configuring
--              one later does not replay months of old alerts at once
--   'failed'   every channel refused it MAX_ATTEMPTS times
--
-- Stored as data/alerts.json, newest first, capped at MAX_ITEMS.

local MAX_ITEMS = 500
local MAX_ATTEMPTS = 3

local doc = nil           -- { version = 1, seq = n, items = { event, ... } }
local flushing = false
local running = false

local function save()
    util_json_array(doc.items)
    local ok, err = store_save('alerts', doc)
    if not ok then cfg_log_error('alerts: save failed: %s', tostring(err)) end
    return ok, err
end

-- Returns true, or nil plus a message. An unreadable file is an error rather
-- than an empty log, for the same reason as the watchlist.
function g_exports.alerts_load()
    local loaded, err = store_load('alerts')
    if err then return nil, err end
    if loaded == nil then
        doc = { version = 1, seq = 0, items = {} }
        return true
    end
    if type(loaded) ~= 'table' or type(loaded.items) ~= 'table' then
        return nil, 'alerts.json has no items list'
    end
    doc = loaded
    doc.seq = tonumber(doc.seq) or #doc.items
    return true
end

-- Add events not already present (by id). Returns how many were added.
function g_exports.alerts_record(events)
    if not events or #events == 0 then return 0 end
    local known = {}
    for _, e in ipairs(doc.items) do known[e.id] = true end
    local now = util_now_iso()
    local added = {}
    for _, e in ipairs(events) do
        if not known[e.id] then
            known[e.id] = true
            doc.seq = doc.seq + 1
            e.seq, e.created_at, e.pushed = doc.seq, now, false
            added[#added + 1] = e
        end
    end
    if #added == 0 then return 0 end
    -- Newest first by seq, within a batch too: the last one added leads.
    for i = 1, #added do table.insert(doc.items, 1, added[i]) end
    while #doc.items > MAX_ITEMS do table.remove(doc.items) end
    save()
    for _, e in ipairs(added) do
        cfg_log_info('alert %s %s: %s', tostring(e.code), e.kind, e.title)
    end
    return #added
end

-- opts: { code?, limit? (default 50), after_seq? }. Newest first.
function g_exports.alerts_list(opts)
    opts = opts or {}
    local out, limit = {}, opts.limit or 50
    for _, e in ipairs(doc.items) do
        if (not opts.code or e.code == opts.code) and (not opts.after_seq or e.seq > opts.after_seq) then
            out[#out + 1] = e
            if #out >= limit then break end
        end
    end
    return out
end

-- Waiting events, OLDEST first: the order a digest reads in.
function g_exports.alerts_pending()
    local out = {}
    for i = #doc.items, 1, -1 do
        if doc.items[i].pushed == false then out[#out + 1] = doc.items[i] end
    end
    return out
end

-- COROUTINE-ONLY. Send everything pending as one digest. Returns
--   { sent = n, channels = { {kind, name, ok, error}, ... }, skipped = bool }
-- A flush already in progress makes this a no-op that says so; the running one
-- will not see events recorded after it started, and the next flush will.
function g_exports.alerts_flush()
    if flushing then return { sent = 0, busy = true, channels = util_json_array({}) } end
    local pending = alerts_pending()
    if #pending == 0 then return { sent = 0, channels = util_json_array({}) } end

    if #notify_channels() == 0 then
        for _, e in ipairs(pending) do e.pushed = 'skipped' end
        save()
        return { sent = 0, skipped = true, channels = util_json_array({}) }
    end

    flushing = true
    local ok, result = pcall(function()
        local msg = {
            title = string.format('xmoat 提醒（%d 条）', #pending),
            markdown = report_events_markdown(pending),
            text = report_events_text(pending),
            events = pending,
        }
        local results = notify_send(msg)
        local delivered = false
        for _, r in ipairs(results) do delivered = delivered or r.ok end
        local now = util_now_iso()
        for _, e in ipairs(pending) do
            if delivered then
                e.pushed, e.pushed_at = true, now
            else
                e.push_attempts = (e.push_attempts or 0) + 1
                if e.push_attempts >= MAX_ATTEMPTS then e.pushed = 'failed' end
            end
        end
        save()
        return { sent = delivered and #pending or 0, channels = util_json_array(results) }
    end)
    flushing = false
    if not ok then
        cfg_log_error('alerts flush raised: %s', tostring(result))
        return { sent = 0, error = '推送时出错', channels = util_json_array({}) }
    end
    return result
end

-- Flush on a coroutine of its own, so a refresh answers its caller without
-- waiting on WeCom. Safe from any coroutine.
function g_exports.alerts_flush_later()
    sched_spawn('alerts flush', alerts_flush)
end

function g_exports.alerts_running()
    return running
end

-- COROUTINE-ONLY. Refresh every watched stock (recording events as each
-- refresh does), then push what is pending. The scheduled check and the
-- "check now" command are both this. Returns
--   { refreshed = { {code, ok, error?} }, new_events = n, push = <flush result> }
function g_exports.alerts_run()
    if running then return nil, 'conflict', '已有一次检查正在进行' end
    running = true
    local ok, result = pcall(function()
        local seq_before = doc.seq
        local refreshed = {}
        for _, e in ipairs(watch_list()) do
            local rec, ecode, emsg = stock_refresh(e.code)
            refreshed[#refreshed + 1] = rec and { code = e.code, ok = true }
                or { code = e.code, ok = false, error = { code = ecode, message = emsg } }
        end
        -- A new annual report is the moment a reading is worth paying for.
        -- Generated before the flush so it goes out in the same digest.
        if cfg_bool('INSIGHT_ON_ANNUAL_REPORT', true) and llm_config() then
            local codes, seen = {}, {}
            for _, e in ipairs(doc.items) do
                if e.seq <= seq_before then break end
                if e.kind == 'report' and tostring(e.period):sub(6) == '12-31' and not seen[e.code] then
                    seen[e.code] = true
                    codes[#codes + 1] = e.code
                end
            end
            for _, code in ipairs(codes) do
                local ins, _, ierr = insight_generate(code)
                if ins then
                    alerts_record({ {
                        id = events_id(code, 'insight|' .. tostring(ins.report_period)),
                        code = code, name = ins.name, kind = 'insight', period = ins.report_period,
                        title = '年报解读（大模型）', detail = insight_summary_line(ins),
                    } })
                else
                    cfg_log_warn('%s: annual report insight failed: %s', code, tostring(ierr))
                end
            end
        end

        -- A background flush started by an earlier refresh may still be
        -- sending; it cannot see what this run recorded, and flushing now
        -- would only report busy and leave those alerts for tomorrow's check.
        sched_wait_until(function() return not flushing end, 120000)
        local push = alerts_flush()
        return { refreshed = util_json_array(refreshed), new_events = doc.seq - seq_before, push = push }
    end)
    running = false
    if not ok then
        cfg_log_error('alerts run raised: %s', tostring(result))
        return nil, 'internal', '检查时出错'
    end
    cfg_log_system('check finished: %d stock(s), %d new alert(s), %d pushed',
        #result.refreshed, result.new_events, result.push.sent or 0)
    return result
end
