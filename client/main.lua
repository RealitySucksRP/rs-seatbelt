assert(GetResourceState('qbx_seatbelt') ~= 'started', '[rs-seatbelt] Stop qbx_seatbelt before starting this controller.')
local config = require 'config.client'
local request = require 'client.rpc'
local BeltVisual = require 'client.visual'
local soundsConfig = config.sounds or {}
local reminderConfig = config.reminder or {}
-- The B key must not change belt state while a harness use is in flight.
local harnessBusy = false
local playerState = LocalPlayer.state
local speedMultiplier = config.useMPH and 2.237 or 3.6
local minSpeeds = {
    unbuckled = config.minSpeedUnbuckled / speedMultiplier,
    buckled = config.minSpeedBuckled / speedMultiplier,
    harness = config.harness.minSpeed / speedMultiplier
}

-- Native audio: the bank can return false from RequestScriptAudioBank even when
-- it has loaded. Do not use qbx.loadAudioBank here: its timeout aborts playback.
local audioBank = 'audiodirectory/seatbelt_sounds'

-- Keep this small bank loaded for the resource lifetime rather than releasing
-- it before the short buckle/unbuckle sound has finished playing.
CreateThread(function()
    RequestScriptAudioBank(audioBank, false)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        BeltVisual.stop()
        SendNUIMessage({ action = 'stopAll' })
        ReleaseNamedScriptAudioBank(audioBank)
        playerState.seatbelt, playerState.harness = false, false
        if cache.ped then SetPedConfigFlag(cache.ped, 32, true) end
    end
end)

-- Only the playing client hears these NUI sounds. The working GTA audio bank
-- still handles its original buckle/unbuckle sounds as before.
local reminderStartAt
local reminderNextAt

local function stopReminder()
    if reminderStartAt then
        reminderStartAt = nil
        reminderNextAt = nil
        SendNUIMessage({ action = 'stopReminder' })
    end
end

local function reminderEligible(vehicle)
    if not reminderConfig.enabled or playerState.seatbelt or playerState.harness then return false end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    if not cache.ped or IsEntityDead(cache.ped) or IsPauseMenuActive() then return false end
    if not GetIsVehicleEngineRunning(vehicle) then return false end

    local class = GetVehicleClass(vehicle)
    if class == 8 or class == 13 or class == 14 then return false end

    local isDriver = GetPedInVehicleSeat(vehicle, -1) == cache.ped
    if reminderConfig.driversOnly and not isDriver then return false end
    if reminderConfig.frontSeatsOnly and not isDriver and GetPedInVehicleSeat(vehicle, 0) ~= cache.ped then
        return false
    end

    if (reminderConfig.minSpeed or 0) > 0 then
        local conversion = config.useMPH and 2.236936 or 3.6
        if GetEntitySpeed(vehicle) * conversion < reminderConfig.minSpeed then return false end
    end
    return true
end

local function updateReminder(vehicle)
    if not reminderEligible(vehicle) then
        stopReminder()
        return
    end

    local now = GetGameTimer()
    if not reminderStartAt then
        reminderStartAt = now
        reminderNextAt = now + math.max(0, reminderConfig.delayMs or 3500)
        return
    end

    if now >= reminderNextAt then
        SendNUIMessage({
            action = 'play',
            sound = 'reminder',
            volume = reminderConfig.volume or 0.52
        })
        reminderNextAt = now + math.max(1500, reminderConfig.intervalMs or 7000)
    end
end

-- Functions
local function playBuckleSound(seatbelt)
    -- Request again in case the initial preload ran before audio was ready.
    -- The boolean result is deliberately not used due to FiveM issue #2989.
    RequestScriptAudioBank(audioBank, false)
    PlaySoundFromEntity(-1, seatbelt and 'carbuckle' or 'carunbuckle', cache.ped, 'seatbelt_soundset', false, 0)

    if soundsConfig.enhanced then
        SendNUIMessage({
            action = 'play',
            sound = seatbelt and 'buckle' or 'unbuckle',
            volume = seatbelt and (soundsConfig.buckleVolume or 0.68) or (soundsConfig.unbuckleVolume or 0.65)
        })
    end
end

local function toggleSeatbelt()
    if harnessBusy then return end
    if playerState.harness then
        lib.notify({description=locale('error.harnesson'), type='error'})
        return
    end
    local seatbeltOn = not playerState.seatbelt
    playerState.seatbelt = seatbeltOn
    if seatbeltOn then stopReminder() end
    BeltVisual.update(cache.vehicle, seatbeltOn)
    if not seatbeltOn then BeltVisual.unbuckleMotion(cache.vehicle) end
    SetFlyThroughWindscreenParams(seatbeltOn and minSpeeds.buckled or minSpeeds.unbuckled, 1.0, 17.0, 10.0)
    TriggerEvent('seatbelt:client:ToggleSeatbelt')
    playBuckleSound(seatbeltOn)
end

local function toggleHarness()
    local harnessOn = not playerState.harness
    playerState.harness = harnessOn
    if harnessOn then stopReminder() end
    BeltVisual.update(cache.vehicle, harnessOn)
    TriggerEvent('seatbelt:client:ToggleSeatbelt')
    playBuckleSound(harnessOn)

    local canFlyThroughWindscreen = not harnessOn
    if config.harness.disableFlyingThroughWindscreen then
        SetPedConfigFlag(cache.ped, 32, canFlyThroughWindscreen) -- PED_FLAG_CAN_FLY_THRU_WINDSCREEN
    else
        local minSpeed = harnessOn and minSpeeds.harness or (playerState.seatbelt and minSpeeds.buckled or minSpeeds.unbuckled)
        SetFlyThroughWindscreenParams(minSpeed, 1.0, 17.0, 10.0)
    end
end

local vehicleSession = 0
local function seatbelt(vehicle, session)
    local nextReminderCheck = 0
    while cache.vehicle == vehicle and session == vehicleSession do
        -- Death does not necessarily trigger a vehicle-cache transition. Clear stale
        -- buckle/harness flags so they cannot persist through revive in the same seat.
        if cache.ped and IsEntityDead(cache.ped) and (playerState.seatbelt or playerState.harness) then
            playerState.seatbelt, playerState.harness = false, false
            SetPedConfigFlag(cache.ped, 32, true)
            SetFlyThroughWindscreenParams(minSpeeds.unbuckled, 1.0, 17.0, 10.0)
            BeltVisual.reset()
        end
        -- Keep the original per-frame exit prevention while fastened.
        local sleep = reminderConfig.enabled and 250 or 1000
        if playerState.seatbelt or playerState.harness then
            sleep = 0
            DisableControlAction(0, 75, true)
            DisableControlAction(27, 75, true)
        end

        local now = GetGameTimer()
        if now >= nextReminderCheck then
            BeltVisual.update(vehicle, playerState.seatbelt or playerState.harness)
            if reminderConfig.enabled then updateReminder(vehicle) end
            nextReminderCheck = now + 250
        end
        Wait(sleep)
    end
end

-- Export
function HasHarness()
    return playerState.harness
end

--- @deprecated Use `state.seatbelt` instead
exports('HasHarness', HasHarness)

-- Main Thread
CreateThread(function()
    SetFlyThroughWindscreenParams(minSpeeds.unbuckled, 1.0, 17.0, 10.0)
end)

local function onVehicleChanged(vehicle)
    vehicleSession = vehicleSession + 1
    local session = vehicleSession
    -- Immediate cleanup; no 500ms wait to leave the strap or icon behind.
    stopReminder()
    playerState.seatbelt = false
    playerState.harness = false
    BeltVisual.reset()
    SetFlyThroughWindscreenParams(minSpeeds.unbuckled, 1.0, 17.0, 10.0)
    if config.harness.disableFlyingThroughWindscreen and cache.ped then
        SetPedConfigFlag(cache.ped, 32, true)
    end
    if not vehicle then return end
    CreateThread(function()
        if session == vehicleSession then
            BeltVisual.update(vehicle, false)
            seatbelt(vehicle, session)
        end
    end)
end

lib.onCache('vehicle', onVehicleChanged)
AddEventHandler('QBCore:Client:OnPlayerUnload', function() onVehicleChanged(nil) end)
AddEventHandler('esx:onPlayerLogout', function() onVehicleChanged(nil) end)
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() onVehicleChanged(cache.vehicle) end)
RegisterNetEvent('esx:playerLoaded', function() onVehicleChanged(cache.vehicle) end)
-- On hot restart, the player can already be sitting in a vehicle.
CreateThread(function()
    Wait(100)
    if vehicleSession == 0 and cache.vehicle then onVehicleChanged(cache.vehicle) end
end)

-- Events
RegisterNetEvent('rs-seatbelt:client:UseHarness', function()
    if source ~= 65535 or harnessBusy then return end
    if playerState.seatbelt then
        lib.notify({description=locale('error.seatbelton'), type='error'})
        return
    end

    if not cache.vehicle then
        lib.notify({description=locale('notify.notInCar'), type='error'})
        return
    end
    local class = GetVehicleClass(cache.vehicle)

    if class == 8 or class == 13 or class == 14 then
        lib.notify({description=locale('notify.notInCar'), type='error'})
        return
    end

    local startingVehicle = cache.vehicle
    local startingSession = vehicleSession
    harnessBusy = true
    if not playerState.harness then
        if lib.progressCircle({
            duration = 5000,
            label = locale('progress.attachHarness'),
            position = 'bottom',
            useWhileDead = false,
            canCancel = true,
            disable = {
                combat = true
            }
        }) and cache.vehicle == startingVehicle and IsPedInVehicle(cache.ped, startingVehicle, false) then
            local ok, equipped = pcall(request, 'rs-seatbelt:server:equip')
            if ok and equipped == true and cache.vehicle == startingVehicle and startingSession == vehicleSession then
                toggleHarness()
            else
                lib.notify({description='Harness equip was not confirmed. Check the item and try again.', type='error'})
            end
        end
    else
        if lib.progressCircle({
            duration = 5000,
            label = locale('progress.removeHarness'),
            position = 'bottom',
            useWhileDead = false,
            canCancel = true,
            disable = {
                combat = true
            }
        }) and cache.vehicle == startingVehicle and startingSession == vehicleSession and
            IsPedInVehicle(cache.ped, startingVehicle, false) then
            toggleHarness()
        end
    end
    harnessBusy = false
    TriggerServerEvent('rs-seatbelt:server:cancelHarness')
end)

-- Register Key
lib.addKeybind({
    name = 'toggleseatbelt',
    description = locale('toggleCommand'),
    defaultKey = config.keybind,
    onPressed = function()
        if not cache.vehicle or IsPauseMenuActive() then return end
        local class = GetVehicleClass(cache.vehicle)
        if class == 8 or class == 13 or class == 14 then return end
        toggleSeatbelt()
    end
})
