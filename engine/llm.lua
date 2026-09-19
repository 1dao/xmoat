-- engine/llm.lua — one chat call to a language model, over plain HTTP.
--
-- Exports: llm_config, llm_status, llm_build, llm_parse, llm_chat, __llm_set_config
--
-- Two wire formats, chosen by LLM_PROVIDER:
--
--   anthropic   Claude's Messages API (POST {base}/v1/messages). There is no
--               Lua SDK, so this is the documented raw-HTTP shape: x-api-key,
--               anthropic-version, and the JSON body. The default model is
--               claude-opus-5. JSON answers use output_config.format with a
--               JSON schema, which the API enforces. Requests also carry
--               `fallbacks: "default"` (beta server-side-fallback-2026-07-01):
--               if a safety classifier declines, the API re-runs the request on
--               a fallback model inside the same call instead of returning a
--               refusal. LLM_FALLBACKS=0 turns that off, and it must be off for
--               an endpoint that is not Anthropic's own API.
--
--   openai      Any OpenAI-compatible chat completions endpoint
--               (POST {base}/chat/completions): DeepSeek, Qwen, Moonshot, a local
--               Ollama. No default model — they differ too much to guess. JSON
--               answers use response_format json_object, which constrains to
--               JSON but not to a schema; engine/insight.lua checks the shape.
--
-- Non-streaming, because the answers here are a few hundred words and the
-- caller wants the whole thing: a digest to store, not text to animate.
--
-- Nothing here decides what to ask. engine/insight.lua builds the messages and
-- judges the answer; this file only speaks the protocols.

local ANTHROPIC_BASE = 'https://api.anthropic.com'
local ANTHROPIC_MODEL = 'claude-opus-5'
local ANTHROPIC_VERSION = '2023-06-01'
local FALLBACK_BETA = 'server-side-fallback-2026-07-01'

local override = nil

-- Tests set the configuration directly: config is read-only once running.
function g_exports.__llm_set_config(conf)
    override = conf
end

-- The active configuration, or nil when no provider is set up.
-- { provider, base, key, model, max_tokens, timeout_ms, proxy, effort, fallbacks }
function g_exports.llm_config()
    if override ~= nil then return override or nil end
    local provider = cfg_get('LLM_PROVIDER', ''):lower()
    local key = cfg_get('LLM_API_KEY', '')
    if provider == '' or key == '' then return nil end
    if provider ~= 'anthropic' and provider ~= 'openai' then return nil end
    local model = cfg_get('LLM_MODEL', '')
    if model == '' then
        if provider ~= 'anthropic' then return nil end
        model = ANTHROPIC_MODEL
    end
    local base = cfg_get('LLM_BASE_URL', '')
    if base == '' then base = provider == 'anthropic' and ANTHROPIC_BASE or 'https://api.openai.com/v1' end
    local effort = cfg_get('LLM_EFFORT', '')
    local proxy = cfg_get('LLM_PROXY', '')
    return {
        provider = provider, base = (base:gsub('/+$', '')), key = key, model = model,
        max_tokens = cfg_int('LLM_MAX_TOKENS', 16000),
        timeout_ms = cfg_int('LLM_TIMEOUT_MS', 180000),
        proxy = proxy ~= '' and proxy or nil,
        effort = effort ~= '' and effort or nil,
        fallbacks = provider == 'anthropic' and cfg_bool('LLM_FALLBACKS', true),
    }
end

-- What a client may see: never the key.
function g_exports.llm_status()
    local c = llm_config()
    if not c then
        return { enabled = false,
                 hint = '在 xmoat.local.cfg 里设置 LLM_PROVIDER（anthropic 或 openai）和 LLM_API_KEY' }
    end
    return { enabled = true, provider = c.provider, model = c.model }
end

-- req: { system = '...', messages = { {role, content}, ... }, schema = <JSON schema> | nil }
-- Returns { url, headers, body } for net_post_json.
function g_exports.llm_build(conf, req)
    if conf.provider == 'anthropic' then
        local body = {
            model = conf.model,
            max_tokens = conf.max_tokens,
            system = req.system,
            messages = req.messages,
        }
        local output_config = {}
        if req.schema then output_config.format = { type = 'json_schema', schema = req.schema } end
        if conf.effort then output_config.effort = conf.effort end
        if next(output_config) then body.output_config = output_config end
        local headers = {
            ['x-api-key'] = conf.key,
            ['anthropic-version'] = ANTHROPIC_VERSION,
        }
        if conf.fallbacks then
            body.fallbacks = 'default'
            headers['anthropic-beta'] = FALLBACK_BETA
        end
        return { url = conf.base .. '/v1/messages', headers = headers, body = body }
    end

    local messages = { { role = 'system', content = req.system } }
    for _, m in ipairs(req.messages) do messages[#messages + 1] = m end
    local body = { model = conf.model, max_tokens = conf.max_tokens, messages = messages }
    if req.schema then body.response_format = { type = 'json_object' } end
    return { url = conf.base .. '/chat/completions',
             headers = { Authorization = 'Bearer ' .. conf.key }, body = body }
end

-- resp: {status, body}; doc: decoded JSON or nil. Returns
--   { text, model, usage = { input_tokens, output_tokens } }
-- or nil plus a message a person can act on.
function g_exports.llm_parse(conf, resp, doc)
    local status = resp and resp.status or 0
    local d = type(doc) == 'table' and doc or nil
    if status < 200 or status >= 300 or not d then
        local detail = d and type(d.error) == 'table' and d.error.message or nil
        if not detail and resp and resp.body then detail = tostring(resp.body):sub(1, 200) end
        return nil, string.format('HTTP %d%s', status, detail and ('：' .. tostring(detail)) or '')
    end

    if conf.provider == 'anthropic' then
        -- The answer is the text blocks. Thinking blocks (empty text by
        -- default on current models) and fallback markers are not.
        if d.stop_reason == 'refusal' then
            return nil, '模型拒绝回答这个请求（refusal）'
        end
        local parts = {}
        for _, block in ipairs(type(d.content) == 'table' and d.content or {}) do
            if type(block) == 'table' and block.type == 'text' and type(block.text) == 'string' then
                parts[#parts + 1] = block.text
            end
        end
        if d.stop_reason == 'max_tokens' then
            return nil, '回答超过 LLM_MAX_TOKENS 被截断，调大后重试'
        end
        if #parts == 0 then return nil, '模型没有返回文本' end
        local u = type(d.usage) == 'table' and d.usage or {}
        return { text = table.concat(parts), model = d.model,
                 usage = { input_tokens = util_num(u.input_tokens), output_tokens = util_num(u.output_tokens) } }
    end

    local choice = type(d.choices) == 'table' and d.choices[1]
    local message = type(choice) == 'table' and choice.message
    local text = type(message) == 'table' and message.content
    if type(text) ~= 'string' or text == '' then return nil, '模型没有返回文本' end
    if choice.finish_reason == 'length' then
        return nil, '回答超过 LLM_MAX_TOKENS 被截断，调大后重试'
    end
    local u = type(d.usage) == 'table' and d.usage or {}
    return { text = text, model = d.model,
             usage = { input_tokens = util_num(u.prompt_tokens), output_tokens = util_num(u.completion_tokens) } }
end

-- COROUTINE-ONLY. One request. Returns the parsed answer, or nil plus
-- (error code, message) with codes from engine/api.lua.
function g_exports.llm_chat(req)
    local conf = llm_config()
    if not conf then return nil, 'unavailable', llm_status().hint end
    local call = llm_build(conf, req)
    local resp, doc_or_err = net_post_json(call.url, call.body,
        { headers = call.headers, timeout_ms = conf.timeout_ms, proxy = conf.proxy })
    if not resp then return nil, 'upstream', '大模型请求失败：' .. tostring(doc_or_err) end
    local out, err = llm_parse(conf, resp, doc_or_err)
    if not out then return nil, 'upstream', '大模型：' .. tostring(err) end
    out.provider = conf.provider
    out.model = out.model or conf.model
    return out
end
