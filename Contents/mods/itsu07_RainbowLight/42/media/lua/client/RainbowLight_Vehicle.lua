-- Rainbow headlights (prototype). A headlight part whose modData has RAINBOW_KEY set
-- cycles its beam color like the rainbow lamps.
--
-- How the color reaches the screen (42.21): flashlights and vehicle lights are "torches".
-- LightingJNI rebuilds every torch on each lighting update (checkTorch(VehiclePart, id)),
-- and IsoGameCharacter.TorchInfo.set(VehiclePart) reads the part's VehicleLight r, g, b
-- every time. Lua cannot write those fields, but VehiclePart:createSpotLightColor sets
-- them together with the other spot light values (vanilla uses it for the red rear
-- lights in VehicleUtils.initHeadlight). VehicleLight.save does not keep the color, so
-- this is in this game only and nothing is saved, like the lamps.
--
-- How a part gets marked is not decided yet; for now the debug menu and the test set it.

require "RainbowLight_Client"

RainbowLight.RAINBOW_KEY = "RainbowLight"
RainbowLight.HEADLIGHT_PARTS = { "HeadlightLeft", "HeadlightRight" }

-- the color VehicleLight starts with (zombie/vehicles/VehicleLight)
local DEFAULT_R, DEFAULT_G, DEFAULT_B = 1.0, 0.8235294, 0.7058824

local paramsCache = {}   -- "<script>|<part>" -> spot light values as VehicleUtils.initHeadlight makes them
local colored = {}       -- "<vehicle id>|<part>" -> part, parts this file has colored

-- the same values VehicleUtils.initHeadlight (lua/server/Vehicles/Vehicles.lua) passes to
-- createSpotLight, so only the color changes
local function spotParams(vehicle, part)
    local key = vehicle:getScriptName() .. "|" .. part:getId()
    local p = paramsCache[key]
    if p then return p end
    p = { x = 0.5, y = 2.0, dist = 36, intensity = 0.75, dot = 0.75 }
    local t = part:getTable("headlight")
    if t then
        p.x = tonumber(t.xOffset) or p.x
        p.y = tonumber(t.yOffset) or p.y
        p.dist = tonumber(t.distance) or p.dist
        p.intensity = tonumber(t.intensity) or p.intensity
        p.dot = tonumber(t.dot) or p.dot
    end
    if part:getId() == "HeadlightRight" then p.x = -p.x end
    paramsCache[key] = p
    return p
end

-- focusing is not used by the game (VehiclePart.getLightFocusing works it out from the condition)
function RainbowLight.setHeadlightColor(vehicle, part, r, g, b)
    local p = spotParams(vehicle, part)
    part:createSpotLightColor(p.x, p.y, p.dist, p.intensity, p.dot, 0, r, g, b)
end

function RainbowLight.isRainbowHeadlight(part)
    return part ~= nil and part:getLight() ~= nil and part:getModData()[RainbowLight.RAINBOW_KEY] == true
end

local function forEachVehicle(fn)
    local cell = getCell()
    if not cell then return end
    local it = cell:getVehicles():iterator()
    while it:hasNext() do fn(it:next()) end
end

-- every rainbow headlight around shows r, g, b; parts that stopped being rainbow get the
-- normal color back
function RainbowLight.colorHeadlights(r, g, b)
    local seen = {}
    forEachVehicle(function(vehicle)
        if vehicle:getHeadlightsOn() then
            for _, id in ipairs(RainbowLight.HEADLIGHT_PARTS) do
                local part = vehicle:getPartById(id)
                if RainbowLight.isRainbowHeadlight(part) then
                    local key = vehicle:getId() .. "|" .. id
                    RainbowLight.setHeadlightColor(vehicle, part, r, g, b)
                    colored[key] = { vehicle = vehicle, part = part }
                    seen[key] = true
                end
            end
        end
    end)
    for key, c in pairs(colored) do
        if not seen[key] then
            if c.part:getLight() then
                RainbowLight.setHeadlightColor(c.vehicle, c.part, DEFAULT_R, DEFAULT_G, DEFAULT_B)
            end
            colored[key] = nil
        end
    end
end

function RainbowLight.coloredHeadlightCount()
    local n = 0
    for _ in pairs(colored) do n = n + 1 end
    return n
end

Events.OnTick.Add(function()
    if RainbowLight.paused then return end
    local now = getTimestampMs()
    RainbowLight.colorHeadlights(RainbowLight.hueToRGB((now % RainbowLight.PERIOD_MS) / RainbowLight.PERIOD_MS))
end)
