-- engine/net.lua — outbound HTTP for data sources, as a call that yields.
--
-- Exports: net_request, net_get, net_get_json, net_post_json, __net_set_transport
--
-- COROUTINE-ONLY. xhttp_client is callback-based; this parks the calling
-- coroutine until the callback fires, so a data source reads as sequential code
-- while the event loop keeps serving everyone else.
--
-- The timeout is ours, not xhttp_client's timeout_ms — see engine/sched.lua for
-- why that option crashes when used from a coroutine. On expiry the connection
-- is closed; xhttp_client then fires its callback with an error, which is
-- ignored because the waiter has already been released.

local httpc = dofile('scripts/core/share/xhttp_client.lua')

local USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' ..
                   '(KHTML, like Gecko) Chrome/126.0 Safari/537.36'

-- Tests replace the transport so a data source's parsing can be checked
-- against recorded responses without a network. Signature:
--   transport(url, opts) -> resp {status, headers, body} | nil, err
local transport = nil

local function fetch_once(url, opts)
    if transport then return transport(url, opts) end

    local state = { done = false }
    local req = httpc.request({
        url = url,
        method = opts.method or 'GET',
        headers = opts.headers,
        body = opts.body,
        proxy = opts.proxy,
    }, function(err, resp)
        if state.done then return end
        state.done, state.err, state.resp = true, err, resp
    end)

    local timeout_ms = opts.timeout_ms or 15000
    local cancel = sched_after(timeout_ms, function()
        if state.done then return end
        state.done, state.err = true, 'timeout after ' .. timeout_ms .. 'ms'
        local c = req and (req.conn or req.proxy_conn)
        if c and not c:is_closed() then c:close('timeout') end
    end)

    sched_wait_until(function() return state.done end)
    cancel()
    if state.err then return nil, tostring(state.err) end
    return state.resp
end

-- Where a request went, for the log. Only the host for anything but a GET:
-- webhook URLs carry their credential in the query (WeCom's key=) or in the
-- path (Telegram's bot token), and a log line is not a place for either.
local function log_target(method, url)
    local host, path = url:match('^https?://([^/?#]+)([^?#]*)')
    if not host then return '?' end
    if method == 'GET' then return host .. path end
    return host
end

-- One request, any status. Returns resp {status, headers, body}, or nil plus a
-- message for a transport failure. COROUTINE-ONLY.
--
-- Transport failures are retried once for GET only. A POST here is a push
-- notification, and a retry after a timeout that actually reached the server
-- sends the same message twice.
function g_exports.net_request(method, url, opts)
    opts = opts or {}
    method = method:upper()
    local headers = util_copy(opts.headers)
    headers['User-Agent'] = headers['User-Agent'] or USER_AGENT
    headers['Accept'] = headers['Accept'] or 'application/json, text/plain, */*'
    -- A per-request proxy (Telegram, from mainland China) wins over HTTP_PROXY.
    local proxy = opts.proxy or cfg_get('HTTP_PROXY', '')
    local call = { method = method, headers = headers, body = opts.body,
                   timeout_ms = opts.timeout_ms or cfg_int('NET_TIMEOUT_MS', 15000),
                   proxy = proxy ~= '' and proxy or nil }

    local attempts = method == 'GET' and (opts.retries or 1) + 1 or 1
    local last_err
    for attempt = 1, attempts do
        local t0 = util_now_ms()
        local resp, err = fetch_once(url, call)
        cfg_log_info('%s %s -> %s in %dms', method, log_target(method, url),
            resp and (resp.status .. ', ' .. #(resp.body or '') .. ' bytes') or tostring(err),
            util_now_ms() - t0)
        if resp then return resp end
        last_err = err
        if attempt < attempts then sched_sleep(500 * attempt) end
    end
    return nil, last_err
end

-- A GET whose non-2xx status is an error: no data source answers a useful
-- body with one.
function g_exports.net_get(url, opts)
    local resp, err = net_request('GET', url, opts)
    if not resp then return nil, err end
    if resp.status < 200 or resp.status >= 300 then
        return nil, 'HTTP ' .. tostring(resp.status)
    end
    return resp
end

function g_exports.net_get_json(url, opts)
    local resp, err = net_get(url, opts)
    if not resp then return nil, err end
    local doc, derr = util_json_decode(resp.body)
    if doc == nil then return nil, 'bad JSON: ' .. tostring(derr) end
    return doc
end

-- POST a JSON body. Returns resp (any status) and its decoded body when it is
-- JSON, or nil plus a message. The caller judges success: every push channel
-- has its own way of saying no, several of them with a 200.
function g_exports.net_post_json(url, value, opts)
    local body, eerr = util_json_encode(value)
    if not body then return nil, 'encode failed: ' .. tostring(eerr) end
    opts = util_copy(opts)
    local headers = util_copy(opts.headers)
    headers['Content-Type'] = 'application/json; charset=utf-8'
    opts.headers, opts.body = headers, body
    local resp, err = net_request('POST', url, opts)
    if not resp then return nil, err end
    return resp, util_json_decode(resp.body or '')
end

function g_exports.__net_set_transport(fn)
    transport = fn
end
