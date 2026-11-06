-- Server half of the test autopilot (tools/light_test.py, lua/client/RainbowLight_TestPilot.lua).
-- Debug mode only. Commands from a game: module "RainbowLightTest", answer "result" {ok, text}.
if not isDebugEnabled() then return end
if isClient() then return end

local SHEETS = { "lighting_indoor_01", "lighting_indoor_02", "lighting_indoor_03" }

-- a movable lamp tile that gives light (what ISMoveableSpriteProps places as an IsoLightSwitch)
local function findLampSprite()
    for _, sheet in ipairs(SHEETS) do
        for i = 0, 63 do
            local name = sheet .. "_" .. i
            local spr = getSprite(name)
            local props = spr and spr:getProperties()
            if props and spr:getType() == IsoObjectType.lightswitch and props:has("IsMoveAble")
                    and props:has(IsoPropertyType.RED_LIGHT) then
                return name, spr
            end
        end
    end
    return nil
end

local function lampAt(sq)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if instanceof(obj, "IsoLightSwitch") then return obj end
    end
    return nil
end

-- nearest outdoor square with only a floor on it
local function freeSquare(x, y, z)
    local cell = getCell()
    for r = 2, 12 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local sq = cell:getGridSquare(x + dx, y + dy, z)
                    if sq and sq:isOutside() and sq:getFloor() and sq:getObjects():size() == 1 and sq:isFree(false) then
                        return sq
                    end
                end
            end
        end
    end
    return nil
end

local COMMANDS = {}

-- place x y z bulb=<full type>: a lamp near x,y,z, switched on
COMMANDS.place = function(player, args)
    local name, spr = findLampSprite()
    if not name then return false, "no movable lamp sprite found" end
    -- lamps left from an earlier run would light the same squares
    local removed = 0
    for dx = -20, 20 do
        for dy = -20, 20 do
            local s = getCell():getGridSquare(args.x + dx, args.y + dy, args.z)
            local old = s and lampAt(s)
            if old and old:getCanBeModified() then
                s:transmitRemoveItemFromSquare(old)
                removed = removed + 1
            end
        end
    end
    local sq = freeSquare(args.x, args.y, args.z)
    if not sq then return false, "no free outdoor square near " .. args.x .. "," .. args.y end
    local lamp = IsoLightSwitch.new(getCell(), sq, spr, sq:getRoomID())
    lamp:addLightSourceFromSprite()
    lamp:setBulbItemRaw(args.bulb or "Base.LightBulb")
    -- an outdoor square has no grid power: run it like a lamp modified for a full battery
    -- (ISLightActions ModifyLamp + AddBattery), which canSwitchLight accepts without electricity
    lamp:setUseBatteryDirect(true)
    lamp:setHasBattery(true)
    lamp:setPower(1.0)
    lamp:setActivated(true)
    sq:AddSpecialObject(lamp)
    lamp:transmitCompleteItemToClients()
    return true, sq:getX() .. " " .. sq:getY() .. " " .. sq:getZ() .. " sprite=" .. name
        .. " modifiable=" .. tostring(lamp:getCanBeModified()) .. " on=" .. tostring(lamp:isActivated())
        .. " canSwitch=" .. tostring(lamp:canSwitchLight()) .. " removedOld=" .. removed
end

-- bulb x y z bulb=<full type>: put another bulb in, sent to every game like vanilla does
COMMANDS.bulb = function(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    local lamp = sq and lampAt(sq)
    if not lamp then return false, "no lamp" end
    lamp:setBulbItemRaw(args.bulb)
    lamp:setActive(true, true, true)
    lamp:syncCustomizedSettings(nil)
    return true, "bulb=" .. tostring(lamp:getBulbItem())
end

-- give items=<full type>,<full type>,...: into the player's inventory, sent to the game
COMMANDS.give = function(player, args)
    local inv = player:getInventory()
    local given = {}
    for t in string.gmatch(tostring(args.items or ""), "[^,]+") do
        local item = inv:AddItem(t)
        if item then
            sendAddItemToContainer(inv, item)
            table.insert(given, t)
        end
    end
    return true, "gave " .. #given .. ": " .. table.concat(given, ",")
end

-- strip: take every light bulb (any color, rainbow too) and screwdriver out of the inventory
COMMANDS.strip = function(player, args)
    local inv = player:getInventory()
    local items = inv:getItems()
    local removed = 0
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if string.sub(item:getType(), 1, 9) == "LightBulb" or item:hasTag(ItemTag.SCREWDRIVER) then
            inv:Remove(item)
            sendRemoveItemFromContainer(inv, item)
            removed = removed + 1
        end
    end
    return true, "removed " .. removed
end

-- night hour=<h>: server clock
COMMANDS.night = function(player, args)
    getGameTime():setTimeOfDay(args.hour or 23)
    return true, "time=" .. string.format("%.2f", getGameTime():getTimeOfDay())
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "RainbowLightTest" then return end
    local fn = COMMANDS[command]
    local ok, done, text
    if fn then
        ok, done, text = pcall(fn, player, args or {})
        if not ok then done, text = false, tostring(done) end
    else
        done, text = false, "unknown command " .. tostring(command)
    end
    print("[RainbowLight][TEST] " .. tostring(command) .. " -> " .. tostring(done) .. " " .. tostring(text))
    sendServerCommand(player, "RainbowLightTest", "result", { ok = done, text = text })
end)
