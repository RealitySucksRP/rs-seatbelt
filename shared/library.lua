local P = require 'shared.profile'
local L = {}
L.limit = 32
function L.empty() return {version=1, props={}, animations={}} end
local function validItem(kind, item)
    if kind == 'props' then return P.validModel(item) and item or nil end
    if kind == 'animations' then return P.validAnimation(item) end
end
local function key(kind, item)
    return kind == 'props' and item or item.dict .. ':' .. item.clip
end
function L.validate(raw)
    if type(raw) ~= 'table' or raw.version ~= 1 then return end
    local out = L.empty()
    for _, kind in ipairs({'props','animations'}) do
        if type(raw[kind]) ~= 'table' then return end
        local count, seen = 0, {}
        for index in pairs(raw[kind]) do
            if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > L.limit then return end
            count = count + 1
        end
        for index = 1, count do
            local item = validItem(kind, raw[kind][index])
            if not item or seen[key(kind, item)] then return end
            seen[key(kind, item)] = true
            out[kind][index] = item
        end
    end
    return out
end
function L.allowed(kind, item, config)
    local list = kind == 'props' and config.allowedModels or config.allowedDictionaries
    local value = kind == 'props' and item or item.dict
    if #list == 0 then return true end
    for _, name in ipairs(list) do if value == name then return true end end
    return false
end
function L.change(current, kind, item, remove)
    if kind ~= 'props' and kind ~= 'animations' then return nil, 'Invalid library type.' end
    local clean = validItem(kind, item)
    if not clean then return nil, 'Invalid saved asset.' end
    local out = L.validate(current)
    if not out then return nil, 'Saved library is invalid.' end
    local id = key(kind, clean)
    for index, existing in ipairs(out[kind]) do
        if key(kind, existing) == id then
            if remove then table.remove(out[kind], index) else out[kind][index] = clean end
            return out
        end
    end
    if remove then return nil, 'Saved asset was not found.' end
    if #out[kind] >= L.limit then return nil, 'Library is full (32 entries per type). Remove an entry first.' end
    out[kind][#out[kind]+1] = clean
    return out
end
return L
