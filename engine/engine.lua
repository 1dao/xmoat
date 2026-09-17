-- engine/engine.lua — starting and stopping the engine inside a host.
--
-- Exports: engine_version, engine_start, engine_stop
--
-- What a host must do, whatever the host is:
--   1. load engine/boot.lua and every path in engine/manifest.lua
--   2. from the MAIN state (__init): xnet.init(), xtimer.init(), engine_start()
--   3. run commands on coroutines: api_call(name, params, ctx)
--   4. on shutdown: engine_stop()
-- Nothing here listens on a socket or writes to a terminal; that is the host's
-- business.

g_exports.engine_version = '0.1.0'

local started = false

-- MAIN STATE ONLY. opts: { data_dir = <path> } overrides DATA_DIR.
-- Returns true, or nil plus a message.
function g_exports.engine_start(opts)
    if started then return true end
    opts = opts or {}
    local ok, err = store_init(opts.data_dir)
    if not ok then return nil, err end
    ok, err = watch_load()
    if not ok then return nil, 'watchlist: ' .. tostring(err) end
    sched_start(cfg_int('SCHED_TICK_MS', 20))
    commands_install()
    started = true
    cfg_log_system('engine %s started, data in %s, %d stock(s) watched',
        engine_version, store_dir(), #watch_list())
    return true
end

function g_exports.engine_stop()
    if not started then return end
    sched_stop()
    started = false
end
