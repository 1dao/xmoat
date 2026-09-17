-- engine/notify.lua — push channels: WeCom, Feishu, DingTalk, Telegram, a webhook.
--
-- Exports: notify_channels, notify_build, notify_judge, notify_send,
--          notify_truncate, notify_urlencode, __notify_set_channels
--
-- Channels are configured, not registered: a channel exists when its keys are
-- set in xmoat.local.cfg. Nothing here stores a secret or returns one — the
-- channel list a client sees has kinds and names only.
--
-- Building a request (notify_build) and judging an answer (notify_judge) are
-- pure and take the clock as an argument, so the signatures can be checked
-- against fixed vectors in test/unit.lua. Only notify_send touches the network.
--
-- Each service says "no" differently, and three of them say it with HTTP 200:
--   WeCom      {"errcode": 0, "errmsg": "ok"}
--   DingTalk   {"errcode": 0, "errmsg": "ok"}
--   Feishu     {"code": 0} (older bots: {"StatusCode": 0})
--   Telegram   {"ok": true} — and HTTP 400 with {"ok": false, "description"}
--   webhook    any 2xx

local xutils = require('xutils')

-- Size limits, in bytes, a little under each service's documented maximum so
-- a multi-byte character cut at the edge still fits.
local LIMITS = { wecom = 4000, dingtalk = 18000, feishu = 18000, telegram = 3800, webhook = 60000 }

-- Tests set channels directly: config is read-only once the runtime starts.
local override = nil

function g_exports.__notify_set_channels(list)
    override = list
end

local function cfg_str(key)
    local v = cfg_get(key, '')
    return v ~= '' and v or nil
end

-- Configured channels, each { kind, name, conf }. `conf` holds the secrets and
-- must not leave the engine: the notify.channels command copies kind and name
-- only.
function g_exports.notify_channels()
    if override then return override end
    local out = {}
    local url = cfg_str('WECOM_WEBHOOK_URL')
    if url then out[#out + 1] = { kind = 'wecom', name = '企业微信', conf = { url = url } } end
    url = cfg_str('FEISHU_WEBHOOK_URL')
    if url then
        out[#out + 1] = { kind = 'feishu', name = '飞书', conf = { url = url, secret = cfg_str('FEISHU_SECRET') } }
    end
    url = cfg_str('DINGTALK_WEBHOOK_URL')
    if url then
        out[#out + 1] = { kind = 'dingtalk', name = '钉钉', conf = { url = url, secret = cfg_str('DINGTALK_SECRET') } }
    end
    local token, chat = cfg_str('TELEGRAM_BOT_TOKEN'), cfg_str('TELEGRAM_CHAT_ID')
    if token and chat then
        out[#out + 1] = { kind = 'telegram', name = 'Telegram', conf = {
            token = token, chat_id = chat,
            api = cfg_get('TELEGRAM_API_BASE', 'https://api.telegram.org'),
            proxy = cfg_str('TELEGRAM_PROXY'),
        } }
    end
    url = cfg_str('WEBHOOK_URL')
    if url then
        out[#out + 1] = { kind = 'webhook', name = 'Webhook', conf = { url = url, bearer = cfg_str('WEBHOOK_BEARER') } }
    end
    return out
end

-- Cut `s` to at most `max` bytes without splitting a UTF-8 character, marking
-- the cut. A byte-count cut through a Chinese character is invalid UTF-8, and
-- several of these services reject the whole message for it.
function g_exports.notify_truncate(s, max)
    s = tostring(s or '')
    if #s <= max then return s end
    local mark = '\n…（内容过长，已截断）'
    local cut = max - #mark
    -- Step back over continuation bytes (10xxxxxx) to a character boundary.
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. mark
end

function g_exports.notify_urlencode(s)
    return (tostring(s):gsub('[^%w%-%._~]', function(c)
        return string.format('%%%02X', c:byte())
    end))
end

-- msg: { title, markdown, text, events }. now_s: epoch seconds.
-- Returns { url, body (a table to send as JSON), headers, proxy }.
function g_exports.notify_build(kind, conf, msg, now_s)
    local limit = LIMITS[kind] or 4000
    if kind == 'wecom' then
        return { url = conf.url, body = {
            msgtype = 'markdown',
            markdown = { content = notify_truncate(msg.markdown, limit) },
        } }
    elseif kind == 'dingtalk' then
        local url = conf.url
        if conf.secret then
            -- Sign "timestamp_ms\nsecret" with the secret; the signature goes
            -- in the query, URL-encoded.
            local ts = string.format('%d', math.floor(now_s * 1000))
            local sign = xutils.base64_encode(xutils.hmac_sha256(conf.secret, ts .. '\n' .. conf.secret))
            url = url .. (url:find('?', 1, true) and '&' or '?') ..
                'timestamp=' .. ts .. '&sign=' .. notify_urlencode(sign)
        end
        return { url = url, body = {
            msgtype = 'markdown',
            markdown = { title = msg.title, text = notify_truncate(msg.markdown, limit) },
        } }
    elseif kind == 'feishu' then
        local body = { msg_type = 'text', content = { text = notify_truncate(msg.text, limit) } }
        if conf.secret then
            -- Feishu's scheme differs from DingTalk's: "timestamp\nsecret" is
            -- the HMAC KEY, the message is empty, and it all goes in the body.
            local ts = string.format('%d', math.floor(now_s))
            body.timestamp = ts
            body.sign = xutils.base64_encode(xutils.hmac_sha256(ts .. '\n' .. conf.secret, ''))
        end
        return { url = conf.url, body = body }
    elseif kind == 'telegram' then
        -- Plain text, no parse_mode: Telegram's Markdown rejects a message
        -- over one unescaped underscore, and company names are not ours to
        -- escape correctly.
        return { url = conf.api .. '/bot' .. conf.token .. '/sendMessage', proxy = conf.proxy, body = {
            chat_id = conf.chat_id, text = notify_truncate(msg.text, limit),
            disable_web_page_preview = true,
        } }
    elseif kind == 'webhook' then
        return { url = conf.url,
                 headers = conf.bearer and { Authorization = 'Bearer ' .. conf.bearer } or nil,
                 body = { source = 'xmoat', title = msg.title,
                          text = notify_truncate(msg.text, limit),
                          markdown = notify_truncate(msg.markdown, limit),
                          events = util_json_array(msg.events or {}) } }
    end
    error('notify_build: unknown channel kind ' .. tostring(kind))
end

-- resp: {status, body}; doc: its decoded JSON or nil. Returns true, or false
-- plus the service's own reason.
function g_exports.notify_judge(kind, resp, doc)
    local status = resp and resp.status or 0
    local d = type(doc) == 'table' and doc or {}
    if kind == 'telegram' then
        if d.ok == true then return true end
        return false, tostring(d.description or ('HTTP ' .. status))
    end
    if status < 200 or status >= 300 then
        return false, 'HTTP ' .. status .. (d.errmsg and (' ' .. tostring(d.errmsg)) or d.msg and (' ' .. tostring(d.msg)) or '')
    end
    if kind == 'wecom' or kind == 'dingtalk' then
        if d.errcode == 0 then return true end
        return false, string.format('errcode %s: %s', tostring(d.errcode), tostring(d.errmsg))
    elseif kind == 'feishu' then
        if d.code == 0 or d.StatusCode == 0 then return true end
        return false, string.format('code %s: %s', tostring(d.code), tostring(d.msg))
    end
    return true
end

-- COROUTINE-ONLY. Send one message to every configured channel, one after
-- another. Returns a list of { kind, name, ok, error }.
function g_exports.notify_send(msg)
    local results = {}
    for _, ch in ipairs(notify_channels()) do
        local req = notify_build(ch.kind, ch.conf, msg, os.time())
        local resp, doc_or_err = net_post_json(req.url, req.body,
            { headers = req.headers, proxy = req.proxy, timeout_ms = 20000 })
        local ok, why
        if not resp then
            ok, why = false, tostring(doc_or_err)
        else
            ok, why = notify_judge(ch.kind, resp, doc_or_err)
        end
        if not ok then cfg_log_warn('push to %s failed: %s', ch.name, tostring(why)) end
        results[#results + 1] = { kind = ch.kind, name = ch.name, ok = ok, error = why }
    end
    return results
end
