-- host/web.lua — the browser client's static files.
--
-- Exports: web_install, __web_serve
--
-- The web page is a pure client of /api/v1: it renders the analysis object and
-- computes no number of its own, so a phone app can replace it without the
-- engine noticing. Nothing here is templated except the asset digest.
--
-- Routes are registered one file at a time rather than mapping URL paths onto
-- the filesystem, which makes traversal impossible by construction — gitloom's
-- web.lua, whose digest scheme this also keeps: /app.js?v=<sha256 prefix> is
-- cached for a year, index.html never, so an edit takes effect on the next
-- page load without a build step.

local xutils = require('xutils')

local INDEX = 'index.html'

local FILES = {
    { route = '/',          name = INDEX,       type = 'text/html; charset=utf-8' },
    { route = '/app.css',   name = 'app.css',   type = 'text/css; charset=utf-8' },
    { route = '/app.js',    name = 'app.js',    type = 'application/javascript; charset=utf-8' },
    { route = '/chart.js',  name = 'chart.js',  type = 'application/javascript; charset=utf-8' },
    { route = '/favicon.svg', name = 'favicon.svg', type = 'image/svg+xml' },
}

local SECURITY = {
    ['X-Content-Type-Options'] = 'nosniff',
    ['Referrer-Policy'] = 'no-referrer',
    ['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; " ..
        "img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
}

local function headers_with(extra)
    local h = {}
    for k, v in pairs(SECURITY) do h[k] = v end
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

local function asset_version(root)
    local parts = {}
    for _, file in ipairs(FILES) do
        if file.name ~= INDEX then
            parts[#parts + 1] = util_file_read(util_path_join(root, file.name)) or ''
        end
    end
    return xutils.sha256_hex(table.concat(parts, '\0')):sub(1, 12)
end

local function unavailable()
    return { status = 503, body = 'web assets are not installed\n',
             headers = { ['Content-Type'] = 'text/plain; charset=utf-8' } }
end

local function serve(root, file, query)
    local path = util_path_join(root, file.name)
    if file.name == INDEX then
        local html = util_file_read(path)
        if not html then return unavailable() end
        return {
            status = 200,
            body = (html:gsub('__ASSET_VERSION__', asset_version(root))),
            headers = headers_with({ ['Content-Type'] = file.type, ['Cache-Control'] = 'no-cache' }),
        }
    end
    if not util_file_exists(path) then return unavailable() end
    local stamped = tostring((query or {}).v or '') == asset_version(root)
    return {
        status = 200,
        file = path,
        content_type = file.type,
        headers = headers_with({
            ['Content-Type'] = file.type,
            ['Cache-Control'] = stamped and 'public, max-age=31536000, immutable' or 'no-cache',
        }),
    }
end

function g_exports.web_install()
    local root = cfg_get('WEB_ROOT', 'web')
    local missing = {}
    for _, file in ipairs(FILES) do
        if not util_file_exists(util_path_join(root, file.name)) then missing[#missing + 1] = file.name end
        http_route('GET', file.route, function(req) return serve(root, file, req.query) end)
    end
    if #missing > 0 then
        cfg_log_warn('web client: %s missing under %s', table.concat(missing, ', '), root)
    end
end

function g_exports.__web_serve(root, route, query)
    for _, file in ipairs(FILES) do
        if file.route == route then return serve(root, file, query) end
    end
    return nil
end
