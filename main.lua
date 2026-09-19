-- main.lua — xmoat as a local service: the engine, its JSON API, and the web page.
--
--   Run:  bin\xnet.exe main.lua [KEY=VAL ...]      (see xmoat.cfg for keys)
--   Open: http://127.0.0.1:8688/
--
-- THREE LAYERS, and the reason for them
--   engine/   everything that fetches, stores and computes. No socket is
--             listened on and no HTML is produced there.
--   host/     adapts transport to the engine's command registry: this HTTP
--             host now, a native bridge on a phone later.
--   web/      a pure client of /api/v1, rendering the analysis object.
-- A phone app embeds the runtime and the engine unchanged, and either runs
-- this file on 127.0.0.1 behind a WebView or calls api_call directly.
--
-- THIS FILE RUNS TWICE, like gitloom's main.lua: the runtime loads it into the
-- root `_G`, where the engine's short names do not resolve, so the first pass
-- only loads the loader and hands the file back to it. The second pass arrives
-- inside a module environment with `boot` as a chunk argument.

local boot = ...
if type(boot) ~= 'table' then
    boot = dofile('engine/boot.lua')
    return boot.run_script('main.lua', boot)
end

for _, path in ipairs(boot.run_script('engine/manifest.lua')) do boot.load_script(path) end
boot.load_script('host/http.lua')    -- http_*
boot.load_script('host/web.lua')     -- web_*
boot.load_script('host/wecom.lua')   -- wecom_*

local function __init()
    assert(xnet.init())
    xtimer.init(16)

    local ok, err = engine_start()
    if not ok then
        cfg_log_error('engine failed to start: %s', tostring(err))
        xthread.stop(1)
        return
    end

    http_install_api()
    web_install()
    wecom_install()

    -- The daily check belongs to a long-running host like this one. A phone
    -- host would call alerts.run when the OS wakes it instead.
    if cfg_bool('SCHEDULE_ENABLED', true) then
        local sok, serr = schedule_start()
        if not sok then
            cfg_log_error('schedule: %s', tostring(serr))
            xthread.stop(1)
            return
        end
    end

    ok, err = http_listen()
    if not ok then
        cfg_log_error('%s', tostring(err))
        xthread.stop(1)
        return
    end

    -- Lock _G: from here a mistyped global raises instead of reading nil.
    if cfg_bool('STRICT_GLOBALS', true) then boot.strict_enable() end
end

local function __uninit()
    http_close()
    engine_stop()
    xnet.uninit()
    cfg_log_system('xmoat stopped')
end

return {
    -- No cross-thread messages yet; present so the runtime does not warn.
    __thread_handle = function() end,
    __init = __init,
    __uninit = __uninit,
}
