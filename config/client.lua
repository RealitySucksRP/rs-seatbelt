return {
    keybind = 'B', -- Keybind to toggle seatbelt (https://docs.fivem.net/docs/game-references/input-mapper-parameter-ids/keyboard/)
	useMPH = true, -- Use MPH instead of KMH
	minSpeedUnbuckled = 20.0, -- Minimum speed to fly through windscreen when seatbelt is off
	minSpeedBuckled = 160.0, -- Minimum speed to fly through windscreen when seatbelt is on
    harness = {
        disableFlyingThroughWindscreen = true, -- Disable flying through windscreen when harness is on
        minSpeed = 200.0 -- If the above is set to false, minimum speed to fly through windscreen when harness is on
    },
    -- Native buckle/unbuckle sounds remain untouched and working. The audio-only
    -- enhancement layers clearer clicks on top, at configurable local volume.
    sounds = {
        enhanced = true,
        buckleVolume = 0.68, -- 0.0-1.0; enhanced sound added to the native sound
        unbuckleVolume = 0.65
    },
    -- GTA V bag strap styled as a seatbelt. These offsets are initial calibration
    -- values and may need in-game adjustment for different ped body types.
    visual = {
        enabled = true,
        model = 'prop_cs_heist_bag_strap_01',
        showOnOtherPlayers = true, -- OneSync observers; props are local to each client
        iconEnabled = true, -- Supplied right-center fading seatbelt icon
        assetTimeoutMs = 1600, -- Never block a seatbelt toggle awaiting the prop/anim
        streamingDistance = 85.0,
        observerIntervalMs = 750,
        -- The native model is a bag strap, NOT a dedicated seatbelt model.
        -- Left shoulder toward right hip initial estimate. Calibrate via /rsbeltalign.
        -- These are deliberately editable; the GTA bag prop is not a true seatbelt mesh.
        attachment = {
            bone = 24817, -- SKEL_Spine2
            x = 0.015, y = 0.095, z = -0.065,
            rx = 90.0, ry = -8.0, rz = -38.0
        },
        animation = {
            enabled = true,
            dict = 'oddjobs@basejump@ig_15',
            clip = 'puton_parachute',
            durationMs = 520, -- Cut off gesture early for rapid entry/exit
            speed = 1.85 -- Faster upper-body motion while remaining seated
        },
        removalAnimation = {
            enabled = true, dict = 'missfam3', clip = 'react_incar_brace_enter_f',
            durationMs = 430, speed = 1.7
        },
        alignmentCamera = {
            -- Opens above and in front of the left shoulder instead of inside the ped.
            -- Rotate/zoom with the gizmo editor; these values affect only initial/reset camera.
            yaw = 38.0, pitch = 12.0, distance = 1.85,
            minDistance = 0.48, maxDistance = 3.2,
            fov = 38.0, height = 0.18
        }
    },
    reminder = {
        enabled = true,
        delayMs = 3500, -- Time after engine starts / front seat becomes eligible
        intervalMs = 7000, -- Time between two-beep alerts
        volume = 0.52, -- 0.0-1.0
        driversOnly = false, -- false: driver and front passenger
        frontSeatsOnly = true, -- true: no rear-seat reminder
        minSpeed = 0.0 -- MPH if useMPH=true; otherwise km/h (0 means even at idle)
    }
}
