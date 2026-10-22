local pending, serial = {}, 0
local session = ('%s:%s:'):format(GetGameTimer(), math.random(100000,999999))
RegisterNetEvent('rs-seatbelt:client:rpc', function(id, result)
    if source ~= 65535 then return end
    local p = pending[id]
    if not p then return end
    pending[id] = nil
    p:resolve(result)
end)
return function(name, ...)
    serial = serial + 1
    local id, p = session .. serial, promise.new()
    pending[id] = p
    SetTimeout(10000, function()
        if pending[id] ~= p then return end
        pending[id] = nil
        p:resolve({ok=false, message='Server did not respond. Reload your saved preset before retrying.'})
    end)
    TriggerServerEvent('rs-seatbelt:server:rpc', id, name, ...)
    return Citizen.Await(p)
end
