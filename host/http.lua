-- host/http.lua — the HTTP host: the engine's commands over JSON, and a listener.
--
-- Exports: http_route, http_dispatch, http_json, http_install_api,
--          http_listen, http_close
--
-- This file adapts transport and owns nothing else. Every /api/v1 route is
-- generated from the engine's command registry (api_list), so a command added
-- to engine/commands.lua is reachable here without touching this file, and the
-- web page, the CLI and a future phone bridge all reach the same handler.
--
-- The serve loop is gitloom's shape without its streaming machinery: raw
-- framing, the codec parsing whole requests from a per-connection buffer, ONE
-- COROUTINE PER REQUEST so a handler can wait on a data source while the event
-- loop serves everyone else, and requests on one connection serialised behind
-- `busy` because HTTP/1.1 responses must come back in order. Bodies here are a
-- few KB of JSON, so the buffering gitloom needed for packfiles is not.

local codec = dofile('scripts/core/share/xhttp_codec.lua')

local routes = {}          -- method -> { {segs, handler, pattern}, ... }
local server = nil
local sweep_timer = nil
local MAX_REQUEST = 1024 * 1024
local IDLE_MS = 60000

-- ---------------------------------------------------------------------------
-- Responses and routing
-- ---------------------------------------------------------------------------

function g_exports.http_json(status, value, headers)
    local body, err = util_json_encode(value)
    if not body then
        cfg_log_error('response encoding failed: %s', tostring(err))
        status = 500
        body = '{"ok":false,"error":{"code":"internal","message":"响应编码失败"}}'
    end
    local h = { ['Content-Type'] = 'application/json; charset=utf-8',
                ['Cache-Control'] = 'no-store' }
    for k, v in pairs(headers or {}) do h[k] = v end
    return { status = status, body = body, headers = h }
end

-- pattern: '/api/v1/stocks/:code/refresh'. A ':name' segment matches one
-- non-empty path segment and is passed to the handler as ctx.params.name.
function g_exports.http_route(method, pattern, handler)
    method = method:upper()
    routes[method] = routes[method] or {}
    local segs = {}
    for seg in pattern:gmatch('[^/]+') do
        segs[#segs + 1] = seg:match('^:(.+)$') and { param = seg:sub(2) } or seg
    end
    table.insert(routes[method], { segs = segs, handler = handler, pattern = pattern })
end

local function match(method, path)
    local list = routes[method]
    if not list then return nil end
    local parts = util_str_split(path, '/')
    for _, r in ipairs(list) do
        if #parts == #r.segs then
            local params, ok = {}, true
            for i, seg in ipairs(r.segs) do
                if type(seg) == 'table' then
                    params[seg.param] = codec.uri_decode(parts[i])
                elseif seg ~= parts[i] then
                    ok = false
                    break
                end
            end
            if ok then return r.handler, params end
        end
    end
    return nil
end

-- Resolve one request to a response. Exported so test/unit.lua can drive
-- routing without a socket. COROUTINE-ONLY when the route reaches a command
-- that fetches.
function g_exports.http_dispatch(req, ctx)
    local method = req.method:upper()
    local handler, params = match(method, req.path)
    if not handler and method == 'HEAD' then handler, params = match('GET', req.path) end
    if handler then
        ctx.params = params
        return handler(req, ctx)
    end
    if util_str_starts(req.path, '/api/') then
        return http_json(404, { ok = false, error = { code = 'not_found', message = '没有这个接口' } })
    end
    return { status = 404, body = 'not found\n', headers = { ['Content-Type'] = 'text/plain; charset=utf-8' } }
end

-- ---------------------------------------------------------------------------
-- The API surface
--
-- Params for a command are the JSON body (an object), then the query string,
-- then the path parameters — later wins, so a body cannot retarget a request
-- at a different stock than its URL names.
--
-- API_TOKEN, when set, is required as `Authorization: Bearer <token>` on every
-- /api request. Unset, the listener refuses to start on anything but loopback:
-- the watchlist is personal and a refresh spends the operator's address's
-- standing with the data source.
-- ---------------------------------------------------------------------------

local function same(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

local function cors_headers()
    local origin = cfg_get('CORS_ORIGIN', '')
    if origin == '' then return nil end
    return {
        ['Access-Control-Allow-Origin'] = origin,
        ['Access-Control-Allow-Methods'] = 'GET, POST, PATCH, DELETE, OPTIONS',
        ['Access-Control-Allow-Headers'] = 'Content-Type, Authorization',
        ['Access-Control-Max-Age'] = '600',
        ['Vary'] = 'Origin',
    }
end

local function api_handler(name)
    return function(req, ctx)
        local cors = cors_headers()
        local token = cfg_get('API_TOKEN', '')
        if token ~= '' then
            local auth = req.headers and req.headers['authorization'] or ''
            if not same(auth:match('^Bearer%s+(.+)$'), token) then
                return http_json(401, { ok = false, error = { code = 'unauthorized',
                    message = '需要 API_TOKEN' } }, cors)
            end
        end

        local params = {}
        local body = req.body or ''
        if body ~= '' then
            local decoded = util_json_decode(body)
            if type(decoded) ~= 'table' then
                return http_json(400, { ok = false, error = { code = 'bad_request',
                    message = '请求体必须是 JSON 对象' } }, cors)
            end
            for k, v in pairs(decoded) do params[k] = v end
        end
        for k, v in pairs(req.query or {}) do
            -- parse_query yields a list for a repeated key; the first one wins.
            params[k] = type(v) == 'table' and v[1] or v
        end
        for k, v in pairs(ctx.params or {}) do params[k] = v end

        local res = api_call(name, params, { host = 'http', ip = ctx.ip })
        local status = res.ok and 200 or api_status_of(res.error.code)
        return http_json(status, res, cors)
    end
end

function g_exports.http_install_api()
    local seen = {}
    for _, c in ipairs(api_list()) do
        if c.method and c.path then
            http_route(c.method, c.path, api_handler(c.name))
            if not seen[c.path] then
                seen[c.path] = true
                http_route('OPTIONS', c.path, function()
                    return { status = 204, body = '', headers = cors_headers() or {} }
                end)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Serve loop
-- ---------------------------------------------------------------------------

local conns = setmetatable({}, { __mode = 'k' })
local resp_opts = { server_name = 'xmoat',
                    compression = { enabled = true, min_size = 1024 } }
local parse_opts = { max_request_size = MAX_REQUEST }

local pump

local function dispatch_request(conn, st, req)
    st.busy = true
    local co = coroutine.create(function()
        local ok, resp = pcall(http_dispatch, req, { ip = st.ip, conn = conn })
        if not ok then
            cfg_log_error('handler error on %s %s: %s', req.method, req.path, tostring(resp))
            resp = http_json(500, { ok = false, error = { code = 'internal', message = '内部错误' } })
        end
        if not st.dead then
            codec.send_response(conn, req, resp, resp_opts)
            if not req.keep_alive then
                st.dead = true
                conn:close_after_flush('done')
            end
        end
        st.busy = false
        st.last = util_now_ms()
        pump(conn, st)
    end)
    local resumed, e = coroutine.resume(co)
    if not resumed then
        cfg_log_error('request coroutine crashed: %s', tostring(e))
        st.busy = false
    end
end

pump = function(conn, st)
    while not st.busy and not st.dead and #st.buf > 0 do
        local req, next_pos, err = codec.parse_request(st.buf, 1, parse_opts)
        if not req then
            if err == 'incomplete' then return end
            codec.send_error(conn, 400, err, resp_opts)
            st.dead = true
            conn:close_after_flush('bad request')
            return
        end
        st.buf = st.buf:sub(next_pos)
        dispatch_request(conn, st, req)
    end
end

local handler = {}

function handler.on_connect(conn, ip)
    conn:set_framing({ type = 'raw', max_packet = MAX_REQUEST * 2 })
    conns[conn] = { buf = '', ip = ip or '?', busy = false, dead = false,
                    last = util_now_ms() }
end

function handler.on_packet(conn, data)
    local st = conns[conn]
    if not st or st.dead then return #data end
    st.last = util_now_ms()
    st.buf = st.buf .. data
    if #st.buf > MAX_REQUEST then
        codec.send_error(conn, 413, 'request too large', resp_opts)
        st.dead = true
        conn:close_after_flush('request too large')
        return #data
    end
    pump(conn, st)
    return #data
end

function handler.on_close(conn)
    local st = conns[conn]
    if st then st.dead = true end
    conns[conn] = nil
end

-- Close connections that have said nothing for IDLE_MS: sockets opened and
-- abandoned, and browsers' idle keep-alives. One sweep timer on the main state
-- rather than a timer per connection, because the natural place to re-arm a
-- per-connection timer is after a response, and that runs on the request's
-- coroutine, where xtimer must not be armed (engine/sched.lua).
local function sweep()
    local now = util_now_ms()
    local idle = {}
    for conn, st in pairs(conns) do
        if not st.busy and not st.dead and now - st.last > IDLE_MS then idle[#idle + 1] = conn end
    end
    for _, conn in ipairs(idle) do
        conns[conn].dead = true
        conn:close('idle')
    end
end

local function is_loopback(host)
    return host == '127.0.0.1' or host == 'localhost' or host == '::1'
end

-- MAIN STATE ONLY. Returns true, or nil plus a message.
function g_exports.http_listen()
    local host = cfg_get('LISTEN_HOST', '127.0.0.1')
    local port = cfg_int('LISTEN_PORT', 8688)
    if not is_loopback(host) and cfg_get('API_TOKEN', '') == '' then
        return nil, string.format('LISTEN_HOST=%s is not loopback: set API_TOKEN first, ' ..
            'or anyone who can reach the port can read and change the watchlist', host)
    end

    local s, err = xnet.listen_fd(host, port, {
        on_accept = function(_, fd, ip, cport)
            local conn, aerr = xnet.attach(fd, handler, ip, cport)
            if not conn then
                cfg_log_warn('attach failed from %s: %s', tostring(ip), tostring(aerr))
                return false
            end
            return true
        end,
        on_close = function(_, reason)
            cfg_log_warn('listener closed: %s', tostring(reason))
        end,
    })
    if not s then
        return nil, string.format('listen on %s:%d failed: %s', host, port, tostring(err))
    end
    server = s
    sweep_timer = xtimer.add(10000, sweep, -1)
    cfg_log_system('listening on http://%s:%d', host, port)
    return true
end

function g_exports.http_close()
    if sweep_timer then sweep_timer:del(); sweep_timer = nil end
    if server then server:close('shutdown'); server = nil end
end
