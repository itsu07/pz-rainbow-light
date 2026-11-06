-- Debug-mode menu for trying out lamp colors. Right-click a lamp >
-- "RainbowLight (debug)". Single player: "make this lamp rainbow" and
-- "give rainbow bulb" change things only on this client.
-- Results of "print info" go to console.txt as "[RainbowLight] ...".
if not isDebugEnabled() then return end

require "RainbowLight_Client"

local COLORS = {
    { "red", 1, 0, 0 },
    { "green", 0, 1, 0 },
    { "blue", 0, 0, 1 },
    { "white", 1, 1, 1 },
}

local function findLamp(worldobjects)
    for _, o in ipairs(worldobjects) do
        local sq = o:getSquare()
        if sq then
            local objects = sq:getObjects()
            for i = 0, objects:size() - 1 do
                local obj = objects:get(i)
                if instanceof(obj, "IsoLightSwitch") then return obj end
            end
        end
    end
    return nil
end

local function printInfo(lamp)
    print(string.format("[RainbowLight] bulb=%s on=%s canBeModified=%s r=%.2f g=%.2f b=%.2f refresh=%s paused=%s lampsNearby=%d",
        tostring(lamp:getBulbItem()), tostring(lamp:isActivated()), tostring(lamp:getCanBeModified()),
        lamp:getPrimaryR(), lamp:getPrimaryG(), lamp:getPrimaryB(),
        RainbowLight.REFRESH, tostring(RainbowLight.paused), RainbowLight.lampCount()))
end

local function setColor(lamp, refresh, r, g, b)
    local saved = RainbowLight.REFRESH
    RainbowLight.REFRESH = refresh
    RainbowLight.setColor(lamp, r, g, b)
    RainbowLight.REFRESH = saved
    printInfo(lamp)
end

local function makeRainbow(lamp)
    lamp:setBulbItemRaw(RainbowLight.BULB)
    printInfo(lamp)
end

local function giveBulb(player)
    player:getInventory():AddItem(RainbowLight.BULB)
end

local function toggleRefresh()
    RainbowLight.REFRESH = RainbowLight.REFRESH == "none" and "switch" or "none"
    print("[RainbowLight] refresh=" .. RainbowLight.REFRESH)
end

local function togglePause()
    RainbowLight.paused = not RainbowLight.paused
    print("[RainbowLight] paused=" .. tostring(RainbowLight.paused))
end

local function setSpeed(period, interval)
    RainbowLight.PERIOD_MS = period
    RainbowLight.UPDATE_MS = interval
    print("[RainbowLight] period=" .. period .. "ms update=" .. interval .. "ms")
end

local function setExtras(n)
    RainbowLight.EXTRA_LIGHTS = n
    RainbowLight.rebuildExtras()
    print("[RainbowLight] extra lights=" .. n .. " (" .. RainbowLight.extraCount() .. " made)")
end

local function onFill(playerNum, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerNum)
    local lamp = findLamp(worldobjects)
    local option = context:addOption("RainbowLight (debug)")
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)

    if lamp then
        for _, c in ipairs(COLORS) do
            sub:addOption("color only: " .. c[1], lamp, setColor, "none", c[2], c[3], c[4])
        end
        for _, c in ipairs(COLORS) do
            sub:addOption("color + switchLight: " .. c[1], lamp, setColor, "switch", c[2], c[3], c[4])
        end
        sub:addOption("make this lamp rainbow", lamp, makeRainbow)
        sub:addOption("print info", lamp, printInfo)
    end
    sub:addOption("refresh while cycling: " .. RainbowLight.REFRESH .. " (toggle)", nil, toggleRefresh)
    sub:addOption(RainbowLight.paused and "resume cycling" or "pause cycling", nil, togglePause)
    sub:addOption("speed: normal (4 s loop, every frame)", nil, setSpeed, 4000, 0)
    sub:addOption("speed: fast, default (2 s loop, every frame)", nil, setSpeed, 2000, 0)
    sub:addOption("speed: slow (12 s loop, every 250 ms)", nil, setSpeed, 12000, 250)
    for n = 0, 2 do
        sub:addOption("extra lights: " .. n .. (n == RainbowLight.EXTRA_LIGHTS and " (now)" or ""), nil, setExtras, n)
    end
    sub:addOption("give rainbow bulb", player, giveBulb)
end

Events.OnFillWorldObjectContextMenu.Add(onFill)
