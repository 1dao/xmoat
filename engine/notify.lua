-- engine/notify.lua — push channels: WeCom (group bot and app), Feishu,
-- DingTalk, Telegram, a webhook.
--
-- Exports: notify_channels, notify_build, notify_judge, notify_send,
--          notify_truncate, notify_urlencode, notify_wecom_token,
--          __notify_set_channels, __notify_clear_tokens
--
-- Channels are configured, not registered: a channel exists when its keys are
-- set in xmoat.local.cfg. Nothing here stores a secret or returns one — the
-- channel list a client sees has kinds and names only.
--
-- Building a request (notify_build) and judging an answer (notify_judge) are
-- pure and take the clock as an argument, so the signatures can be checked
-- against fixed vectors in test/unit.lua. Only notify_send and
-- notify_wecom_token touch the network.
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
local LIMITS = { wecom = 4000, wecom_app = 2000, dingtalk = 18000, feishu = 18000,
                 telegram = 3800, webhook = 60000 }

local WECOM_API = 'https://qyapi.weixin.qq.com'

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
    if url then out[#out + 1] = { kind = 'wecom', name = '企业微信群机器人', conf = { url = url } } end
    -- The app channel is a different thing from the group bot: it posts to a
    -- member's own conversation with the application, so it needs the company
    -- (corp id), the application (agent id) and a secret to get a token with.
    local corp, secret = cfg_str('WECOM_CORP_ID'), cfg_str('WECOM_CORP_SECRET')
    local agent = tonumber(cfg_str('WECOM_AGENT_ID') or '')
    if corp and secret and agent then
        out[#out + 1] = { kind = 'wecom_app', name = '企业微信应用', conf = {
            api = WECOM_API, corp_id = corp, secret = secret, agent_id = agent,
            touser = cfg_get('WECOM_TO_USER', '@all'),
        } }
    elseif corp or secret then
        cfg_log_warn('WeCom app: WECOM_CORP_ID, WECOM_CORP_SECRET and a numeric WECOM_AGENT_ID are all required')
    end
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

-- Cached WeCom app tokens, keyed by company and secret. A token lasts two
-- hours and fetching a new one can invalidate the last, so it is kept rather
-- than fetched per message. Process-local on purpose: it is a credential, and
-- a host that restarts can afford one more fetch.
local tokens = {}

function g_exports.__notify_clear_tokens()
    tokens = {}
end

-- COROUTINE-ONLY. The token for a WeCom app channel, from the cache unless
-- `force`. Returns the token, or nil plus a reason.
function g_exports.notify_wecom_token(conf, force)
    local key = tostring(conf.corp_id) .. '\n' .. tostring(conf.secret)
    local now, cached = os.time(), tokens[key]
    if not force and cached and cached.expires_at > now then return cached.token end
    local url = conf.api .. '/cgi-bin/gettoken?corpid=' .. notify_urlencode(conf.corp_id) ..
                '&corpsecret=' .. notify_urlencode(conf.secret)
    local doc, err = net_get_json(url, { timeout_ms = 20000 })
    if not doc then return nil, 'gettoken: ' .. tostring(err) end
    if doc.errcode ~= 0 or type(doc.access_token) ~= 'string' then
        return nil, string.format('gettoken errcode %s: %s', tostring(doc.errcode), tostring(doc.errmsg))
    end
    -- A minute of margin: expires_in counts from when the server answered, and
    -- the send it is used for still has to get there.
    local ttl = tonumber(doc.expires_in) or 7200
    tokens[key] = { token = doc.access_token, expires_at = now + math.max(60, ttl - 60) }
    return doc.access_token
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
    elseif kind == 'wecom_app' then
        -- Not a webhook: the token goes in the query, and the message names
        -- both the application it comes from and who is to receive it.
        --
        -- Text, not Markdown: an app's Markdown message renders in the WeCom
        -- client only, and the same message read through the WeChat plugin —
        -- which is how a one-person company usually reads it — shows nothing.
        return { url = conf.api .. '/cgi-bin/message/send?access_token=' ..
                       notify_urlencode(conf.access_token),
                 body = {
                     touser = conf.touser or '@all',
                     msgtype = 'text',
                     agentid = conf.agent_id,
                     text = { content = notify_truncate(msg.text, limit) },
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
    if kind == 'wecom' or kind == 'wecom_app' or kind == 'dingtalk' then
        if d.errcode == 0 then return true end
        return false, string.format('errcode %s: %s', tostring(d.errcode), tostring(d.errmsg))
    elseif kind == 'feishu' then
        if d.code == 0 or d.StatusCode == 0 then return true end
        return false, string.format('code %s: %s', tostring(d.code), tostring(d.msg))
    end
    return true
end

-- A token WeCom will not take any more: it expired early, or something else
-- holding the same secret fetched one and invalidated ours.
local TOKEN_ERRCODES = { [40014] = true, [41001] = true, [42001] = true }

-- COROUTINE-ONLY. One attempt at one channel. Returns ok, reason, the decoded
-- answer.
local function send_once(kind, conf, msg)
    local req = notify_build(kind, conf, msg, os.time())
    local resp, doc_or_err = net_post_json(req.url, req.body,
        { headers = req.headers, proxy = req.proxy, timeout_ms = 20000 })
    if not resp then return false, tostring(doc_or_err) end
    local ok, why = notify_judge(kind, resp, doc_or_err)
    return ok, why, doc_or_err
end

-- COROUTINE-ONLY. The app channel sends with a token, so it takes two requests
-- and may need a third: a refused token is replaced and the message sent again
-- rather than reported as a failed push.
local function send_wecom_app(ch, msg)
    local token, err = notify_wecom_token(ch.conf)
    if not token then return false, err end
    local conf = util_copy(ch.conf)
    conf.access_token = token
    local ok, why, doc = send_once(ch.kind, conf, msg)
    if not ok and type(doc) == 'table' and TOKEN_ERRCODES[doc.errcode] then
        token, err = notify_wecom_token(ch.conf, true)
        if not token then return false, err end
        conf.access_token = token
        ok, why, doc = send_once(ch.kind, conf, msg)
    end
    -- Delivered, but not to everyone named: WeCom answers errcode 0 and lists
    -- the recipients it does not know.
    if ok and type(doc) == 'table' and doc.invaliduser and doc.invaliduser ~= '' then
        cfg_log_warn('WeCom app: no such member %s', tostring(doc.invaliduser))
    end
    return ok, why
end

-- COROUTINE-ONLY. Send one message to every configured channel, one after
-- another. Returns a list of { kind, name, ok, error }.
function g_exports.notify_send(msg)
    local results = {}
    for _, ch in ipairs(notify_channels()) do
        local ok, why
        if ch.kind == 'wecom_app' then
            ok, why = send_wecom_app(ch, msg)
        else
            ok, why = send_once(ch.kind, ch.conf, msg)
        end
        if not ok then cfg_log_warn('push to %s failed: %s', ch.name, tostring(why)) end
        results[#results + 1] = { kind = ch.kind, name = ch.name, ok = ok, error = why }
    end
    return results
end
