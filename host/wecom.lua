-- host/wecom.lua — the WeCom callback URL.
--
-- Exports: wecom_install
--
-- Transport only, like the rest of host/: the envelope belongs to
-- engine/wxcrypt.lua, which says why any of this exists. Two methods on one
-- path, because WeCom uses both — GET once, when the console saves the URL and
-- wants the echostr handed back in plain text, and POST from then on for every
-- event type the application is subscribed to.
--
-- Those events are dropped. An empty 200 is WeCom's "nothing to reply", and it
-- is the whole of the answer: xmoat pushes, it does not take instructions from
-- a chat window.
--
-- This path is NOT behind API_TOKEN — WeCom sends no Authorization header.
-- What stands in its place is the signature: a request whose Encrypt does not
-- decrypt with the application's own key, or whose receiveid is not this
-- company, is refused before anything reads it.

local DEFAULT_PATH = '/wecom/callback'

local function text(status, body)
    return { status = status, body = body,
             headers = { ['Content-Type'] = 'text/plain; charset=utf-8',
                         ['Cache-Control'] = 'no-store' } }
end

-- parse_query yields a list for a repeated key; the first one wins, as in the
-- API's own handler.
local function one(v)
    return type(v) == 'table' and v[1] or v
end

local function encrypted_of(body)
    return body:match('<Encrypt><!%[CDATA%[(.-)%]%]></Encrypt>') or
           body:match('<Encrypt>(.-)</Encrypt>')
end

-- MAIN STATE ONLY, before http_listen. `conf` is for tests; a host passes
-- nothing and the configuration is read. Returns whether the route exists.
function g_exports.wecom_install(conf)
    if conf == nil then
        local err
        conf, err = wxcrypt_config()
        if not conf then
            if err then cfg_log_warn('%s', err) end
            return false
        end
    end
    local path = cfg_get('WECOM_CALLBACK_PATH', DEFAULT_PATH)

    http_route('GET', path, function(req, ctx)
        local q = req.query or {}
        local plain, why = wxcrypt_open(conf, one(q.msg_signature), one(q.timestamp),
                                        one(q.nonce), one(q.echostr))
        if not plain then
            cfg_log_warn('WeCom callback: URL check from %s refused: %s',
                         tostring(ctx.ip), tostring(why))
            return text(403, 'forbidden\n')
        end
        -- The echostr's plaintext, exactly: no newline, nothing around it.
        cfg_log_system('WeCom callback: URL check passed')
        return text(200, plain)
    end)

    http_route('POST', path, function(req, ctx)
        local q = req.query or {}
        local encrypted = encrypted_of(req.body or '')
        local plain, why
        if encrypted then
            plain, why = wxcrypt_open(conf, one(q.msg_signature), one(q.timestamp),
                                      one(q.nonce), encrypted)
        else
            why = 'no Encrypt element'
        end
        if not plain then
            cfg_log_warn('WeCom callback: event from %s refused: %s',
                         tostring(ctx.ip), tostring(why))
            return text(403, 'forbidden\n')
        end
        cfg_log_debug('WeCom callback: %s',
                      plain:match('<MsgType><!%[CDATA%[(%w+)%]%]>') or 'event')
        return text(200, '')
    end)

    cfg_log_system('WeCom callback at %s', path)
    return true
end
