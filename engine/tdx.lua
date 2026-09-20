-- engine/tdx.lua — the 通达信 (TDX) quote protocol, spoken directly.
--
-- Exports: tdx_frame, tdx_take_frame, tdx_price_at, tdx_volume, tdx_date,
--          tdx_parse_bars, tdx_parse_xdxr, tdx_market_of, tdx_servers,
--          tdx_acquire, tdx_release, tdx_with, tdx_bars, tdx_xdxr,
--          tdx_status, tdx_shutdown
--
-- WHY THIS EXISTS. Eastmoney serves one stock's daily history as half a
-- megabyte of JSON over a fresh HTTPS connection, and starts dropping
-- connections after a couple of dozen in a row — measured, not guessed: a scan
-- of forty stocks lost nineteen of them. The quote servers every 通达信 client
-- talks to serve the same bars as about 14 KB of compressed binary over a
-- connection that stays open. That difference is what makes "scan a few
-- hundred stocks" a reasonable thing to do at all.
--
-- THE PROTOCOL, as spoken here:
--   request   <u16 0x010c> <u32 magic> <u16 len> <u16 len> <u16 msg> <payload>
--             len = 2 + #payload; magic is a constant per command, copied from
--             the reference implementation rather than invented
--   response  <u32 0x0074cbb1> <u8 zipped> <u32 magic> <u8 ?> <u16 msg>
--             <u16 zipsize> <u16 rawsize> <body>
--             the body is zlib-compressed when the two sizes differ
--
-- A connection answers one request at a time, in order, but a frame that is
-- not the answer is skipped rather than mistaken for one: that is the
-- difference between a wrong number and a missing one.
--
-- NOT ADJUSTED. These bars are raw prices, as the exchange printed them.
-- engine/source_tdx.lua applies the forward adjustment from the ex-rights
-- records, because everything else in xmoat reads forward-adjusted prices.

local xcompress = require('xcompress')

-- Servers that answered a bar request when this was written. They are a
-- default, not a promise: TDX_SERVERS replaces the list, and a host that stops
-- serving is skipped at connect time.
local DEFAULT_SERVERS =
    '117.34.114.16:7709,117.34.114.27:7709,117.34.114.15:7709,117.34.114.17:7709,117.34.114.20:7709'

local MSG_BARS, MSG_XDXR = 0x052d, 0x000f
-- The per-command constant in the request header. The ex-rights command
-- carries its own fixed prefix instead; see tdx_xdxr.
local MAGIC_BARS = 0x01016408

local function hexbytes(s)
    return (s:gsub('%s', ''):gsub('%x%x', function(h) return string.char(tonumber(h, 16)) end))
end

-- The three packets a client sends before it may ask anything. Their answers
-- are discarded; what matters is that the server accepted them.
local SETUP = {
    hexbytes('0c 02 18 93 00 01 03 00 03 00 0d 00 01'),
    hexbytes('0c 02 18 94 00 01 03 00 03 00 0d 00 02'),
    hexbytes('0c 03 18 99 00 01 20 00 20 00 db 0f d5 d0 c9 cc d6 a4 a8 af 00 00 00 8f c2 25'
             .. '40 13 00 00 d5 00 c9 cc bd f0 d7 ea 00 00 00 02'),
}

-- ---------------------------------------------------------------------------
-- Pure: framing and the number formats
-- ---------------------------------------------------------------------------

function g_exports.tdx_frame(msg, payload, magic)
    local len = #payload + 2
    return string.pack('<I2I4I2I2I2', 0x010c, magic or 0x01016408, len, len, msg) .. payload
end

-- One frame out of a buffer. Returns msg, body, rest — or nil when the buffer
-- does not hold a whole frame yet, and nil plus a message when it holds a
-- broken one.
function g_exports.tdx_take_frame(buf)
    if #buf < 16 then return nil end
    local _, _, _, _, msg, zipsize, rawsize = string.unpack('<I4BI4BI2I2I2', buf)
    if #buf < 16 + zipsize then return nil end
    local body = buf:sub(17, 16 + zipsize)
    if zipsize ~= rawsize then
        local plain, derr = xcompress.zlib_decompress(body, rawsize)
        if not plain then return nil, 'inflate failed: ' .. tostring(derr) end
        body = plain
    end
    return msg, body, buf:sub(17 + zipsize)
end

-- A price: six value bits, a sign bit at 0x40, 0x80 to continue. The unit is
-- a thousandth of a yuan, and the value is a difference — see tdx_parse_bars.
function g_exports.tdx_price_at(s, pos)
    local b = s:byte(pos)
    if not b then return nil, pos end
    local v, neg, shift = b & 0x3f, (b & 0x40) ~= 0, 6
    while (b & 0x80) ~= 0 do
        pos = pos + 1
        b = s:byte(pos)
        if not b then return nil, pos end
        v = v + ((b & 0x7f) << shift)
        shift = shift + 7
    end
    return (neg and -v or v), pos + 1
end

-- TDX's own 32-bit float, used for volumes and turnover. Transcribed from the
-- reference implementation, which transcribed it from the client's assembly;
-- it is checked against a recorded response in test/unit.lua.
function g_exports.tdx_volume(ivol)
    local logpoint = ivol >> 24
    local hleax = (ivol >> 16) & 0xff
    local lheax = (ivol >> 8) & 0xff
    local lleax = ivol & 0xff
    local ecx, edx = logpoint * 2 - 0x7f, logpoint * 2 - 0x86
    local esi, eax = logpoint * 2 - 0x8e, logpoint * 2 - 0x96
    local v6 = 2.0 ^ math.abs(ecx)
    if ecx < 0 then v6 = 1.0 / v6 end
    local v4
    if hleax > 0x80 then
        v4 = 2.0 ^ edx * 128.0 + (hleax & 0x7f) * (2.0 ^ (edx + 1))
    elseif edx >= 0 then
        v4 = 2.0 ^ edx * hleax
    else
        v4 = (1 / 2.0 ^ edx) * hleax
    end
    local v3 = 2.0 ^ esi * lheax
    local v1 = 2.0 ^ eax * lleax
    if (hleax & 0x80) ~= 0 then v3, v1 = v3 * 2.0, v1 * 2.0 end
    return v6 + v4 + v3 + v1
end

-- A daily bar's date: one u32 of YYYYMMDD.
function g_exports.tdx_date(n)
    local y, m, d = n // 10000, (n % 10000) // 100, n % 100
    if y < 1990 or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
    return string.format('%04d-%02d-%02d', y, m, d)
end

-- Daily bars, oldest first. Every price in the body is a difference: the open
-- is a difference from the previous bar's running base, and the other three
-- are differences from that open.
function g_exports.tdx_parse_bars(body)
    if type(body) ~= 'string' or #body < 2 then return nil, 'empty response' end
    local count = string.unpack('<I2', body)
    local pos, rows, base = 3, {}, 0
    for _ = 1, count do
        if pos + 3 > #body then return nil, 'truncated response' end
        local daynum = string.unpack('<I4', body, pos); pos = pos + 4
        local date = tdx_date(daynum)
        local o, c, hi, lo
        o, pos = tdx_price_at(body, pos)
        c, pos = tdx_price_at(body, pos)
        hi, pos = tdx_price_at(body, pos)
        lo, pos = tdx_price_at(body, pos)
        if not (date and o and c and hi and lo) or pos + 7 > #body then
            return nil, 'truncated response'
        end
        local vol_raw = string.unpack('<I4', body, pos); pos = pos + 4
        local amt_raw = string.unpack('<I4', body, pos); pos = pos + 4
        local open_abs = o + base
        rows[#rows + 1] = {
            date = date,
            open = open_abs / 1000, close = (open_abs + c) / 1000,
            high = (open_abs + hi) / 1000, low = (open_abs + lo) / 1000,
            volume = tdx_volume(vol_raw),      -- 手
            amount = tdx_volume(amt_raw),      -- yuan
        }
        base = open_abs + c
    end
    return rows
end

-- The ex-rights records: what happened to a share, and when. Only the cash
-- dividend and share categories matter for adjusting a price, and only those
-- are returned; the rest (capital changes, warrants) are counted and dropped.
function g_exports.tdx_parse_xdxr(body)
    if type(body) ~= 'string' or #body < 11 then return {} end
    local pos = 10                                  -- nine bytes of header
    local count = string.unpack('<I2', body, pos); pos = pos + 2
    local out, others = {}, 0
    for _ = 1, count do
        if pos + 27 > #body then break end
        pos = pos + 8                               -- market, code, one spare
        local daynum = string.unpack('<I4', body, pos); pos = pos + 4
        local category = string.unpack('<B', body, pos); pos = pos + 1
        local date = tdx_date(daynum)
        if category == 1 then
            -- Per ten shares, as every Chinese announcement states them.
            local bonus, rights_price, shares, rights = string.unpack('<ffff', body, pos)
            if date then
                out[#out + 1] = { date = date, bonus = bonus, rights_price = rights_price,
                                  shares = shares, rights = rights }
            end
        else
            others = others + 1
        end
        pos = pos + 16
    end
    table.sort(out, function(a, b) return a.date < b.date end)
    return out, others
end

-- Which TDX market a code belongs to: 0 Shenzhen, 1 Shanghai, 2 Beijing.
function g_exports.tdx_market_of(code)
    local p2 = tostring(code):sub(1, 2)
    if p2 == '60' or p2 == '68' or p2 == '51' or p2 == '11' then return 1 end
    if p2 == '43' or p2 == '83' or p2 == '87' or p2 == '88' or p2 == '92' then return 2 end
    return 0
end

-- ---------------------------------------------------------------------------
-- Connections
-- ---------------------------------------------------------------------------

function g_exports.tdx_servers()
    local out = {}
    for item in cfg_get('TDX_SERVERS', DEFAULT_SERVERS):gmatch('[^,%s]+') do
        local host, port = item:match('^([^:]+):(%d+)$')
        if host then out[#out + 1] = { host = host, port = tonumber(port) } end
    end
    return out
end

local pool = {}            -- every session this process has opened
local preferred = nil      -- the server that answered last, tried first

local function raw_call(s, pkg, want_msg, timeout_ms)
    local ok, err = s.conn:send_raw(pkg)
    if not ok then return nil, 'send failed: ' .. tostring(err) end
    local deadline = util_now_ms() + (timeout_ms or cfg_int('TDX_TIMEOUT_MS', 10000))
    while true do
        local msg, body, rest = tdx_take_frame(s.buf)
        if msg then
            s.buf = rest
            if not want_msg or msg == want_msg then return body end
            cfg_log_debug('tdx: skipped frame 0x%04x (%d bytes)', msg, #body)
        elseif body then
            return nil, body                          -- a broken frame
        else
            if s.closed then return nil, 'connection closed: ' .. tostring(s.closed) end
            if util_now_ms() > deadline then return nil, 'timeout' end
            sched_sleep(10)
        end
    end
end

-- COROUTINE-ONLY. Open one connection and put it through the handshake.
local function open_session(server)
    local s = { buf = '', host = server.host, port = server.port }
    local h = {}
    function h.on_connect() s.connected = true end
    local function on_data(_, data) s.buf = s.buf .. data; return #data end
    h.on_packet, h.on_recv = on_data, on_data
    function h.on_close(_, why) s.closed = why or 'closed' end

    local conn, cerr = xnet.connect(server.host, server.port, h)
    if not conn then return nil, tostring(cerr) end
    s.conn = conn
    sched_wait_until(function() return s.connected or s.closed end,
                     cfg_int('TDX_CONNECT_MS', 5000))
    if not s.connected then
        conn:close('timeout')
        return nil, s.closed or 'connect timeout'
    end
    for _, pkg in ipairs(SETUP) do
        local body, err = raw_call(s, pkg, nil, cfg_int('TDX_CONNECT_MS', 5000))
        if not body then
            conn:close('handshake')
            return nil, 'handshake: ' .. tostring(err)
        end
    end
    s.opened_at = util_now_iso()
    return s
end

-- COROUTINE-ONLY. A connection to work on, from the pool or newly opened.
-- Returns the session, or nil plus a message when no server would talk.
function g_exports.tdx_acquire()
    for _, s in ipairs(pool) do
        if not s.busy and not s.closed then s.busy = true; return s end
    end
    local max = cfg_int('TDX_CONNECTIONS', 4)
    local live = 0
    for _, s in ipairs(pool) do if not s.closed then live = live + 1 end end
    if live >= max then
        -- Wait for one to come free rather than opening a sixth.
        local got
        sched_wait_until(function()
            for _, s in ipairs(pool) do
                if not s.busy and not s.closed then got = s; return true end
            end
            return false
        end, cfg_int('TDX_TIMEOUT_MS', 10000))
        if got then got.busy = true; return got end
        return nil, '没有空闲的行情连接'
    end

    local servers, errs = tdx_servers(), {}
    if preferred then table.insert(servers, 1, preferred) end
    for _, server in ipairs(servers) do
        local s, err = open_session(server)
        if s then
            preferred = server
            s.busy = true
            pool[#pool + 1] = s
            cfg_log_info('tdx: connected to %s:%d (%d open)', s.host, s.port, #pool)
            return s
        end
        errs[#errs + 1] = string.format('%s:%d %s', server.host, server.port, tostring(err))
    end
    return nil, '没有可用的行情服务器：' .. table.concat(errs, '; ')
end

function g_exports.tdx_release(s)
    if s then s.busy = false end
end

-- COROUTINE-ONLY. Run `fn(session)` on a pooled connection, releasing it
-- however fn ends. A connection that failed mid-call is closed rather than
-- returned to the pool: its buffer may hold half an answer.
function g_exports.tdx_with(fn)
    local s, err = tdx_acquire()
    if not s then return nil, err end
    local ok, a, b = pcall(fn, s)
    if not ok or a == nil then
        if s.closed then
            for i, item in ipairs(pool) do
                if item == s then table.remove(pool, i); break end
            end
        end
    end
    tdx_release(s)
    if not ok then return nil, tostring(a) end
    return a, b
end

-- COROUTINE-ONLY. `count` daily bars ending at the newest one, oldest first.
-- TDX serves at most 800 per request, so more than that is several.
function g_exports.tdx_bars(code, count)
    count = math.max(1, count or 800)
    local market = tdx_market_of(code)
    return tdx_with(function(s)
        local all = {}
        local start = 0
        while #all < count do
            local want = math.min(800, count - #all)
            local payload = string.pack('<I2c6I2I2I2I2I4I4I2',
                market, code, 9, 1, start, want, 0, 0, 0)
            local body, err = raw_call(s, tdx_frame(MSG_BARS, payload, MAGIC_BARS), MSG_BARS)
            if not body then return nil, err end
            local rows, perr = tdx_parse_bars(body)
            if not rows then return nil, perr end
            if #rows == 0 then break end
            -- `start` counts back from the newest bar, so each page is older
            -- than the last and the pages are prepended.
            for i = #rows, 1, -1 do table.insert(all, 1, rows[i]) end
            if #rows < want then break end
            start = start + #rows
        end
        return all
    end)
end

-- COROUTINE-ONLY. The ex-rights records for a code, oldest first.
function g_exports.tdx_xdxr(code)
    local market = tdx_market_of(code)
    return tdx_with(function(s)
        -- This command's header carries its own constants; the reference
        -- implementation sends them as a fixed prefix and so does this.
        local pkg = hexbytes('0c 1f 18 76 00 01 0b 00 0b 00 0f 00 01 00')
            .. string.pack('<Bc6', market, code)
        local body, err = raw_call(s, pkg, MSG_XDXR)
        if not body then return nil, err end
        return tdx_parse_xdxr(body)
    end)
end

function g_exports.tdx_status()
    local open, busy = 0, 0
    for _, s in ipairs(pool) do
        if not s.closed then open = open + 1 end
        if s.busy then busy = busy + 1 end
    end
    return { open = open, busy = busy, max = cfg_int('TDX_CONNECTIONS', 4),
             server = preferred and (preferred.host .. ':' .. preferred.port) or nil,
             servers = #tdx_servers() }
end

-- MAIN STATE or anywhere. Close every connection; engine_stop calls this.
function g_exports.tdx_shutdown()
    for _, s in ipairs(pool) do
        if s.conn and not s.conn:is_closed() then s.conn:close('shutdown') end
    end
    pool = {}
end
