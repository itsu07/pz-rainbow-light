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

-- cars from earlier runs within 40 squares (their headlights would light the measurements)
local function removeCars(x, y)
    local old = {}
    local it = getCell():getVehicles():iterator()
    while it:hasNext() do
        local v = it:next()
        if math.abs(v:getX() - x) < 40 and math.abs(v:getY() - y) < 40 then table.insert(old, v) end
    end
    for _, v in ipairs(old) do v:permanentlyRemove() end
    return #old
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
    local cars = removeCars(args.x, args.y)
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
        .. " canSwitch=" .. tostring(lamp:canSwitchLight()) .. " removedOld=" .. removed .. " removedCars=" .. cars
end

-- placeroom x y z bulb=<full type>: a lamp in the roomiest room square near x,y,z (only a floor on
-- it, 15+ squares of the same room 2 to 5 squares away), switched on like "place".
-- Answer: "lx ly lz sx sy inRoom=N other=N" with sx,sy a free square of the room next to the lamp
COMMANDS.placeroom = function(player, args)
    local name, spr = findLampSprite()
    if not name then return false, "no movable lamp sprite found" end
    local cell = getCell()
    local best, bestN, bestOther = nil, 14, 0
    for dx = -45, 45 do
        for dy = -45, 45 do
            local sq = cell:getGridSquare(args.x + dx, args.y + dy, args.z)
            local room = sq and sq:getRoom()
            if room and sq:getFloor() and sq:getObjects():size() == 1 and sq:isFree(false) then
                local n, other = 0, 0
                for ex = -5, 5 do
                    for ey = -5, 5 do
                        local d = math.sqrt(ex * ex + ey * ey)
                        if d <= 5.5 then
                            local s = cell:getGridSquare(sq:getX() + ex, sq:getY() + ey, args.z)
                            if s and s:getRoom() == room then
                                if d >= 2 and s:getFloor() then n = n + 1 end
                            else
                                other = other + 1
                            end
                        end
                    end
                end
                if n > bestN then best, bestN, bestOther = sq, n, other end
            end
        end
    end
    if not best then return false, "no roomy room near " .. args.x .. "," .. args.y end
    local removed = 0
    for _, c in ipairs({ { args.x, args.y }, { best:getX(), best:getY() } }) do
        for dx = -20, 20 do
            for dy = -20, 20 do
                local s = cell:getGridSquare(c[1] + dx, c[2] + dy, args.z)
                local old = s and lampAt(s)
                if old and old:getCanBeModified() then
                    s:transmitRemoveItemFromSquare(old)
                    removed = removed + 1
                end
            end
        end
    end
    local cars = removeCars(best:getX(), best:getY())
    local stand
    for _, o in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
        local s = cell:getGridSquare(best:getX() + o[1], best:getY() + o[2], args.z)
        if not stand and s and s:getRoom() == best:getRoom() and s:isFree(false) then stand = s end
    end
    stand = stand or best
    local lamp = IsoLightSwitch.new(cell, best, spr, best:getRoomID())
    lamp:addLightSourceFromSprite()
    lamp:setBulbItemRaw(args.bulb or "Base.LightBulb")
    lamp:setUseBatteryDirect(true)
    lamp:setHasBattery(true)
    lamp:setPower(1.0)
    lamp:setActivated(true)
    best:AddSpecialObject(lamp)
    lamp:transmitCompleteItemToClients()
    return true, best:getX() .. " " .. best:getY() .. " " .. best:getZ() .. " " .. stand:getX() .. " " .. stand:getY()
        .. " inRoom=" .. bestN .. " other=" .. bestOther .. " room=" .. tostring(best:getRoom():getName())
        .. " on=" .. tostring(lamp:isActivated()) .. " removedOld=" .. removed .. " removedCars=" .. cars
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

-- ---------- headlights ----------

-- outdoor squares nothing stands on (grass and the like are fine), around the middle square
local function clearArea(cx, cy, z, hw, hh)
    local cell = getCell()
    for dx = -hw, hw do
        for dy = -hh, hh do
            local sq = cell:getGridSquare(cx + dx, cy + dy, z)
            if not (sq and sq:isOutside() and sq:getFloor() and sq:isFree(false)) then
                return false
            end
        end
    end
    return true
end

-- car x y z [script=Base.CarNormal]: cars from earlier runs within 40 squares are removed, a new
-- one facing east is put on open ground near x,y (room for the car and a few squares around it),
-- repaired (full battery) with headlights off
COMMANDS.car = function(player, args)
    local cars = removeCars(args.x, args.y)
    -- lamps from earlier runs (a rainbow one would color the measurements)
    local lamps = 0
    for dx = -30, 30 do
        for dy = -30, 30 do
            local s = getCell():getGridSquare(args.x + dx, args.y + dy, args.z)
            local lamp = s and lampAt(s)
            if lamp and lamp:getCanBeModified() then
                s:transmitRemoveItemFromSquare(lamp)
                lamps = lamps + 1
            end
        end
    end
    local spot
    for r = 0, 30 do
        for dx = -r, r do
            for dy = -r, r do
                if not spot and (math.abs(dx) == r or math.abs(dy) == r)
                        and clearArea(args.x + dx, args.y + dy, args.z, 5, 2) then
                    spot = getCell():getGridSquare(args.x + dx, args.y + dy, args.z)
                end
            end
        end
        if spot then break end
    end
    if not spot then return false, "no open ground near " .. args.x .. "," .. args.y end
    local v = addVehicleDebug(args.script or "Base.CarNormal", IsoDirections.E, nil, spot)
    if not v then return false, "addVehicleDebug gave nothing" end
    v:repair()
    v:setHeadlightsOn(false)
    return true, v:getId() .. " " .. spot:getX() .. " " .. spot:getY() .. " " .. spot:getZ()
        .. " removedOld=" .. cars .. " removedLamps=" .. lamps .. " script=" .. tostring(v:getScriptName())
end

-- lights id=<vehicle id> on=1|0
-- The beams follow headlightsOn only while the car updates its parts (Vehicles.Update.Headlight,
-- normally while someone drives); nobody is in the test car, so the lights are set here too.
COMMANDS.lights = function(player, args)
    local v = getVehicleById(args.id)
    if not v then return false, "no vehicle " .. tostring(args.id) end
    v:setHeadlightsOn(args.on == 1)
    for _, name in ipairs({ "HeadlightLeft", "HeadlightRight" }) do
        local part = v:getPartById(name)
        if part and part:getLight() then part:setLightActive(args.on == 1) end
    end
    return true, "headlightsOn=" .. tostring(v:getHeadlightsOn()) .. " battery=" .. string.format("%.2f", v:getBatteryCharge())
end

-- mark id=<vehicle id> on=1|0: the rainbow mark on both front headlights, sent to every game
COMMANDS.mark = function(player, args)
    local v = getVehicleById(args.id)
    if not v then return false, "no vehicle " .. tostring(args.id) end
    local done = {}
    for _, name in ipairs({ "HeadlightLeft", "HeadlightRight" }) do
        local part = v:getPartById(name)
        if part then
            part:getModData().RainbowLight = (args.on == 1) or nil
            v:transmitPartModData(part)
            table.insert(done, name)
        end
    end
    return true, "marked " .. table.concat(done, ",") .. " on=" .. tostring(args.on)
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
