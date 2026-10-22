local C = require 'config.server'
local S = {}
local resource = GetCurrentResourceName()
local path = 'data/profiles.json'
local data
local function query(sql, params)
    local p = promise.new()
    exports.oxmysql:query(sql, params or {}, function(result, err)
        if err or result == nil then p:reject(err or 'SQL query failed') else p:resolve(result) end
    end, resource, true)
    return Citizen.Await(p)
end
function S.init()
    assert(C.storage == 'json' or C.storage == 'sql', 'Invalid rs-seatbelt storage setting')
    if C.storage == 'sql' then
        assert(GetResourceState('oxmysql') == 'started', 'SQL mode requires oxmysql')
        query('SELECT owner_id FROM rs_seatbelt_profiles LIMIT 1')
        return
    end
    local raw = LoadResourceFile(resource, path)
    if not raw then data = {version=1, profiles={}} return end
    local ok, decoded = pcall(json.decode, raw)
    assert(ok and type(decoded) == 'table' and decoded.version == 1 and type(decoded.profiles) == 'table',
        'Invalid profiles.json; restore the backup before saving. Refusing to overwrite.')
    data = decoded
end
function S.get(id)
    if C.storage == 'json' then return data.profiles[id] end
    local rows = query('SELECT profile FROM rs_seatbelt_profiles WHERE owner_id = ?', {id})
    if not rows[1] then return end
    return json.decode(rows[1].profile)
end
function S.put(id, value)
    if C.storage == 'sql' then
        if value then query('INSERT INTO rs_seatbelt_profiles (owner_id, profile) VALUES (?, ?) ON DUPLICATE KEY UPDATE profile = VALUES(profile)', {id, json.encode(value)})
        else query('DELETE FROM rs_seatbelt_profiles WHERE owner_id = ?', {id}) end
        return true
    end
    -- No yield between snapshot/write/commit: concurrent player saves cannot lose each other.
    local old = data.profiles[id]
    data.profiles[id] = value
    local encoded = json.encode(data)
    local previous = LoadResourceFile(resource, path)
    if previous and not SaveResourceFile(resource, path .. '.bak', previous, -1) then
        data.profiles[id] = old
        return false
    end
    if not SaveResourceFile(resource, path, encoded, -1) then data.profiles[id] = old return false end
    return true
end
return S
