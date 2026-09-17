-- engine/util.lua — strings, paths, files, JSON, numbers and dates.
--
-- Exports: util_is_windows,
--          util_str_trim, util_str_split, util_str_starts,
--          util_path_join, util_file_read, util_file_write_atomic,
--          util_file_exists, util_file_remove, util_dir_make,
--          util_null, util_json_array, util_json_encode, util_json_decode,
--          util_num, util_round, util_copy,
--          util_rand_hex, util_now_ms, util_now_iso,
--          util_date_valid, util_date_add_days, util_date_diff_days, util_today
--
-- Nothing here opens a socket or spawns a process. That is a rule for the whole
-- engine, not just this file: a phone embedding the runtime has no shell and no
-- git, and the engine has to run there unchanged.

local xutils = require('xutils')
local xfs    = dofile('scripts/core/share/xfs.lua')

g_exports.util_is_windows = package.config:sub(1, 1) == '\\'

-- ---------------------------------------------------------------------------
-- Strings
-- ---------------------------------------------------------------------------

function g_exports.util_str_trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Split on a Lua pattern class of separators. Empty fields are dropped.
function g_exports.util_str_split(s, sep_class)
    local out = {}
    for part in tostring(s or ''):gmatch('[^' .. (sep_class or '/') .. ']+') do
        out[#out + 1] = part
    end
    return out
end

function g_exports.util_str_starts(s, prefix)
    return tostring(s):sub(1, #prefix) == prefix
end

-- ---------------------------------------------------------------------------
-- Paths and files
--
-- Internally every path uses '/', including on Windows, where the CRT accepts
-- it everywhere.
-- ---------------------------------------------------------------------------

function g_exports.util_path_join(...)
    local parts = {}
    for _, p in ipairs({ ... }) do
        p = tostring(p or ''):gsub('\\', '/'):gsub('/+$', '')
        if p ~= '' then parts[#parts + 1] = p end
    end
    return (table.concat(parts, '/'):gsub('//+', '/'))
end

function g_exports.util_file_read(path)
    return xfs.read_file(path)
end

function g_exports.util_file_exists(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close()
    return true
end

function g_exports.util_file_remove(path)
    if not path then return false end
    return (pcall(os.remove, path))
end

-- Replace a file's contents so that a crash can never leave it missing or
-- half-written: every reader sees either the old file or the new one.
--
-- From gitloom, where losing the window between "delete the target" and "rename
-- the temp file" would have meant losing every account. Here it would mean
-- losing the watchlist. POSIX rename(2) replaces the destination atomically;
-- Windows os.rename refuses to, so the old file is moved aside first and only
-- removed once the new one is in place.
function g_exports.util_file_write_atomic(path, data)
    local tmp = path .. '.tmp'
    local ok, err = xfs.write_file(tmp, data)
    if not ok then return nil, 'write failed: ' .. tostring(err) end

    if not util_is_windows then
        local rok, rerr = os.rename(tmp, path)
        if not rok then
            util_file_remove(tmp)
            return nil, 'rename failed: ' .. tostring(rerr)
        end
        return true
    end

    local bak = path .. '.bak'
    local had_old = util_file_exists(path)
    if had_old then
        util_file_remove(bak)
        local mok, merr = os.rename(path, bak)
        if not mok then
            util_file_remove(tmp)
            return nil, 'could not move the old file aside: ' .. tostring(merr)
        end
    end

    local rok, rerr = os.rename(tmp, path)
    if not rok then
        if had_old then os.rename(bak, path) end
        util_file_remove(tmp)
        return nil, 'rename failed: ' .. tostring(rerr)
    end

    if had_old then util_file_remove(bak) end
    return true
end

-- The syscall, not xfs.mkdirp: that one runs os.execute, and the engine may be
-- somewhere without a shell.
function g_exports.util_dir_make(path)
    local ok, err = xutils.mkdir_p(path)
    if not ok then return nil, 'mkdir failed: ' .. tostring(err) end
    return true
end

-- ---------------------------------------------------------------------------
-- JSON
--
-- Two properties of the runtime's packer shape everything that produces JSON:
--
--   * A table is an array only when its keys are 1..n with no hole. A series
--     with a missing year — ROE for a company that did not report one — is a
--     Lua table with a nil in it, and would come out as an OBJECT keyed "1",
--     "3", "4". Missing values are therefore util_null, the runtime's JSON null
--     sentinel, never nil. json_unpack produces the same sentinel for a null it
--     reads, which is why nothing here trusts a field's type without checking.
--
--   * An empty table always packs as {}. util_json_array MARKS a list that may
--     be empty and returns it unchanged, so engine code and tests keep handling
--     ordinary tables; util_json_encode writes a marked empty table as []. The
--     same problem gitloom's util.lua solves, solved without handing callers a
--     placeholder string where they expected a table.
--
-- NaN and infinity are not JSON, and the packer fails the whole document on
-- one. util_num is the gate every computed number goes through.
-- ---------------------------------------------------------------------------

g_exports.util_null = xutils.json_null

local array_marks = setmetatable({}, { __mode = 'k' })
local empty_array_token = nil

function g_exports.util_json_array(t)
    if type(t) == 'table' then array_marks[t] = true end
    return t
end

-- Copy `v`, replacing every marked empty table with the placeholder. Only
-- tables are copied; the rest is shared.
local function substitute(v, token)
    if type(v) ~= 'table' then return v end
    if array_marks[v] and next(v) == nil then return token end
    local out = {}
    for k, x in pairs(v) do out[k] = substitute(x, token) end
    return out
end

-- Returns the JSON text, or nil plus a message.
function g_exports.util_json_encode(value)
    if not empty_array_token then
        empty_array_token = 'ZZxmoatEmptyArrayZZ' .. util_rand_hex(8)
    end
    local ok, json = pcall(xutils.json_pack, substitute(value, empty_array_token))
    if not ok then return nil, tostring(json) end
    if type(json) ~= 'string' then return nil, 'json_pack returned nothing' end
    local quoted = '"' .. empty_array_token .. '"'
    if json:find(quoted, 1, true) then json = json:gsub(quoted, '[]') end
    return json
end

-- Returns the decoded value, or nil plus a message. Never raises: every input
-- here comes from a network or a file that may be truncated.
function g_exports.util_json_decode(text)
    if type(text) ~= 'string' or text == '' then return nil, 'empty document' end
    local ok, value = pcall(xutils.json_unpack, text)
    if not ok then return nil, tostring(value) end
    return value
end

-- ---------------------------------------------------------------------------
-- Numbers
-- ---------------------------------------------------------------------------

-- A finite number, or nil. Data sources send null, "", "--" and occasionally a
-- number as a string; only a real finite number counts as a value.
function g_exports.util_num(v)
    if type(v) ~= 'number' then return nil end
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

-- Round for presentation. Stored data is never rounded — only what leaves the
-- engine in an analysis — so a recomputation always starts from source values.
function g_exports.util_round(v, digits)
    v = util_num(v)
    if not v then return nil end
    local m = 10 ^ (digits or 2)
    local r = math.floor(v * m + 0.5) / m
    if r == 0 then r = 0.0 end   -- no "-0" in the output
    return r
end

-- Shallow copy.
function g_exports.util_copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

-- ---------------------------------------------------------------------------
-- Time
--
-- Dates travel as 'YYYY-MM-DD' strings throughout: they sort as text, they are
-- what every data source already sends, and they carry no timezone for a phone
-- in another country to misread. Arithmetic converts at local noon so that a
-- DST jump can never move a date by a day.
-- ---------------------------------------------------------------------------

function g_exports.util_rand_hex(nbytes)
    nbytes = nbytes or 16
    local raw = xnet.random_bytes(nbytes)
    if not raw or #raw ~= nbytes then
        error('util_rand_hex: xnet.random_bytes failed', 2)
    end
    return xutils.hex_encode(raw)
end

-- A monotonic millisecond clock, for intervals and deadlines only — never for a
-- date. xtimer.now_ms is a plain C read, safe from any state, and needs no
-- xtimer.init.
function g_exports.util_now_ms()
    return xtimer.now_ms()
end

function g_exports.util_now_iso()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

function g_exports.util_today()
    return os.date('%Y-%m-%d')
end

local function date_time(d)
    local y, m, dd = tostring(d or ''):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
end

function g_exports.util_date_valid(d)
    local t = date_time(d)
    return t ~= nil and os.date('%Y-%m-%d', t) == tostring(d):sub(1, 10)
end

function g_exports.util_date_add_days(d, n)
    local t = date_time(d)
    if not t then return nil end
    return os.date('%Y-%m-%d', t + n * 86400)
end

-- b - a, in whole days.
function g_exports.util_date_diff_days(a, b)
    local ta, tb = date_time(a), date_time(b)
    if not ta or not tb then return nil end
    return math.floor((tb - ta) / 86400 + 0.5)
end
