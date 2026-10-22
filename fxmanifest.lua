fx_version 'cerulean'
game 'gta5'

name 'RS Seatbelt'
author 'RealitySucksRP; derived from Qbox-project/qbx_seatbelt'
description 'Framework-bridged seatbelt and harness with live personal and server-wide presets'
version '1.1.1'

ox_lib 'locale'
shared_script '@ox_lib/init.lua'

client_scripts {
    'client/main.lua'
}

server_script 'server/main.lua'

-- Transparent, non-interactive NUI for the original sounds and seatbelt indicator.
ui_page 'html/index.html'

files {
    'locales/*.json',
    'html/index.html',
    'html/audio.js',
    'html/editor.js',
    -- Explicitly stream ES modules to FiveM NUI (wildcard registration was unreliable).
    'html/vendor/three.core.js',
    'html/vendor/three.module.js',
    'html/vendor/TransformControls.js',
    'html/seatbelt-icon.png',
    'client/visual.lua',
    'client/rpc.lua',
    'shared/profile.lua',
    'shared/library.lua',
    'html/sounds/*.wav',
    'config/*.lua',
    'audiodirectory/seatbelt_sounds.awc',
    'data/seatbelt_sounds.dat54.rel'
}

data_file 'AUDIO_WAVEPACK' 'audiodirectory'
data_file 'AUDIO_SOUNDDATA' 'data/seatbelt_sounds.dat'

-- Lua 5.4 is the current default; avoid experimental OAL native behavior.

dependency 'ox_lib'
