-- engine/sched.lua — waiting and delayed work for code running on a coroutine.
--
-- Exports: sched_start, sched_stop, sched_after, sched_sleep, sched_wait_until,
--          sched_spawn
--
-- Everything the engine does that touches the network runs on a coroutine,
-- and two things such a coroutine needs cannot come from xtimer directly:
-- waiting for a condition, and arranging for something to happen later (the
-- timeout that abandons a slow data source).
--
-- The reason is in the runtime, and gitloom found it the hard way: xtimer
-- records the lua_State that ARMED a timer and calls back into it. A timer
-- armed inside a coroutine fires into that coroutine's state while it is
-- suspended, which is a crash. xhttp_client's own timeout_ms option arms its
-- timer wherever request() is called, so it must never be used from here.
--
-- So there is ONE timer, armed from the main state by sched_start, and both
-- facilities are lists it walks. Its callbacks run on the main state, where
-- resuming a suspended coroutine is exactly what coroutine.resume is for.
-- Socket callbacks are safe by contrast: xnet stores the main state for them.

local timers  = {}      -- { at, fn, cancelled }
local waiters = {}      -- { co, ready, deadline }
local tick_timer = nil

local function tick()
    if #timers > 0 then
        local now, live, due = util_now_ms(), {}, nil
        for i = 1, #timers do
            local t = timers[i]
            if t.cancelled then
            elseif now >= t.at then due = due or {}; due[#due + 1] = t
            else live[#live + 1] = t end
        end
        timers = live
        for i = 1, due and #due or 0 do
            local ok, e = pcall(due[i].fn)
            if not ok then cfg_log_error('scheduled callback failed: %s', tostring(e)) end
        end
    end

    if #waiters > 0 then
        local now, live, due = util_now_ms(), {}, nil
        for i = 1, #waiters do
            local w = waiters[i]
            local go = w.deadline ~= nil and now >= w.deadline
            if not go then
                local ok, ready = pcall(w.ready)
                go = (not ok) or ready == true
            end
            if go then due = due or {}; due[#due + 1] = w
            else live[#live + 1] = w end
        end
        -- Swapped BEFORE anything is resumed: a coroutine that parks again
        -- straight away has to land on the new list.
        waiters = live
        for i = 1, due and #due or 0 do
            local ok, e = coroutine.resume(due[i].co)
            if not ok then cfg_log_error('a parked coroutine crashed: %s', tostring(e)) end
        end
    end
end

-- MAIN STATE ONLY: from __init, never from a coroutine. Resolution is one tick,
-- so waits are good to tick_ms and no better.
function g_exports.sched_start(tick_ms)
    if tick_timer then return end
    tick_timer = xtimer.add(tick_ms or 50, tick, -1)
end

function g_exports.sched_stop()
    if tick_timer then tick_timer:del(); tick_timer = nil end
end

-- Run fn once, on the main state, after delay_ms. Returns a cancel function.
-- Safe to call from a coroutine, which xtimer.add is not.
function g_exports.sched_after(delay_ms, fn)
    local t = { at = util_now_ms() + delay_ms, fn = fn, cancelled = false }
    timers[#timers + 1] = t
    return function() t.cancelled = true end
end

-- Park the running coroutine until ready() answers true or timeout_ms passes.
-- Returns what ready() says at that point. COROUTINE-ONLY.
--
-- Nothing else may resume a coroutine parked here: the ticker holds it and
-- would resume it a second time. Express the other event in ready() instead.
function g_exports.sched_wait_until(ready, timeout_ms)
    if ready() then return true end
    waiters[#waiters + 1] = {
        co       = coroutine.running(),
        ready    = ready,
        deadline = timeout_ms and (util_now_ms() + timeout_ms) or nil,
    }
    coroutine.yield()
    return ready() == true
end

-- COROUTINE-ONLY. Used to pace requests to a data source.
function g_exports.sched_sleep(ms)
    local wake = util_now_ms() + ms
    sched_wait_until(function() return util_now_ms() >= wake end)
end

-- Run fn(...) on a fresh coroutine, reporting a raise instead of losing it.
-- The first resume happens here, so fn runs until its first yield before this
-- returns. Returns the coroutine.
function g_exports.sched_spawn(label, fn, ...)
    local args = table.pack(...)
    local co = coroutine.create(function()
        local ok, err = xpcall(function() return fn(table.unpack(args, 1, args.n)) end,
            debug and debug.traceback or tostring)
        if not ok then cfg_log_error('%s failed: %s', tostring(label), tostring(err)) end
    end)
    local ok, err = coroutine.resume(co)
    if not ok then cfg_log_error('%s crashed: %s', tostring(label), tostring(err)) end
    return co
end
