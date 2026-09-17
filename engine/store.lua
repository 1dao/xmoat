-- engine/store.lua — everything xmoat keeps, as JSON files under one directory.
--
-- Exports: store_init, store_dir, store_load, store_save, store_stock_path
--
-- Files, not a database, because the same engine has to run on a phone, where
-- there is an app sandbox directory and nothing else. One file per stock keeps
-- a write proportional to the stock being refreshed, and each is replaced
-- atomically (util_file_write_atomic), so a crash mid-refresh leaves the
-- previous copy rather than a truncated one.
--
--   <DATA_DIR>/watchlist.json
--   <DATA_DIR>/stocks/<code>.json
--
-- A MySQL backend, if a multi-user server ever needs one, goes behind these
-- same functions, as gitloom's store.lua does.

local root = nil

-- MAIN STATE or anywhere: no yield. `dir` overrides DATA_DIR.
function g_exports.store_init(dir)
    root = dir or cfg_get('DATA_DIR', 'data')
    local ok, err = util_dir_make(util_path_join(root, 'stocks'))
    if not ok then return nil, string.format('cannot create %s: %s', root, tostring(err)) end
    return true
end

function g_exports.store_dir()
    return root
end

-- Stock codes are validated before they get here (source_em_security), and
-- this checks again because the result is a filesystem path.
function g_exports.store_stock_path(code)
    if type(code) ~= 'string' or not code:match('^%d%d%d%d%d%d$') then
        error('store_stock_path: not a stock code: ' .. tostring(code), 2)
    end
    return util_path_join(root, 'stocks', code .. '.json')
end

local function path_of(name)
    assert(root, 'store_init has not run')
    if name == 'watchlist' then return util_path_join(root, 'watchlist.json') end
    local code = name:match('^stock:(%d%d%d%d%d%d)$')
    if code then return store_stock_path(code) end
    error('store: unknown document ' .. tostring(name), 3)
end

-- Returns the decoded document, nil when it does not exist, or nil plus a
-- message when it exists and cannot be read — which the caller must not treat
-- as "empty" and then overwrite.
function g_exports.store_load(name)
    local path = path_of(name)
    if not util_file_exists(path) then return nil end
    local text = util_file_read(path)
    if not text then return nil, 'cannot read ' .. path end
    local doc, err = util_json_decode(text)
    if doc == nil then return nil, string.format('%s is not valid JSON: %s', path, tostring(err)) end
    return doc
end

function g_exports.store_save(name, doc)
    local path = path_of(name)
    local text, err = util_json_encode(doc)
    if not text then return nil, 'encode failed: ' .. tostring(err) end
    return util_file_write_atomic(path, text)
end
