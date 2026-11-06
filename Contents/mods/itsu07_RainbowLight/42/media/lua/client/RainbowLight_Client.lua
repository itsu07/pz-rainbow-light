-- Lamps with a rainbow bulb cycle their light color.
--
-- How the color reaches the screen (zombie/iso/IsoLightSwitch, LightingJNI in
-- 42.21): the lamp's IsoLightSource holds r, g, b; setPrimaryR/G/B writes them,
-- and LightingJNI.checkLights compares them with the last values sent to the
-- native lighting every update and calls setLightColor when they differ. So
-- writing the color is enough, but tools/light_test.py measured that the light
-- on screen then follows 0.6 to 4 s late and in jumps. REFRESH = "switch" also
-- calls switchLight, which is what vanilla does after receiving new lamp
-- settings (SyncCustomLightSettingsPacket.processClient); the light then
-- follows in about 0.1 s.
--
-- Deeper color: one light is capped (LightingJNI sends clamp(r * 2) to the
-- native lighting, so even a white bulb is at the cap) and the moon and other
-- ambient light whiten it. EXTRA_LIGHTS adds more lights of the same color on
-- the lamp's square (IsoCell:addLamppost), in this game only.
--
-- Visual only, so every client does it for itself around its own player, with
-- no network traffic. Players are not kept in step.

RainbowLight = RainbowLight or {}
RainbowLight.BULB = "RainbowLight.LightBulbRainbow"
RainbowLight.PERIOD_MS = 2000       -- one full trip around the rainbow
RainbowLight.UPDATE_MS = 0          -- how often the color is changed; 0 = every frame
RainbowLight.REFRESH = "switch"     -- "switch" or "none" (see above)
RainbowLight.EXTRA_LIGHTS = 2       -- extra lights of the same color per lamp (light_test.py: a third one adds nothing)
RainbowLight.EXTRA_RADIUS = 0       -- their radius; 0 = the lamp's own
RainbowLight.paused = false

local SCAN_RADIUS = 20
local SCAN_INTERVAL_MS = 1000
local lastScan = 0
local lastUpdate = 0
local lamps = {}
local extras = {}   -- "x,y,z" -> { lamp = IsoLightSwitch, lights = { IsoLightSource ... } }

-- hue 0..1 to r, g, b 0..1 (full saturation and brightness)
function RainbowLight.hueToRGB(h)
    h = (h % 1) * 6
    local i = math.floor(h)
    local f = h - i
    if i == 0 then return 1, f, 0
    elseif i == 1 then return 1 - f, 1, 0
    elseif i == 2 then return 0, 1, f
    elseif i == 3 then return 0, 1 - f, 1
    elseif i == 4 then return f, 0, 1
    else return 1, 0, 1 - f end
end

function RainbowLight.isRainbowLamp(obj)
    return instanceof(obj, "IsoLightSwitch") and obj:getBulbItem() == RainbowLight.BULB
end

local function isLit(lamp)
    return lamp:getSquare() and lamp:isActivated() and lamp:getBulbItem() == RainbowLight.BULB
end

local function keyOf(lamp)
    return lamp:getX() .. "," .. lamp:getY() .. "," .. lamp:getZ()
end

local function lampRadius(lamp)
    local list = lamp:getLights()
    if list and list:size() > 0 then return list:get(0):getRadius() end
    return 8
end

local function removeExtras(key)
    local e = extras[key]
    if not e then return end
    for _, light in ipairs(e.lights) do
        getCell():removeLamppost(light)
    end
    extras[key] = nil
end

-- the game drops a light by itself when its square leaves the loaded area, so
-- lights that are no longer registered are made again
local function ensureExtras(lamp)
    local key = keyOf(lamp)
    local e = extras[key]
    if e and e.lamp ~= lamp then removeExtras(key) e = nil end
    if RainbowLight.EXTRA_LIGHTS <= 0 then
        if e then removeExtras(key) end
        return
    end
    e = e or { lamp = lamp, lights = {} }
    extras[key] = e
    local registered = getCell():getLamppostPositions()
    local keep = {}
    for _, light in ipairs(e.lights) do
        if #keep < RainbowLight.EXTRA_LIGHTS and registered:contains(light) then
            table.insert(keep, light)
        else
            getCell():removeLamppost(light)
        end
    end
    local radius = RainbowLight.EXTRA_RADIUS > 0 and RainbowLight.EXTRA_RADIUS or lampRadius(lamp)
    while #keep < RainbowLight.EXTRA_LIGHTS do
        table.insert(keep, getCell():addLamppost(lamp:getX(), lamp:getY(), lamp:getZ(),
            lamp:getPrimaryR(), lamp:getPrimaryG(), lamp:getPrimaryB(), radius))
    end
    e.lights = keep
end

function RainbowLight.setColor(lamp, r, g, b)
    lamp:setPrimaryR(r)
    lamp:setPrimaryG(g)
    lamp:setPrimaryB(b)
    local e = extras[keyOf(lamp)]
    if e then
        for _, light in ipairs(e.lights) do
            light:setR(r)
            light:setG(g)
            light:setB(b)
        end
    end
    if RainbowLight.REFRESH == "switch" and lamp:isActivated() then
        lamp:switchLight(true)
    end
end

-- every rainbow lamp around shows hue h (0..1)
function RainbowLight.applyHue(h)
    local r, g, b = RainbowLight.hueToRGB(h)
    for _, lamp in ipairs(lamps) do
        if isLit(lamp) then RainbowLight.setColor(lamp, r, g, b) end
    end
end

-- after changing EXTRA_LIGHTS or EXTRA_RADIUS
function RainbowLight.rebuildExtras()
    for key, _ in pairs(extras) do removeExtras(key) end
    for _, lamp in ipairs(lamps) do
        if isLit(lamp) then ensureExtras(lamp) end
    end
end

local function scan()
    lamps = {}
    local player = getSpecificPlayer(0)
    if not player then return end
    local cell = getCell()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for z = pz - 1, pz + 1 do
        for x = px - SCAN_RADIUS, px + SCAN_RADIUS do
            for y = py - SCAN_RADIUS, py + SCAN_RADIUS do
                local sq = cell:getGridSquare(x, y, z)
                if sq then
                    local objects = sq:getObjects()
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if RainbowLight.isRainbowLamp(obj) then
                            table.insert(lamps, obj)
                        end
                    end
                end
            end
        end
    end
    -- extra lights only for lamps that are around and lit
    local wanted = {}
    for _, lamp in ipairs(lamps) do
        if isLit(lamp) then
            wanted[keyOf(lamp)] = true
            ensureExtras(lamp)
        end
    end
    for key, _ in pairs(extras) do
        if not wanted[key] then removeExtras(key) end
    end
end

local function update(now)
    local r, g, b = RainbowLight.hueToRGB((now % RainbowLight.PERIOD_MS) / RainbowLight.PERIOD_MS)
    for _, lamp in ipairs(lamps) do
        -- the lamp may have been switched off, picked up or had its bulb taken out since the scan
        if isLit(lamp) then
            RainbowLight.setColor(lamp, r, g, b)
        elseif extras[keyOf(lamp)] then
            removeExtras(keyOf(lamp))
        end
    end
end

local function onTick()
    local now = getTimestampMs()
    if now - lastScan >= SCAN_INTERVAL_MS then
        lastScan = now
        scan()
    end
    if RainbowLight.paused or now - lastUpdate < RainbowLight.UPDATE_MS then return end
    lastUpdate = now
    update(now)
end

-- for lua/client/RainbowLight_Debug.lua and RainbowLight_TestPilot.lua
RainbowLight.lampCount = function() return #lamps end
RainbowLight.extraCount = function()
    local n = 0
    for _, e in pairs(extras) do n = n + #e.lights end
    return n
end

Events.OnTick.Add(onTick)
