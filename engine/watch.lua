-- engine/watch.lua — the watchlist: which stocks, and the user's own notes on them.
--
-- Exports: watch_load, watch_list, watch_get, watch_add, watch_update, watch_remove
--
-- Held in memory, written through on every change. An entry:
--   { code, added_at, note, band = { metric, low, high } }
-- `band` is the user's own fair-value range; the engine reports where the
-- price sits against it and never sets one itself.

local doc = nil          -- { version = 1, items = { entry, ... } }

local function save()
    util_json_array(doc.items)
    return store_save('watchlist', doc)
end

local function index_of(code)
    for i, e in ipairs(doc.items) do
        if e.code == code then return i end
    end
    return nil
end

-- Returns true, or nil plus a message. A watchlist file that exists and does
-- not parse is an error rather than an empty list: starting empty would
-- overwrite it on the first change.
function g_exports.watch_load()
    local loaded, err = store_load('watchlist')
    if err then return nil, err end
    if loaded == nil then
        doc = { version = 1, items = {} }
        return true
    end
    if type(loaded) ~= 'table' or type(loaded.items) ~= 'table' then
        return nil, 'watchlist.json has no items list'
    end
    doc = loaded
    return true
end

function g_exports.watch_list()
    return doc.items
end

function g_exports.watch_get(code)
    local i = index_of(code)
    return i and doc.items[i] or nil
end

-- Validate a band patch against an existing band (or none). Returns the new
-- band (nil to clear), or false plus a message.
local function merge_band(current, patch)
    if patch == util_null then return nil end
    if type(patch) ~= 'table' then return false, 'band 必须是对象' end
    local band = util_copy(current)
    for _, k in ipairs({ 'metric', 'low', 'high' }) do
        if patch[k] ~= nil then band[k] = patch[k] end
        if band[k] == util_null then band[k] = nil end
    end
    band.metric = band.metric or 'pe_ttm'
    if not valuation_band_metrics[band.metric] then
        return false, 'band.metric 只能是 pe_ttm、pb、ps_ttm、pcf_ttm'
    end
    for _, k in ipairs({ 'low', 'high' }) do
        if band[k] ~= nil and not util_num(band[k]) then
            return false, 'band.' .. k .. ' 必须是数字'
        end
    end
    if band.low == nil and band.high == nil then return nil end
    if band.low and band.high and band.low > band.high then
        return false, 'band.low 不能大于 band.high'
    end
    return band
end

-- fields: { note?, band? }. Returns the entry, or nil plus (code, message).
function g_exports.watch_add(code, fields)
    fields = fields or {}
    if index_of(code) then return nil, 'conflict', code .. ' 已在自选中' end
    local entry = { code = code, added_at = util_now_iso() }
    if type(fields.note) == 'string' then entry.note = fields.note end
    if fields.band ~= nil then
        local band, berr = merge_band(nil, fields.band)
        if band == false then return nil, 'bad_request', berr end
        entry.band = band
    end
    doc.items[#doc.items + 1] = entry
    local ok, err = save()
    if not ok then
        table.remove(doc.items)
        return nil, 'internal', tostring(err)
    end
    return entry
end

-- patch: { note?, band? }; util_null clears a field.
function g_exports.watch_update(code, patch)
    local i = index_of(code)
    if not i then return nil, 'not_found', code .. ' 不在自选中' end
    local entry = doc.items[i]
    local updated = util_copy(entry)
    if patch.note ~= nil then
        if patch.note == util_null then updated.note = nil
        elseif type(patch.note) == 'string' then updated.note = patch.note
        else return nil, 'bad_request', 'note 必须是字符串' end
    end
    if patch.band ~= nil then
        local band, berr = merge_band(entry.band, patch.band)
        if band == false then return nil, 'bad_request', berr end
        updated.band = band
    end
    doc.items[i] = updated
    local ok, err = save()
    if not ok then
        doc.items[i] = entry
        return nil, 'internal', tostring(err)
    end
    return updated
end

function g_exports.watch_remove(code)
    local i = index_of(code)
    if not i then return nil, 'not_found', code .. ' 不在自选中' end
    local entry = table.remove(doc.items, i)
    local ok, err = save()
    if not ok then
        table.insert(doc.items, i, entry)
        return nil, 'internal', tostring(err)
    end
    return true
end
