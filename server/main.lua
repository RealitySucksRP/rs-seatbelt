local C = require 'config.server'
local Profile = require 'shared.profile'
local Library = require 'shared.library'
local Bridge = require 'server.bridge'
local Storage = require 'server.storage'
local ready, failure = false, nil
local serverProfile = Profile.defaults()
local sessions, lastSave, lastFetch, saving, harness = {}, {}, {}, {}, {}
local publishing = false
local sharedLibrary = Library.empty()
local librarySaving, lastLibrarySave = {}, {}
local beginHarness
local callbacks = {}
local function registerRPC(name, fn) callbacks[name] = fn end
RegisterNetEvent('rs-seatbelt:server:rpc', function(id, name, ...)
    local src = source
    if type(id) ~= 'string' or #id > 64 or type(name) ~= 'string' or not callbacks[name] then return end
    local ok, result = pcall(callbacks[name], src, ...)
    if not ok then
        print('[rs-seatbelt] Request failed: ' .. tostring(result))
        result = {ok=false, message='Seatbelt service error. No save confirmed.'}
    end
    TriggerClientEvent('rs-seatbelt:client:rpc', src, id, result)
end)

SetConvarReplicated('game_enableFlyThroughWindscreen', 'true')
local function admin(src) return IsPlayerAceAllowed(src, C.adminAce) end
local function identity(src)
    local ok, id = pcall(Bridge.identity, src)
    return ok and id or nil
end
local function state(src, profile, active)
    local p = Player(src)
    if p then
        p.state:set('rsSeatbeltProfile', profile, true)
        if active ~= nil then p.state:set('rsSeatbeltVisual', active, true) end
    end
end
local function loadSession(src)
    local id = identity(src)
    if not id then return end
    local old = sessions[src]
    if old and old.id == id then return old end
    local personal = Profile.validate(Storage.get(id))
    local library = Library.validate(Storage.get('library:' .. id)) or Library.empty()
    if personal and C.personalMode == 'full' and not Profile.allowed(personal, C) then personal = nil end
    if identity(src) ~= id then return end
    local session = {id=id, personal=personal, library=library}
    sessions[src], harness[src] = session, nil
    state(src, Profile.merge(personal, serverProfile, C.personalMode), false)
    return session
end
local function reply(src, session)
    return {ok=true, profile=Profile.merge(session.personal, serverProfile, C.personalMode),
        serverProfile=serverProfile, mode=C.personalMode, admin=admin(src), identity=session.id,
        libraries={personal=session.library, server=sharedLibrary}}
end
local function errorReply(message) return {ok=false, message=message} end

CreateThread(function()
    local ok, err = pcall(function()
        assert(GetResourceState('qbx_seatbelt') ~= 'started', 'Stop qbx_seatbelt before starting rs-seatbelt')
        assert(C.personalMode == 'server' or C.personalMode == 'alignment' or C.personalMode == 'full', 'Invalid personalMode')
        Bridge.init()
        Storage.init()
        local savedLibrary = Storage.get('__library__')
        if savedLibrary then sharedLibrary = assert(Library.validate(savedLibrary), 'Invalid shared asset library') end
        local existing = Storage.get('__server__')
        if existing then serverProfile = assert(Profile.validate(existing), 'Invalid saved server profile')
        else
            local raw = LoadResourceFile(GetCurrentResourceName(), 'data/seatbelt_alignment.json')
            if raw then
                local old = json.decode(raw)
                for _, k in ipairs({'x','y','z','rx','ry','rz'}) do serverProfile[k] = old[k] end
                serverProfile = assert(Profile.validate(serverProfile), 'Invalid legacy alignment')
            end
            assert(Storage.put('__server__', serverProfile), 'Unable to persist initial server preset')
        end
        beginHarness = function(src, item)
            src = tonumber(src)
            local ped = GetPlayerPed(src)
            if not ped or ped == 0 or GetVehiclePedIsIn(ped, false) == 0 then return end
            local id = identity(src)
            if not id then return end
            local now = GetGameTimer()
            if harness[src] and now < harness[src].expires then return end
            harness[src] = {slot=item and item.slot, id=id, vehicle=GetVehiclePedIsIn(ped, false),
                ready=now + 4500, expires=now + 30000}
            TriggerClientEvent('rs-seatbelt:client:UseHarness', src)
        end
        Bridge.registerHarness(beginHarness)
        for _, s in ipairs(GetPlayers()) do state(tonumber(s), nil, false) end
    end)
    ready, failure = ok, not ok and tostring(err) or nil
    if not ok then print('[rs-seatbelt] Startup refused: ' .. failure) end
end)

-- Optional ox_inventory item export for frameworks which do not forward a slot.
exports('useHarness', function(event, item, inventory, slot)
    if event ~= 'usingItem' then return end
    if ready and type(inventory) == 'table' and inventory.type == 'player' and
        type(item) == 'table' and item.name == C.harnessItem then
        beginHarness(tonumber(inventory.id), {slot=tonumber(slot)})
    end
    return false -- RS Seatbelt owns the progress and wear; ox must not consume it too.
end)

registerRPC('rs-seatbelt:server:profile', function(src)
    if not ready then return errorReply(failure and 'Seatbelt storage/bridge unavailable; contact the owner.' or 'Seatbelt is starting.') end
    local now = GetGameTimer()
    if lastFetch[src] and now - lastFetch[src] < 500 then return errorReply('Please wait.') end
    lastFetch[src] = now
    local ok, session = pcall(loadSession, src)
    if not ok or not session then return errorReply('Character profile unavailable. Try again after loading.') end
    return reply(src, session)
end)

registerRPC('rs-seatbelt:server:save', function(src, request)
    if not ready or type(request) ~= 'table' then return errorReply('Seatbelt service unavailable.') end
    if request.reset ~= nil and type(request.reset) ~= 'boolean' then return errorReply('Invalid reset request.') end
    if request.scope ~= 'personal' and request.scope ~= 'server' then return errorReply('Invalid save target.') end
    local global = request.scope == 'server'
    if global and not admin(src) then return errorReply('Owner permission required.') end
    if not global and C.personalMode == 'server' then return errorReply('Personal presets are disabled by the owner.') end
    if saving[src] or publishing then return errorReply('Another save is finishing. Please retry.') end
    local now = os.time()
    if lastSave[src] and now - lastSave[src] < C.saveCooldownSeconds then return errorReply('Please wait before saving again.') end
    local candidate = not request.reset and Profile.validate(request.profile) or nil
    if not request.reset and not candidate then return errorReply('Invalid prop, animation, bone or transform.') end
    if global and request.reset then return errorReply('Publish a preset to replace the server default.') end
    if not global and candidate and C.personalMode == 'full' and not Profile.allowed(candidate, C) then
        return errorReply('This prop or animation is restricted by the server owner.')
    end
    saving[src], publishing = true, global
    local ok, result = pcall(function()
        local session = loadSession(src)
        if not session then return errorReply('No loaded character.') end
        local id = session.id
        if global and not admin(src) then return errorReply('Owner permission required.') end
        if not global and candidate then candidate = Profile.merge(candidate, serverProfile, C.personalMode) end
        if not Storage.put(global and '__server__' or id, candidate) then return errorReply('Could not write saved preset.') end
        lastSave[src] = now
        if global then
            serverProfile = candidate
            for playerId, s in pairs(sessions) do
                if identity(playerId) == s.id then
                    state(playerId, Profile.merge(s.personal, serverProfile, C.personalMode))
                    TriggerClientEvent('rs-seatbelt:client:profileChanged', playerId, reply(playerId, s))
                end
            end
        elseif identity(src) == id then
            session.personal = candidate
            state(src, Profile.merge(candidate, serverProfile, C.personalMode))
        end
        if identity(src) ~= id then return errorReply('Character changed; saved to the original character only.') end
        return reply(src, session)
    end)
    saving[src] = nil
    if global then publishing = false end
    if not ok then
        print('[rs-seatbelt] Save failed: ' .. tostring(result))
        return errorReply('Storage error. Your previous active preset is unchanged.')
    end
    return result
end)

registerRPC('rs-seatbelt:server:library', function(src, request)
    if not ready or type(request) ~= 'table' then return errorReply('Seatbelt service unavailable.') end
    local global = request.scope == 'server'
    if not global and request.scope ~= 'personal' then return errorReply('Invalid library target.') end
    if global and not admin(src) then return errorReply('Owner permission required.') end
    if not global and C.personalMode ~= 'full' and not admin(src) then return errorReply('Personal asset libraries are disabled by the owner.') end
    if request.action ~= 'save' and request.action ~= 'remove' then return errorReply('Invalid library action.') end
    local now = os.time()
    if lastLibrarySave[src] and now - lastLibrarySave[src] < C.saveCooldownSeconds then return errorReply('Please wait before editing the library again.') end
    local id = identity(src)
    if not id then return errorReply('No loaded character.') end
    local storageId = global and '__library__' or 'library:' .. id
    if librarySaving[storageId] then return errorReply('Another library save is finishing.') end
    librarySaving[storageId] = true
    local ok, result = pcall(function()
        local s = loadSession(src)
        if not s or s.id ~= id then return errorReply('Character changed; reopen the editor.') end
        local current = global and sharedLibrary or s.library
        local clean, message = Library.change(current, request.kind, request.item, request.action == 'remove')
        if not clean then return errorReply(message) end
        if request.action == 'save' and not global and not admin(src) and
            not Library.allowed(request.kind, request.item, C) then return errorReply('This asset is restricted by the server owner.') end
        if global and not admin(src) then return errorReply('Owner permission required.') end
        if not Storage.put(storageId, clean) then return errorReply('Unable to write saved library.') end
        lastLibrarySave[src] = now
        if global then
            sharedLibrary = clean
            TriggerClientEvent('rs-seatbelt:client:libraryChanged', -1, sharedLibrary)
        elseif identity(src) == id then s.library = clean end
        if identity(src) ~= id then return errorReply('Saved to the original character. Reopen the editor.') end
        return reply(src, s)
    end)
    librarySaving[storageId] = nil
    if not ok then
        print('[rs-seatbelt] Library save failed: ' .. tostring(result))
        return errorReply('Library storage error. No save confirmed.')
    end
    return result
end)

registerRPC('rs-seatbelt:server:equip', function(src)
    local ticket = harness[src]
    harness[src] = nil
    if not ready or not ticket or identity(src) ~= ticket.id then return false end
    local now, ped = GetGameTimer(), GetPlayerPed(src)
    if now < ticket.ready or now > ticket.expires or ped == 0 or
        GetEntityHealth(ped) <= 0 or GetVehiclePedIsIn(ped, false) ~= ticket.vehicle then return false end
    local ok, worn = pcall(Bridge.wearHarness, src, ticket.slot)
    return ok and worn == true
end)

RegisterNetEvent('rs-seatbelt:server:cancelHarness', function() harness[source] = nil end)

RegisterNetEvent('rs-seatbelt:server:visual', function(active)
    local src = source
    if type(active) ~= 'boolean' or not ready then return end
    local s = sessions[src]
    if not s or identity(src) ~= s.id then state(src, nil, false) return end
    local ped = GetPlayerPed(src)
    state(src, Profile.merge(s.personal, serverProfile, C.personalMode),
        active and ped ~= 0 and GetVehiclePedIsIn(ped, false) ~= 0)
end)

AddEventHandler('playerDropped', function()
    sessions[source], lastSave[source], lastFetch[source], harness[source] = nil, nil, nil, nil
    lastLibrarySave[source] = nil
end)
AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, s in ipairs(GetPlayers()) do state(tonumber(s), nil, false) end
end)
