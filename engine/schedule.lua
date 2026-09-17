-- engine/schedule.lua — the daily check, at fixed times in the market's timezone.
--
-- Exports: schedule_parse_times, schedule_parse_weekdays, schedule_clock,
--          schedule_due, schedule_next, schedule_start, schedule_stop,
--          schedule_status
--
-- Off unless a host starts it. main.lua does; the CLI does not, and a phone
-- host would rather let the operating system wake it and call alerts.run —
-- a background timer is exactly what mobile platforms kill first.
--
-- Times are wall-clock times at SCHEDULE_UTC_OFFSET (default +8, Beijing),
-- computed from UTC rather than from the machine's local zone: a server set to
-- UTC must still check after the A-share close, not eight hours early.
--
-- A slot runs at most once per day, and the day it last ran is kept in
-- data/state.json, so a restart does not repeat it. A slot whose time passed
-- while the process was down runs once when it comes back the same day — the
-- data that check was for is still the data there is. Holidays are not known;
-- a check on one finds nothing new and pushes nothing.

local TICK_MS = 30000

local timer = nil
local state = nil         -- { schedule_last = { ['17:30'] = 'YYYY-MM-DD' } }
local last_started = nil

-- '17:30' or '08:45,17:30' -> sorted list, or nil plus a message.
function g_exports.schedule_parse_times(s)
    local out, seen = {}, {}
    for part in tostring(s or ''):gmatch('[^,%s]+') do
        local h, m = part:match('^(%d%d?):(%d%d)$')
        h, m = tonumber(h), tonumber(m)
        if not h or h > 23 or m > 59 then return nil, '时间格式应为 HH:MM：' .. part end
        local hm = string.format('%02d:%02d', h, m)
        if not seen[hm] then seen[hm] = true; out[#out + 1] = hm end
    end
    if #out == 0 then return nil, '没有配置检查时间' end
    table.sort(out)
    return out
end

-- '1-5' or '1,3,5' (1 = Monday ... 7 = Sunday) -> set, or nil plus a message.
function g_exports.schedule_parse_weekdays(s)
    local set, any = {}, false
    for part in tostring(s or ''):gmatch('[^,%s]+') do
        local a, b = part:match('^(%d)%-(%d)$')
        a, b = tonumber(a or part), tonumber(b or a or part)
        if not a or not b or a < 1 or b > 7 or a > b then return nil, '星期应为 1-7：' .. part end
        for d = a, b do set[d] = true; any = true end
    end
    if not any then return nil, '没有配置星期' end
    return set
end

-- The wall clock at `offset_hours` from UTC, for epoch `now_s`.
-- Returns { date = 'YYYY-MM-DD', hm = 'HH:MM', iso_wday = 1..7, epoch }.
function g_exports.schedule_clock(offset_hours, now_s)
    now_s = now_s or os.time()
    local t = os.date('!*t', now_s + math.floor(offset_hours * 3600))
    return {
        date = string.format('%04d-%02d-%02d', t.year, t.month, t.day),
        hm = string.format('%02d:%02d', t.hour, t.min),
        iso_wday = (t.wday + 5) % 7 + 1,     -- os.date: 1 = Sunday
        epoch = now_s,
    }
end

-- Slots due now: allowed weekday, time reached, not yet run today.
function g_exports.schedule_due(clock, times, weekdays, last)
    local due = {}
    if not weekdays[clock.iso_wday] then return due end
    for _, hm in ipairs(times) do
        if clock.hm >= hm and (last or {})[hm] ~= clock.date then due[#due + 1] = hm end
    end
    return due
end

-- When the next check will happen, as 'YYYY-MM-DD HH:MM' in the schedule's
-- timezone: today's first slot that has not run (now, if its time has already
-- passed), otherwise the first slot of the next allowed day. nil when no
-- weekday is allowed.
function g_exports.schedule_next(clock, times, weekdays, last)
    last = last or {}
    if weekdays[clock.iso_wday] then
        for _, hm in ipairs(times) do
            if last[hm] ~= clock.date then
                return clock.date .. ' ' .. (hm < clock.hm and clock.hm or hm)
            end
        end
    end
    for day = 1, 7 do
        -- Date arithmetic at local noon on the clock's own date, so neither
        -- the answer nor the weekday depends on the host's timezone.
        local date = util_date_add_days(clock.date, day)
        local y, m, d = date:match('^(%d+)%-(%d+)%-(%d+)$')
        local t = os.date('*t', os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
        if weekdays[(t.wday + 5) % 7 + 1] then return date .. ' ' .. times[1] end
    end
    return nil
end

local function config()
    local times, terr = schedule_parse_times(cfg_get('SCHEDULE_TIMES', '17:30'))
    if not times then return nil, terr end
    local weekdays, werr = schedule_parse_weekdays(cfg_get('SCHEDULE_WEEKDAYS', '1-5'))
    if not weekdays then return nil, werr end
    return { times = times, weekdays = weekdays, offset = cfg_num('SCHEDULE_UTC_OFFSET', 8) }
end

local function tick()
    local conf = config()
    if not conf or alerts_running() then return end
    local clock = schedule_clock(conf.offset)
    local due = schedule_due(clock, conf.times, conf.weekdays, state.schedule_last)
    if #due == 0 then return end
    -- Marked before running, and saved: a run that crashes must not become a
    -- run that repeats every thirty seconds.
    for _, hm in ipairs(due) do state.schedule_last[hm] = clock.date end
    local ok, err = store_save('state', state)
    if not ok then cfg_log_error('schedule: cannot save state: %s', tostring(err)) end
    last_started = util_now_iso()
    cfg_log_system('scheduled check for %s %s', clock.date, table.concat(due, ','))
    sched_spawn('scheduled check', alerts_run)
end

-- MAIN STATE ONLY: arms an xtimer. Returns true, or nil plus a message.
function g_exports.schedule_start()
    if timer then return true end
    local conf, err = config()
    if not conf then return nil, err end
    local loaded, lerr = store_load('state')
    if lerr then return nil, lerr end
    state = type(loaded) == 'table' and loaded or {}
    state.schedule_last = type(state.schedule_last) == 'table' and state.schedule_last or {}
    timer = xtimer.add(TICK_MS, function()
        local ok, e = pcall(tick)
        if not ok then cfg_log_error('schedule tick failed: %s', tostring(e)) end
    end, -1)
    cfg_log_system('daily check at %s (UTC%+g), weekdays %s', table.concat(conf.times, ','),
        conf.offset, cfg_get('SCHEDULE_WEEKDAYS', '1-5'))
    return true
end

function g_exports.schedule_stop()
    if timer then timer:del(); timer = nil end
end

function g_exports.schedule_status()
    local conf, err = config()
    local out = { enabled = timer ~= nil, running = alerts_running(), last_started = last_started }
    if not conf then out.error = err; return out end
    out.times = util_json_array(conf.times)
    out.weekdays = cfg_get('SCHEDULE_WEEKDAYS', '1-5')
    out.utc_offset = conf.offset
    local clock = schedule_clock(conf.offset)
    out.now = clock.date .. ' ' .. clock.hm
    out.last_runs = state and state.schedule_last or {}
    if timer then out.next_run = schedule_next(clock, conf.times, conf.weekdays, out.last_runs) end
    return out
end
