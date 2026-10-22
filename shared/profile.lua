local P = {}
local cfg = require 'config.client'
local limits = { x=.35, y=.35, z=.35, rx=180, ry=180, rz=180 }

local function finite(n, lo, hi)
    return type(n) == 'number' and n == n and n >= lo and n <= hi
end
local function asset(s, max)
    return type(s) == 'string' and #s > 0 and #s <= max and not s:find('[%s%c:]')
end
local function animation(a)
    if type(a) ~= 'table' or not asset(a.dict, 180) or not asset(a.clip, 100) or
        not finite(a.durationMs, 100, 5000) or not finite(a.speed, .1, 3) then return end
    return { dict=a.dict, clip=a.clip, durationMs=math.floor(a.durationMs), speed=a.speed,
        enabled=a.enabled ~= false }
end
function P.validate(raw)
    if type(raw) ~= 'table' or not asset(raw.model, 100) or
        not finite(raw.bone, 0, 65535) or raw.bone % 1 ~= 0 then return end
    local out = { model=raw.model, bone=raw.bone }
    for key, limit in pairs(limits) do
        if not finite(raw[key], -limit, limit) then return end
        out[key] = math.floor(raw[key] * 1000 + .5) / 1000
    end
    out.animation, out.removalAnimation = animation(raw.animation), animation(raw.removalAnimation)
    if not out.animation or not out.removalAnimation then return end
    return out
end
function P.copy(p)
    return P.validate(p)
end
function P.validModel(name) return asset(name, 100) end
function P.validAnimation(value) return animation(value) end
function P.defaults()
    local v = cfg.visual
    local p = { model=v.model, bone=v.attachment.bone,
        animation=v.animation, removalAnimation=v.removalAnimation }
    for key in pairs(limits) do p[key] = v.attachment[key] end
    local valid = P.validate(p)
    assert(valid, 'Invalid default RS Seatbelt profile')
    return valid
end
function P.merge(personal, server, mode)
    if not personal or mode == 'server' then return P.copy(server) end
    if mode == 'full' then return P.copy(personal) end
    local p = P.copy(server)
    for key in pairs(limits) do p[key] = personal[key] end
    return p
end
function P.allowed(p, config)
    local function contains(list, value)
        if #list == 0 then return true end
        for _, name in ipairs(list) do if name == value then return true end end
        return false
    end
    return contains(config.allowedModels, p.model) and
        contains(config.allowedDictionaries, p.animation.dict) and
        contains(config.allowedDictionaries, p.removalAnimation.dict)
end
return P
