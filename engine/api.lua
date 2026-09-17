-- engine/api.lua — the command registry: the one door into the engine.
--
-- Exports: api_define, api_call, api_list, api_status_of
--
-- Every capability a client may use is a named command with declared
-- parameters. A host adapts transport to it and nothing else:
--
--   host/http.lua   maps a METHOD + path to a command, merging path, query and
--                   JSON body into one params table
--   cli.lua         calls commands directly
--   a phone app     can call api_call through a native bridge with no socket at
--                   all, or run the HTTP host on 127.0.0.1 behind a WebView
--
-- So there is no HTTP in the engine, and no business logic in a host. A
-- command's result is the same Lua value whichever host asked.
--
-- RESULT ENVELOPE, identical over every transport:
--   { ok = true,  data = <value> }
--   { ok = false, error = { code = '<code>', message = '<text for a person>' } }
-- Error codes are a closed set (ERROR_STATUS below); clients switch on `code`
-- and show `message`.

local commands, order = {}, {}

local ERROR_STATUS = {
    bad_request = 400,    -- the caller sent something invalid
    not_found   = 404,    -- no such command, stock or watchlist entry
    not_fetched = 404,    -- the stock exists but has never been refreshed
    conflict    = 409,    -- already exists
    upstream    = 502,    -- a data source failed or answered nonsense
    internal    = 500,    -- a bug, or the disk
}

function g_exports.api_status_of(code)
    return ERROR_STATUS[code] or 500
end

-- spec = {
--   name   = 'watchlist.add',
--   method = 'POST', path = '/api/v1/watchlist',     -- for HTTP hosts
--   summary = 'one line',
--   params = { code = { type = 'string', required = true, doc = '...' }, ... },
--   handler = function(params, ctx) return data | nil, code, message end,
-- }
-- param types: string, number, integer, boolean, object, any. `enum` lists
-- allowed values; `nullable` accepts JSON null (passed through as util_null so
-- a handler can tell "clear this" from "not given").
function g_exports.api_define(spec)
    assert(type(spec.name) == 'string' and spec.name:match('^[a-z_]+%.[a-z_]+$'),
        'api_define: name must be group.action')
    assert(not commands[spec.name], 'api_define: duplicate command ' .. spec.name)
    assert(type(spec.handler) == 'function', 'api_define: handler required')
    spec.params = spec.params or {}
    commands[spec.name] = spec
    order[#order + 1] = spec.name
end

-- Commands in definition order, without handlers: what a host needs to build
-- routes, and what system.commands returns to a client.
function g_exports.api_list()
    local out = {}
    for _, name in ipairs(order) do
        local c = commands[name]
        local params = {}
        for pname, p in pairs(c.params) do
            params[#params + 1] = { name = pname, type = p.type, required = p.required or false,
                                    nullable = p.nullable or false, enum = p.enum, doc = p.doc }
        end
        table.sort(params, function(a, b) return a.name < b.name end)
        out[#out + 1] = { name = name, method = c.method, path = c.path,
                          summary = c.summary, params = util_json_array(params) }
    end
    return out
end

-- Coerce and check one value. Query strings arrive as strings, so a number or
-- boolean given as text is accepted; anything else is refused, never guessed.
local function coerce(p, v)
    if v == util_null then
        if p.nullable then return util_null end
        return nil, '不能为 null'
    end
    local t = p.type or 'any'
    if t == 'string' then
        if type(v) == 'number' then v = tostring(v) end
        if type(v) ~= 'string' then return nil, '应为字符串' end
    elseif t == 'number' or t == 'integer' then
        if type(v) == 'string' then v = tonumber(v) end
        if not util_num(v) then return nil, '应为数字' end
        if t == 'integer' and math.floor(v) ~= v then return nil, '应为整数' end
        if t == 'integer' then v = math.floor(v) end
    elseif t == 'boolean' then
        if v == 'true' or v == '1' then v = true elseif v == 'false' or v == '0' then v = false end
        if type(v) ~= 'boolean' then return nil, '应为 true 或 false' end
    elseif t == 'object' then
        if type(v) ~= 'table' then return nil, '应为对象' end
    end
    if p.enum then
        local okv = false
        for _, e in ipairs(p.enum) do if e == v then okv = true; break end end
        if not okv then return nil, '只能是 ' .. table.concat(p.enum, '、') end
    end
    return v
end

local function fail(code, message)
    return { ok = false, error = { code = code, message = tostring(message or code) } }
end

-- COROUTINE-ONLY (a handler may fetch). Never raises.
--   ctx: host-supplied facts about the caller, e.g. { host = 'http', ip = ... }
function g_exports.api_call(name, raw, ctx)
    local c = commands[name]
    if not c then return fail('not_found', '没有这个命令：' .. tostring(name)) end
    raw = type(raw) == 'table' and raw or {}

    local params = {}
    for pname, p in pairs(c.params) do
        local v = raw[pname]
        if v == nil or v == '' then
            if p.required then return fail('bad_request', '缺少参数 ' .. pname) end
        else
            local cv, err = coerce(p, v)
            if cv == nil then return fail('bad_request', '参数 ' .. pname .. ' ' .. err) end
            params[pname] = cv
        end
    end

    local ok, data, ecode, emsg = xpcall(c.handler, function(e)
        return debug and debug.traceback(tostring(e), 2) or tostring(e)
    end, params, ctx or {})
    if not ok then
        cfg_log_error('command %s raised: %s', name, tostring(data))
        return fail('internal', '内部错误')
    end
    if data == nil then
        if not ERROR_STATUS[ecode or ''] then
            cfg_log_error('command %s returned unknown error code %s: %s', name,
                tostring(ecode), tostring(emsg))
            ecode = 'internal'
        end
        return fail(ecode, emsg)
    end
    return { ok = true, data = data }
end
