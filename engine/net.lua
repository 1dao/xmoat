-- engine/net.lua — outbound HTTP for data sources, as a call that yields.
--
-- Exports: net_get, net_get_json, __net_set_transport
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

-- Returns resp {status, headers, body}, or nil plus a message. A non-2xx status
-- is an error here: no data source answers a useful body with one.
function g_exports.net_get(url, opts)
    opts = opts or {}
    local headers = util_copy(opts.headers)
    headers['User-Agent'] = headers['User-Agent'] or USER_AGENT
    headers['Accept'] = headers['Accept'] or 'application/json, text/plain, */*'
    local proxy = cfg_get('HTTP_PROXY', '')
    local call = { method = opts.method, headers = headers, body = opts.body,
                   timeout_ms = opts.timeout_ms or cfg_int('NET_TIMEOUT_MS', 15000),
                   proxy = proxy ~= '' and proxy or nil }

    -- One retry, for transport failures only. A data source that answers 4xx
    -- will answer it again, and hammering it is how an address gets blocked.
    local attempts = (opts.retries or 1) + 1
    local last_err
    for attempt = 1, attempts do
        local t0 = util_now_ms()
        local resp, err = fetch_once(url, call)
        cfg_log_info('GET %s -> %s in %dms', url:match('^https?://([^?]*)') or url,
            resp and (resp.status .. ', ' .. #(resp.body or '') .. ' bytes') or tostring(err),
            util_now_ms() - t0)
        if resp then
            if resp.status < 200 or resp.status >= 300 then
                return nil, 'HTTP ' .. tostring(resp.status)
            end
            return resp
        end
        last_err = err
        if attempt < attempts then sched_sleep(500 * attempt) end
    end
    return nil, last_err
end

function g_exports.net_get_json(url, opts)
    local resp, err = net_get(url, opts)
    if not resp then return nil, err end
    local doc, derr = util_json_decode(resp.body)
    if doc == nil then return nil, 'bad JSON: ' .. tostring(derr) end
    return doc
end

function g_exports.__net_set_transport(fn)
    transport = fn
end
