-- engine/cfg.lua — configuration and logging.
--
-- Exports: cfg_get, cfg_int, cfg_num, cfg_bool,
--          cfg_log_system, cfg_log_info, cfg_log_warn, cfg_log_error, cfg_log_debug
--
-- Config comes from xutils' key=value store, which is FIRST-WINS: command-line
-- KEY=VAL arguments are already in it by the time this runs, so they beat every
-- file, and xmoat.local.cfg is loaded before xmoat.cfg so local overrides (API
-- keys, webhook URLs) beat the committed defaults. Same ordering as gitloom.
--
-- A host embedding the engine somewhere without these files (a phone app) sets
-- keys before loading the engine instead; a missing file is not an error.

local xutils = require('xutils')

xutils.load_config('xmoat.local.cfg')
xutils.load_config('xmoat.cfg')

function g_exports.cfg_get(key, default)
    return xutils.get_config(key, default)
end

function g_exports.cfg_int(key, default)
    local v = tonumber(xutils.get_config(key, tostring(default)))
    if not v then return default end
    return math.floor(v)
end

-- Rates and thresholds are fractional (DCF_DISCOUNT_RATE=10.5), which cfg_int
-- would truncate without saying so.
function g_exports.cfg_num(key, default)
    return tonumber(xutils.get_config(key, tostring(default))) or default
end

-- '1', 'true', 'yes', 'on' are true; everything else, including an unset key
-- with a false default, is false.
function g_exports.cfg_bool(key, default)
    local v = tostring(xutils.get_config(key, default and '1' or '0')):lower()
    return v == '1' or v == 'true' or v == 'yes' or v == 'on'
end

-- ---------------------------------------------------------------------------
-- Logging
--
-- xthread.log_init() is what gives THIS thread a log sink; without it every
-- xthread.log_* call from Lua is silently dropped while the C layer keeps
-- printing its own lines. print() does not reach stdout under the runtime
-- either — it goes to logs/ — so a host that must talk to a terminal (the CLI)
-- uses io.write.
-- ---------------------------------------------------------------------------
xthread.log_init()

local PREFIX = '[XMOAT] '

local function fmt(f, ...)
    if select('#', ...) == 0 then return PREFIX .. tostring(f) end
    local ok, s = pcall(string.format, tostring(f), ...)
    return PREFIX .. (ok and s or tostring(f))
end

function g_exports.cfg_log_system(f, ...) xthread.log_system(fmt(f, ...)) end
function g_exports.cfg_log_info(f, ...)   xthread.log_info(fmt(f, ...))   end
function g_exports.cfg_log_warn(f, ...)   xthread.log_warn(fmt(f, ...))   end
function g_exports.cfg_log_error(f, ...)  xthread.log_error(fmt(f, ...))  end
function g_exports.cfg_log_debug(f, ...)  xthread.log_debug(fmt(f, ...))  end
