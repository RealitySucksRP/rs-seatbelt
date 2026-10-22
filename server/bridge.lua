local C = require 'config.server'
local B = {}
local fw, core, inventory
function B.init()
    fw = C.framework
    if fw == 'auto' then
        if GetResourceState('qbx_core') == 'started' then fw = 'qbox'
        elseif GetResourceState('qb-core') == 'started' then fw = 'qbcore'
        elseif GetResourceState('es_extended') == 'started' then fw = 'esx' end
    end
    assert(fw == 'qbox' or fw == 'qbcore' or fw == 'esx', 'Start Qbox, QBCore or ESX before rs-seatbelt')
    if fw == 'qbcore' then core = exports['qb-core']:GetCoreObject()
    elseif fw == 'esx' then core = exports.es_extended:getSharedObject() end
    inventory = C.inventory
    if inventory == 'auto' then
        if GetResourceState('ox_inventory') == 'started' then inventory = 'ox'
        elseif GetResourceState('qb-inventory') == 'started' and fw == 'qbcore' then inventory = 'qb'
        elseif fw == 'esx' then inventory = 'esx' end
    end
    assert(inventory == 'ox' or inventory == 'qb' and fw == 'qbcore' or inventory == 'esx' and fw == 'esx',
        'Unsupported inventory combination; select ox, qb (QBCore), or esx (ESX native)')
    print(('[rs-seatbelt] Framework: %s; inventory: %s; storage: %s'):format(fw, inventory, C.storage))
end
function B.player(src)
    if fw == 'qbox' then return exports.qbx_core:GetPlayer(src) end
    if fw == 'qbcore' then return core.Functions.GetPlayer(src) end
    return core.GetPlayerFromId(src)
end
function B.identity(src)
    local p = B.player(src)
    if not p then return end
    local id = fw == 'esx' and p.identifier or p.PlayerData.citizenid
    if type(id) == 'string' and #id <= 170 then return fw .. ':' .. id end
end
function B.registerHarness(fn)
    if fw == 'qbox' then exports.qbx_core:CreateUseableItem(C.harnessItem, fn)
    elseif fw == 'qbcore' then core.Functions.CreateUseableItem(C.harnessItem, fn)
    else core.RegisterUsableItem(C.harnessItem, function(src) fn(src, {}) end) end
end
function B.wearHarness(src, slot)
    if inventory == 'esx' then
        local p = B.player(src)
        local item = p and p.getInventoryItem(C.harnessItem)
        if not item or item.count < 1 then return false end
        p.removeInventoryItem(C.harnessItem, 1)
        return true
    end
    if type(slot) ~= 'number' or slot < 1 or slot % 1 ~= 0 then return false end
    local item = inventory == 'ox' and exports.ox_inventory:GetSlot(src, slot) or
        inventory == 'qb' and exports['qb-inventory']:GetItemBySlot(src, slot)
    if not item or item.name ~= C.harnessItem then return false end
    local info = item.metadata or item.info or {}
    if type(info) ~= 'table' then return false end
    local durability = tonumber(info.durability or 100)
    if not durability or durability ~= durability or durability < 0 or durability > 100 then return false end
    local nextValue = durability - C.harnessWear
    if nextValue <= 0 then
        if inventory == 'ox' then return exports.ox_inventory:RemoveItem(src, C.harnessItem, 1, nil, slot) end
        return exports['qb-inventory']:RemoveItem(src, C.harnessItem, 1, slot, 'rs-seatbelt:harness')
    end
    local metadata = {}
    for k, v in pairs(info) do metadata[k] = v end
    metadata.durability = nextValue
    if inventory == 'ox' then exports.ox_inventory:SetMetadata(src, slot, metadata) return true end
    return exports['qb-inventory']:SetItemData(src, C.harnessItem, 'info', metadata, slot) == true
end
return B
