-- Seatbelt cosmetics only. The existing seatbelt / harness safety logic remains in main.lua.
-- The prop is created locally on every nearby viewer from a replicated server state;
-- this avoids networked-object duplication and ownership/cleanup races.
local config = require 'config.client'
local Profile = require 'shared.profile'
local Library = require 'shared.library'
local request = require 'client.rpc'
local currentProfile = Profile.defaults()
local editorProfile, permissions, previewGeneration = nil, {}, 0
local rebuildLocal
local stopTest
local editorToken = 0
local visual = config.visual or {}
local anim = visual.animation or {}
local attach = visual.attachment or {}
local enabled = visual.enabled ~= false
local synced = visual.showOnOtherPlayers ~= false
local modelHash = joaat(visual.model or 'prop_cs_heist_bag_strap_01')
local animDict = anim.dict or 'oddjobs@basejump@ig_15'
local animClip = anim.clip or 'puton_parachute'
local propBone = attach.bone or 24817 -- SKEL_Spine2 (not a hand bone)

local localEpoch = 0
local localPed
local localProp
local missingLocalRetryAt = 0
local wantedLocal = false
local hudVisible = false
local sentState
local stopped = false
local remoteProps = {}
local editorOpen = false
local editorOpening = false
local editorSaving = false
local editorDraft
local currentAlignment
local alignmentKeys = { 'x', 'y', 'z', 'rx', 'ry', 'rz' }
local alignmentLimits = { x = .35, y = .35, z = .35, rx = 180, ry = 180, rz = 180 }
local removalAnim = visual.removalAnimation or {}
local removalEpoch = 0
local editorCam
local editorAnchor
local cameraGeneration = 0
local cameraState
local cameraConfig = visual.alignmentCamera or {}

local function stopRemoval(ped)
    removalEpoch = removalEpoch + 1
    if ped and ped ~= 0 and DoesEntityExist(ped) and removalAnim.enabled ~= false then
        local dict = removalAnim.dict or 'missfam3'
        local clip = removalAnim.clip or 'react_incar_brace_enter_f'
        if IsEntityPlayingAnim(ped, dict, clip, 3) then StopAnimTask(ped, dict, clip, 2.5) end
    end
end

-- Unbuckling removes the strap immediately; this short upper-body motion is
-- cancellable and never blocks input or a rapid vehicle exit/re-entry.
local function playRemoval(ped, vehicle)
    if removalAnim.enabled == false or not ped or not vehicle or vehicle == 0 then return end
    stopRemoval(ped)
    local expected = removalEpoch
    local dict = removalAnim.dict or 'missfam3'
    local clip = removalAnim.clip or 'react_incar_brace_enter_f'
    CreateThread(function()
        if not DoesAnimDictExist(dict) then return end
        RequestAnimDict(dict)
        local deadline = GetGameTimer() + (visual.assetTimeoutMs or 1600)
        while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do
            if stopped or expected ~= removalEpoch or cache.ped ~= ped or cache.vehicle ~= vehicle then return end
            Wait(0)
        end
        if not HasAnimDictLoaded(dict) or stopped or expected ~= removalEpoch or
            cache.ped ~= ped or cache.vehicle ~= vehicle or
            not IsPedInVehicle(ped, vehicle, false) or LocalPlayer.state.seatbelt or LocalPlayer.state.harness then return end
        TaskPlayAnim(ped, dict, clip, 8.0, -8.0, removalAnim.durationMs or 430, 48, 0.0, false, false, false)
        Wait(0)
        if expected == removalEpoch and IsEntityPlayingAnim(ped, dict, clip, 3) then
            SetEntityAnimSpeed(ped, dict, clip, removalAnim.speed or 1.7)
        end
        RemoveAnimDict(dict)
    end)
end


local function copyAlignment(src)
    local out = {}
    for _, key in ipairs(alignmentKeys) do out[key] = src[key] end
    return out
end

local function validateAlignment(src)
    if type(src) ~= 'table' then return nil end
    local out = {}
    for _, key in ipairs(alignmentKeys) do
        local n = tonumber(src[key])
        if not n or n ~= n or n == math.huge or n == -math.huge or
            math.abs(n) > alignmentLimits[key] then return nil end
        out[key] = math.floor(n * 1000 + 0.5) / 1000
    end
    return out
end

local defaultAlignment = validateAlignment(attach)
currentAlignment = copyAlignment(defaultAlignment)

local function eligibleVehicle(ped, vehicle)
    if not ped or ped == 0 or not DoesEntityExist(ped) or IsEntityDead(ped) then return false end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    if not IsPedInVehicle(ped, vehicle, false) then return false end
    local class = GetVehicleClass(vehicle)
    return class ~= 8 and class ~= 13 and class ~= 14
end

local function deleteProp(prop)
    if prop and prop ~= 0 and DoesEntityExist(prop) then
        DetachEntity(prop, false, false)
        SetEntityAsMissionEntity(prop, true, true)
        DeleteEntity(prop)
    end
end

local function stopMotion(ped)
    if ped and ped ~= 0 and DoesEntityExist(ped) and
        IsEntityPlayingAnim(ped, animDict, animClip, 3) then
        StopAnimTask(ped, animDict, animClip, 2.5)
    end
end

local function loadAsset(check, isModel, profile)
    local modelHash = profile and joaat(profile.model) or modelHash
    local animDict = profile and profile.animation.dict or animDict
    if isModel then
        if not IsModelInCdimage(modelHash) or not IsModelValid(modelHash) or
            IsModelAVehicle(modelHash) or IsModelAPed(modelHash) then return false end
        RequestModel(modelHash)
    else
        if not DoesAnimDictExist(animDict) then return false end
        RequestAnimDict(animDict)
    end

    local deadline = GetGameTimer() + (visual.assetTimeoutMs or 1600)
    while not (isModel and HasModelLoaded(modelHash) or not isModel and HasAnimDictLoaded(animDict)) do
        if stopped or not check() or GetGameTimer() >= deadline then return false end
        Wait(0)
    end
    return not stopped and check()
end

local function applyAlignment(prop, ped, alignment, bone)
    if not prop or prop == 0 or not DoesEntityExist(prop) or
        not ped or ped == 0 or not DoesEntityExist(ped) then return end
    local a = alignment or currentAlignment
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, bone or propBone),
        a.x, a.y, a.z, a.rx, a.ry, a.rz,
        false, false, false, false, 2, true)
end

local function closeEditor(revert)
    if not editorOpen then return end
    if stopTest then stopTest() end
    editorToken = editorToken + 1
    editorOpen = false
    editorSaving = false
    editorDraft = nil
    editorProfile = nil
    previewGeneration = previewGeneration + 1
    cameraGeneration = cameraGeneration + 1
    if editorCam then
        RenderScriptCams(false, true, 180, true, true)
        SetCamActive(editorCam, false)
        DestroyCam(editorCam, false)
        editorCam = nil
    end
    deleteProp(editorAnchor)
    editorAnchor = nil
    cameraState = nil
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeAlignmentEditor' })
    if revert and rebuildLocal and wantedLocal then rebuildLocal(currentProfile) end
end

local function createAttachedProp(ped, check, profile)
    profile = Profile.copy(profile or currentProfile)
    local hash = joaat(profile.model)
    if not loadAsset(check, true, profile) then return nil end
    if not check() or not DoesEntityExist(ped) then return nil end
    local pos = GetEntityCoords(ped)
    -- Client-side prop: observers independently display the same belt on this ped.
    local obj = CreateObjectNoOffset(hash, pos.x, pos.y, pos.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    if not check() then deleteProp(obj) return nil end
    SetEntityCollision(obj, false, false)
    SetEntityInvincible(obj, true)
    applyAlignment(obj, ped, profile, profile.bone)
    if not check() then deleteProp(obj) return nil end
    return obj
end

rebuildLocal = function(profile)
    local ped, epoch = localPed, localEpoch
    previewGeneration = previewGeneration + 1
    local generation = previewGeneration
    CreateThread(function()
        local function alive()
            return not stopped and wantedLocal and localEpoch == epoch and previewGeneration == generation and
                cache.ped == ped and eligibleVehicle(ped, cache.vehicle)
        end
        local prop = createAttachedProp(ped, alive, profile)
        if prop then
            deleteProp(localProp)
            localProp = prop
        end
    end)
end

local function cleanupLocal()
    closeEditor(true)
    missingLocalRetryAt = 0
    localEpoch = localEpoch + 1 -- invalidates any in-flight model or animation loads
    stopMotion(localPed)
    stopRemoval(localPed or cache.ped)
    deleteProp(localProp)
    localProp = nil
    localPed = nil
    wantedLocal = false
end

local function startLocal(ped)
    cleanupLocal()
    missingLocalRetryAt = GetGameTimer() + 5000
    localPed = ped
    wantedLocal = true
    local expected = localEpoch
    local preview = previewGeneration
    local profile = Profile.copy(currentProfile)
    local function alive()
        return expected == localEpoch and preview == previewGeneration and wantedLocal and cache.ped == ped and
            eligibleVehicle(ped, cache.vehicle)
    end

    CreateThread(function()
        local obj = createAttachedProp(ped, alive, profile)
        if obj then localProp = obj end
    end)

    if anim.enabled ~= false then
        CreateThread(function()
            if not loadAsset(alive, false, profile) then return end
            local animDict, animClip = profile.animation.dict, profile.animation.clip
            if not alive() then return end
            -- AF_UPPERBODY | AF_SECONDARY: does not interrupt seated driving tasks.
            TaskPlayAnim(ped, animDict, animClip, 8.0, -8.0,
                profile.animation.durationMs, 48, 0.0, false, false, false)
            Wait(0)
            if alive() and IsEntityPlayingAnim(ped, animDict, animClip, 3) then
                SetEntityAnimSpeed(ped, animDict, animClip, profile.animation.speed)
            end
            RemoveAnimDict(animDict)
        end)
    end
end

local function setIndicator(show)
    if show == hudVisible then return end
    hudVisible = show
    SendNUIMessage({ action = 'beltIndicator', show = show })
end

local function syncState(value)
    if sentState == value then return end
    sentState = value
    TriggerServerEvent('rs-seatbelt:server:visual', value)
end

local BeltVisual = {}

function BeltVisual.unbuckleMotion(vehicle)
    if stopped or not enabled then return end
    local ped = cache.ped
    if eligibleVehicle(ped, vehicle) then playRemoval(ped, vehicle) end
end

function BeltVisual.update(vehicle, fastened)
    if stopped then return end
    local ped = cache.ped
    local eligible = enabled and eligibleVehicle(ped, vehicle)
    local fastenedHere = eligible and fastened == true
    if editorOpen and not fastenedHere then closeEditor(true) end
    setIndicator(eligible and not fastenedHere and visual.iconEnabled ~= false)
    if fastenedHere then
        if not wantedLocal or localPed ~= ped then
            startLocal(ped)
        elseif not localProp and not editorOpen and GetGameTimer() >= missingLocalRetryAt then
            -- A model stream timeout used to leave the belt missing until the next
            -- vehicle change. Retry only the cosmetic prop at bounded intervals;
            -- don't replay the fastening animation or create overlapping objects.
            missingLocalRetryAt = GetGameTimer() + 5000
            rebuildLocal(currentProfile)
        end
    elseif wantedLocal or localProp then
        cleanupLocal()
    end
    syncState(fastenedHere and synced)
end

local function clearRemoteSlot(id)
    local slot = remoteProps[id]
    if not slot then return end
    slot.active = false -- cancels any in-flight prop model load
    deleteProp(slot.prop)
    remoteProps[id] = nil
end

-- Called by the main vehicle-cache handler on exit or during resource shutdown.
function BeltVisual.reset()
    setIndicator(false)
    cleanupLocal()
    syncState(false)
end

function BeltVisual.stop()
    closeEditor(true)
    stopped = true
    cleanupLocal()
    setIndicator(false)
    for id in pairs(remoteProps) do clearRemoteSlot(id) end
    -- Server clears all cosmetic states on resource stop/restart.
end

-- Other players see straps via a replicated BOOL, not owned network props.
-- Check actual ped/vehicle on this viewer (handles OneSync streaming and fast exits).
if enabled and synced then
    CreateThread(function()
        while not stopped do
            local seen = {}
            local myPed = cache.ped
            local myPos = myPed and DoesEntityExist(myPed) and GetEntityCoords(myPed)
            for _, playerId in ipairs(GetActivePlayers()) do
                if playerId ~= PlayerId() then
                    local id = GetPlayerServerId(playerId)
                    local ped = GetPlayerPed(playerId)
                    local state = Player(playerId).state
                    local vehicle = ped ~= 0 and DoesEntityExist(ped) and GetVehiclePedIsIn(ped, false) or 0
                    local close = myPos and ped ~= 0 and DoesEntityExist(ped) and
                        #(GetEntityCoords(ped) - myPos) < (visual.streamingDistance or 85.0)
                    if state.rsSeatbeltVisual == true and close and eligibleVehicle(ped, vehicle) then
                        seen[id] = true
                        local profile = Profile.validate(state.rsSeatbeltProfile) or Profile.defaults()
                        local signature = json.encode(profile)
                        local slot = remoteProps[id]
                        if slot and (slot.signature ~= signature or slot.ped ~= ped or slot.prop and not DoesEntityExist(slot.prop)) then
                            clearRemoteSlot(id)
                            slot = nil
                        end
                        if not slot then
                            slot = { ped = ped, active = true, signature = signature, profile = profile }
                            remoteProps[id] = slot
                        end
                        if not slot.prop and not slot.pending and
                            (not slot.retryAfter or GetGameTimer() >= slot.retryAfter) then
                            slot.pending = true
                            local current = slot
                            CreateThread(function()
                                local obj = createAttachedProp(ped, function()
                                    return current.active and remoteProps[id] == current and
                                        eligibleVehicle(ped, GetVehiclePedIsIn(ped, false))
                                end, current.profile)
                                if obj then
                                    current.prop = obj
                                else
                                    current.retryAfter = GetGameTimer() + 5000
                                end
                                current.pending = false
                            end)
                        end
                    end
                end
            end
            for id in pairs(remoteProps) do
                if not seen[id] then clearRemoteSlot(id) end
            end
            Wait(visual.observerIntervalMs or 750)
        end
    end)
end


-- Scripted orbit camera on the REAL seated ped. The temporary invisible object
-- carries the chest bone's real transform to the same Three.js XYZ gizmo used
-- by RS Consumables. All objects and camera ownership stay local.
local function cameraView(action)
    if not cameraState then return end
    local c = cameraState
    -- Elevated, front-left three-quarter default stays outside the ped's lower body.
    -- Camera settings affect the editor view only; saved strap offsets are untouched.
    if action == 'front' then c.yaw, c.pitch, c.distance, c.height = 0, 12, 1.80, 0.16
    elseif action == 'left' then c.yaw, c.pitch, c.distance, c.height = 90, 9, 1.45, 0.12
    elseif action == 'right' then c.yaw, c.pitch, c.distance, c.height = -90, 9, 1.45, 0.12
    elseif action == 'back' then c.yaw, c.pitch, c.distance, c.height = 180, 9, 1.65, 0.12
    elseif action == 'chest' then c.yaw, c.pitch, c.distance, c.height = 0, 8, 1.05, 0.10
    elseif action == 'shoulder' then c.yaw, c.pitch, c.distance, c.height = 35, 14, 1.30, 0.18
    else
        c.yaw = cameraConfig.yaw or 38.0
        c.pitch = cameraConfig.pitch or 12.0
        c.distance = cameraConfig.distance or 1.85
        c.height = cameraConfig.height or 0.18
    end
end

local function updateEditorCamera()
    if not editorCam or not editorAnchor or not DoesEntityExist(editorAnchor) or not cameraState then return nil end
    local a = GetEntityCoords(editorAnchor)
    local c = cameraState
    local target = vector3(a.x, a.y, a.z + c.height)
    local heading = math.rad(GetEntityHeading(localPed) + c.yaw)
    local pitch = math.rad(c.pitch)
    local horizontal = math.cos(pitch) * c.distance
    local pos = vector3(target.x - math.sin(heading) * horizontal,
        target.y + math.cos(heading) * horizontal,
        target.z + math.sin(pitch) * c.distance)
    SetCamCoord(editorCam, pos.x, pos.y, pos.z)
    PointCamAtCoord(editorCam, target.x, target.y, target.z)
    SetCamFov(editorCam, c.fov)
    return { position = pos, target = target, fov = c.fov }
end

local function beginEditorCamera(ped)
    if not localProp or not DoesEntityExist(localProp) then return false end
    -- Stream explicitly even if the display prop has already relinquished its model request.
    RequestModel(modelHash)
    local deadline = GetGameTimer() + 800
    while not HasModelLoaded(modelHash) and GetGameTimer() < deadline do
        if not editorOpen or cache.ped ~= ped then return false end
        Wait(0)
    end
    if not HasModelLoaded(modelHash) then return false end
    local pos = GetEntityCoords(ped)
    local anchor = CreateObjectNoOffset(modelHash, pos.x, pos.y, pos.z, false, false, false)
    SetModelAsNoLongerNeeded(modelHash)
    if not anchor or anchor == 0 or not DoesEntityExist(anchor) then return false end
    SetEntityVisible(anchor, false, false)
    SetEntityCollision(anchor, false, false)
    SetEntityInvincible(anchor, true)
    AttachEntityToEntity(anchor, ped, GetPedBoneIndex(ped, propBone),
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    editorAnchor = anchor
    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    if not cam or cam == 0 then deleteProp(editorAnchor) editorAnchor = nil return false end
    editorCam = cam
    cameraState = {
        yaw = cameraConfig.yaw or 38.0, pitch = cameraConfig.pitch or 12.0,
        distance = cameraConfig.distance or 1.85,
        height = cameraConfig.height or 0.18, fov = cameraConfig.fov or 38.0
    }
    updateEditorCamera()
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 180, true, true)
    cameraGeneration = cameraGeneration + 1
    local expected = cameraGeneration
    CreateThread(function()
        local nextFrame = 0
        while editorOpen and cameraGeneration == expected do
            if not eligibleVehicle(cache.ped, cache.vehicle) or
                cache.ped ~= ped or (not LocalPlayer.state.seatbelt and not LocalPlayer.state.harness) or
                not DoesEntityExist(editorAnchor) or not DoesEntityExist(localProp) then
                closeEditor(true)
                break
            end
            DisableControlAction(0, 75, true)
            DisableControlAction(27, 75, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 1, true)
            DisableControlAction(0, 2, true)
            local camInfo = updateEditorCamera()
            if camInfo and GetGameTimer() >= nextFrame then
                nextFrame = GetGameTimer() + 33
                local a = GetEntityCoords(editorAnchor)
                local r = GetEntityRotation(editorAnchor, 2)
                SendNUIMessage({ action = 'strapGizmoFrame',
                    anchor = { position = { x=a.x, y=a.y, z=a.z }, rotation = { x=r.x, y=r.y, z=r.z } },
                    camera = { position = {x=camInfo.position.x,y=camInfo.position.y,z=camInfo.position.z},
                        target = {x=camInfo.target.x,y=camInfo.target.y,z=camInfo.target.z}, fov=camInfo.fov }
                })
            end
            Wait(0)
        end
    end)
    return true
end

-- Alignment Studio: admin-gated from the server command /rsbeltalign.
-- Preview changes affect only the local prop; Save is validated and persisted server-side.
local function acceptProfile(response)
    local p = type(response) == 'table' and response.ok and Profile.validate(response.profile)
    if not p then return false end
    local changed = json.encode(currentProfile) ~= json.encode(p)
    if changed then stopMotion(localPed) stopRemoval(localPed or cache.ped) end
    local newCharacter = permissions.identity ~= response.identity
    currentProfile, permissions = p, response
    currentAlignment = copyAlignment(p)
    modelHash, propBone = joaat(p.model), p.bone
    anim, removalAnim = p.animation, p.removalAnimation
    animDict, animClip = anim.dict, anim.clip
    if changed and not editorOpen and wantedLocal then rebuildLocal(p) end
    if newCharacter then
        sentState = nil
        BeltVisual.update(cache.vehicle, LocalPlayer.state.seatbelt or LocalPlayer.state.harness)
    end
    return true
end
RegisterNetEvent('rs-seatbelt:client:profileChanged', function(response)
    if source ~= 65535 then return end
    acceptProfile(response)
end)
RegisterNetEvent('rs-seatbelt:client:libraryChanged', function(values)
    if source ~= 65535 then return end
    local library = Library.validate(values)
    if not library then return end
    permissions.libraries = permissions.libraries or {personal=Library.empty()}
    permissions.libraries.server = library
    if editorOpen then SendNUIMessage({action='libraryChanged', libraries=permissions.libraries}) end
end)

local function openEditor()
    if stopped or editorOpen or editorOpening or not enabled then return end
    editorOpening = true
    local ok, response = pcall(request, 'rs-seatbelt:server:profile')
    editorOpening = false
    if stopped or editorOpen then return end
    if not ok or not acceptProfile(response) then
        lib.notify({description=type(response) == 'table' and response.message or 'Profile request timed out.', type='error'})
        return
    end
    if permissions.mode == 'server' and not permissions.admin then
        lib.notify({description='The server owner has disabled personal customization.', type='error'})
        return
    end
    if not (cache.vehicle and eligibleVehicle(cache.ped, cache.vehicle)) then
        lib.notify({ description = 'Enter a supported vehicle before calibrating.', type = 'error' })
        return
    end
    if LocalPlayer.state.seatbelt ~= true and LocalPlayer.state.harness ~= true then
        lib.notify({ description = 'Fasten your seatbelt first (B), then run /rsbeltalign.', type = 'error' })
        return
    end
    if not localProp or not DoesEntityExist(localProp) then
        lib.notify({ description = 'Seatbelt prop is still loading. Try again in a moment.', type = 'error' })
        return
    end
    editorDraft = copyAlignment(currentAlignment)
    editorProfile = Profile.copy(currentProfile)
    editorOpen = true
    editorToken = editorToken + 1
    editorSaving = false
    if not beginEditorCamera(cache.ped) then
        closeEditor(true)
        lib.notify({ description = 'Unable to initialize seatbelt gizmo camera.', type = 'error' })
        return
    end
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'openAlignmentEditor', values = editorDraft,
        defaults = defaultAlignment, profile=editorProfile, serverProfile=permissions.serverProfile,
        admin=permissions.admin, mode=permissions.mode, libraries=permissions.libraries })
end
RegisterCommand('rsbeltalign', openEditor, false)
RegisterCommand('rsbelt', openEditor, false)

RegisterNetEvent('rs-seatbelt:client:alignmentError', function(message)
    if editorOpen then
        editorSaving = false
        SendNUIMessage({ action = 'alignmentSaveError', message = message or 'Save failed' })
    else
        lib.notify({ description = message or 'Seatbelt alignment request denied.', type = 'error' })
    end
end)

RegisterNUICallback('strapCamera', function(data, cb)
    if not editorOpen or not cameraState or type(data) ~= 'table' then cb({ok=false}) return end
    local c = cameraState
    local action = data.action
    local function safe(v, fallback, limit)
        local n = tonumber(v)
        if not n or n ~= n or math.abs(n) > limit then return fallback end
        return n
    end
    if action == 'orbit' then
        c.yaw = (c.yaw - safe(data.dx, 0, 500) * 0.28) % 360
        c.pitch = math.max(-45, math.min(50, c.pitch + safe(data.dy, 0, 500) * 0.22))
    elseif action == 'zoom' then
        c.distance = math.max(cameraConfig.minDistance or .48,
            math.min(cameraConfig.maxDistance or 3.2, c.distance + safe(data.delta, 0, 2000) * .003))
    elseif action == 'pan' then
        c.height = math.max(-.50, math.min(.55, c.height - safe(data.dy, 0, 400) * .003))
    elseif action == 'preset' then
        local valid = {front=true,left=true,right=true,back=true,chest=true,shoulder=true,reset=true}
        if not valid[data.preset] then cb({ok=false}) return end
        cameraView(data.preset)
    else cb({ok=false}) return end
    updateEditorCamera()
    cb({ok=true})
end)

RegisterNUICallback('strapPreview', function(data, cb)
    if not editorOpen then cb({ ok = false }) return end
    if not eligibleVehicle(cache.ped, cache.vehicle) or
        (not LocalPlayer.state.seatbelt and not LocalPlayer.state.harness) then
        closeEditor(true)
        cb({ ok = false })
        return
    end
    local values = validateAlignment(data)
    if not values then cb({ ok = false }) return end
    editorDraft = values
    for key, value in pairs(values) do editorProfile[key] = value end
    applyAlignment(localProp, localPed, editorDraft, editorProfile.bone)
    cb({ ok = true })
end)

local function validatedAssets(p, alive)
    if not loadAsset(alive, true, p) then return false, 'Prop is not a loaded object model.' end
    SetModelAsNoLongerNeeded(joaat(p.model))
    for _, a in ipairs({p.animation, p.removalAnimation}) do
        if a.enabled then
            if not DoesAnimDictExist(a.dict) then return false, 'Animation dictionary does not exist.' end
            RequestAnimDict(a.dict)
            local deadline = GetGameTimer() + (visual.assetTimeoutMs or 1600)
            while not HasAnimDictLoaded(a.dict) and GetGameTimer() < deadline and alive() do Wait(0) end
            local valid = alive() and HasAnimDictLoaded(a.dict) and GetAnimDuration(a.dict, a.clip) > 0
            RemoveAnimDict(a.dict)
            if not valid then return false, 'Animation clip is unavailable in this dictionary.' end
        end
    end
    return alive()
end

RegisterNUICallback('strapProfile', function(data, cb)
    if not editorOpen or editorSaving then cb({ok=false, message='Editor unavailable.'}) return end
    local p = Profile.validate(data)
    if not p then cb({ok=false, message='Invalid profile values.'}) return end
    if stopTest then stopTest() end
    if permissions.mode ~= 'full' and not permissions.admin then
        for _, key in ipairs({'model','bone','animation','removalAnimation'}) do p[key] = currentProfile[key] end
    end
    -- Asset replacement must never import a different prop's transform.
    for _, key in ipairs(alignmentKeys) do p[key] = editorDraft[key] end
    previewGeneration = previewGeneration + 1
    local generation, epoch = previewGeneration, localEpoch
    local function alive()
        return editorOpen and not stopped and generation == previewGeneration and epoch == localEpoch and
            eligibleVehicle(cache.ped, cache.vehicle) and (LocalPlayer.state.seatbelt or LocalPlayer.state.harness)
    end
    local ok, message = validatedAssets(p, alive)
    if not ok then cb({ok=false, message=message or 'Preview cancelled.'}) return end
    local replacement = createAttachedProp(localPed, alive, p)
    if not replacement then cb({ok=false, message='Unable to create preview prop.'}) return end
    deleteProp(localProp)
    localProp, editorProfile, editorDraft = replacement, p, copyAlignment(p)
    if editorAnchor and DoesEntityExist(editorAnchor) then
        AttachEntityToEntity(editorAnchor, localPed, GetPedBoneIndex(localPed, p.bone),
            0.0,0.0,0.0,0.0,0.0,0.0,false,false,false,false,2,true)
    end
    cb({ok=true})
end)

RegisterNUICallback('strapLibrary', function(data, cb)
    if not editorOpen or editorSaving or type(data) ~= 'table' then cb({ok=false, message='Editor unavailable.'}) return end
    local token = editorToken
    if data.action == 'save' then
        local p = Profile.copy(editorProfile)
        if data.kind == 'props' and Profile.validModel(data.item) then p.model = data.item
        elseif data.kind == 'animations' then
            local a = Profile.validAnimation(data.item)
            if not a then cb({ok=false, message='Invalid animation.'}) return end
            a.enabled = true
            p.animation, p.removalAnimation = a, a
        else cb({ok=false, message='Invalid library entry.'}) return end
        local ok, message = validatedAssets(p, function()
            return not stopped and editorOpen and editorToken == token and eligibleVehicle(cache.ped, cache.vehicle)
        end)
        if not ok then cb({ok=false, message=message or 'Library request cancelled.'}) return end
    end
    local ok, response = pcall(request, 'rs-seatbelt:server:library',
        {scope=data.scope, kind=data.kind, action=data.action, item=data.item})
    if not editorOpen or editorToken ~= token then cb({ok=false, message='Editor closed. Reopen to see saved entries.'}) return end
    if not ok or not acceptProfile(response) then
        cb({ok=false, message=type(response) == 'table' and response.message or 'Library request timed out.'})
        return
    end
    cb({ok=true, libraries=response.libraries})
end)

local testEpoch, testAnimation = 0, nil
stopTest = function()
    testEpoch = testEpoch + 1
    if testAnimation then
        StopAnimTask(testAnimation.ped, testAnimation.dict, testAnimation.clip, 2.5)
        testAnimation = nil
    end
end
RegisterNUICallback('strapTest', function(data, cb)
    if not editorOpen or not editorProfile then cb({ok=false}) return end
    stopTest()
    local a = data.removal and editorProfile.removalAnimation or editorProfile.animation
    if not a.enabled then cb({ok=false, message='Animation disabled.'}) return end
    local expected, ped = testEpoch, cache.ped
    RequestAnimDict(a.dict)
    local deadline = GetGameTimer() + 1600
    while not HasAnimDictLoaded(a.dict) and editorOpen and GetGameTimer() < deadline do Wait(0) end
    if not editorOpen or not HasAnimDictLoaded(a.dict) or expected ~= testEpoch then cb({ok=false}) return end
    testAnimation = {ped=ped, dict=a.dict, clip=a.clip}
    TaskPlayAnim(ped, a.dict, a.clip, 8.0,-8.0,a.durationMs,48,0.0,false,false,false)
    SetEntityAnimSpeed(ped,a.dict,a.clip,a.speed)
    RemoveAnimDict(a.dict)
    SetTimeout(a.durationMs + 100, function() if expected == testEpoch then stopTest() end end)
    cb({ok=true})
end)

RegisterNUICallback('strapSave', function(data, cb)
    if not editorOpen or editorSaving then cb({ ok = false }) return end
    if not eligibleVehicle(cache.ped, cache.vehicle) or
        (not LocalPlayer.state.seatbelt and not LocalPlayer.state.harness) then
        closeEditor(true)
        cb({ ok = false })
        return
    end
    if type(data) ~= 'table' then cb({ok=false}) return end
    local profile = Profile.validate(data.profile)
    if not profile and not data.reset then cb({ok=false, message='Invalid profile.'}) return end
    editorSaving = true
    local token = editorToken
    local ok, response = pcall(request, 'rs-seatbelt:server:save',
        {profile=profile, scope=data.scope, reset=data.reset == true})
    if not editorOpen or token ~= editorToken then cb({ok=ok and type(response) == 'table' and response.ok == true}) return end
    editorSaving = false
    if not ok or not acceptProfile(response) then
        cb({ok=false, message=type(response) == 'table' and response.message or 'Save timed out. Reload your saved preset before retrying.'})
        return
    end
    stopTest()
    closeEditor(true)
    cb({ok=true})
    lib.notify({description=data.scope == 'server' and 'Server default published.' or data.reset and 'Using the server default.' or 'Personal preset saved.', type='success'})
end)

RegisterNUICallback('strapClose', function(_, cb)
    stopTest()
    closeEditor(true)
    cb({ ok = true })
end)

-- Ask the server for its persisted override on resource startup.
CreateThread(function()
    Wait(1000)
    while not stopped do
        if not editorOpen then
            local ok, response = pcall(request, 'rs-seatbelt:server:profile')
            if ok then acceptProfile(response) end
        end
        Wait(10000)
    end
end)

return BeltVisual
