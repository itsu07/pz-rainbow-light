if not isDebugEnabled() then return end
-- Test autopilot for tools/light_test.py. Does nothing unless the game runs with -debug AND
-- <cachedir>\Lua\RainbowLight_pilot.txt exists (light_test.py writes it only into its own test folder).
-- Main menu: connects to the test server by itself (same way as CheeseMaking_DebugPilot.lua).
-- In game: runs commands from RainbowLight_pilot_cmd.txt, answers in RainbowLight_pilot_out.txt.

require "RainbowLight_Client"
require "RainbowLight_Vehicle"
require "RainbowLight_MirrorBall"

local TAG = "[RainbowLight][PILOT] "

local function readConfig()
    local reader = getFileReader("RainbowLight_pilot.txt", false)
    if not reader then return nil end
    local cfg = {}
    while true do
        local line = reader:readLine()
        if line == nil then break end
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then cfg[k] = v end
    end
    reader:close()
    return cfg
end

local cfg = readConfig()
if not cfg or not cfg.user then return end

local function status(state, extra)
    local w = getFileWriter("RainbowLight_pilot_status.txt", true, false)
    if w then
        w:write(state .. "|" .. tostring(getTimestampMs()) .. "|" .. tostring(extra or "") .. "\n")
        w:close()
    end
    print(TAG .. "status " .. state .. (extra and (" " .. tostring(extra)) or ""))
end

-- ---------- main menu: connect ----------

local firstTick, lastTry = nil, nil
local connected = false

local function visible(ui)
    return ui and ui.isVisible and ui:isVisible()
end

local function passCreationScreens()
    local ms = MainScreen and MainScreen.instance
    if not ms then return end
    local next = { internal = "NEXT" }
    if MapSpawnSelect and MapSpawnSelect.instance and visible(MapSpawnSelect.instance) then
        MapSpawnSelect.instance:onOptionMouseDown(next)
    elseif WorldSelect and WorldSelect.instance and visible(WorldSelect.instance) then
        WorldSelect.instance:onOptionMouseDown(next)
    elseif visible(ms.charCreationProfession) then
        ms.charCreationProfession:onOptionMouseDown(next)
    elseif visible(ms.charCreationMain) then
        ms.charCreationMain:onOptionMouseDown(next)
    end
end

Events.OnFETick.Add(function()
    if isClient() and getPlayer() then return end
    local now = getTimestampMs()
    firstTick = firstTick or now
    if connected then
        passCreationScreens()
        return
    end
    if now - firstTick < 4000 then return end
    if lastTry and now - lastTry < 20000 then return end
    if not (MainScreen and MainScreen.instance and ConnectToServer and ConnectToServer.instance) then return end
    lastTry = now
    status("connecting", cfg.user)
    ConnectToServer.instance:connect(MainScreen.instance, "", cfg.user, cfg.pass or "", cfg.ip or "127.0.0.1", "",
        cfg.port or "16261", "", false, true, 1)
end)

Events.OnConnected.Add(function()
    connected = true
    status("connected", cfg.user)
end)

Events.OnConnectFailed.Add(function(message, detail)
    status("connectfailed", tostring(message) .. " " .. tostring(detail))
end)

Events.OnGameStart.Add(function()
    local p = getPlayer()
    status("ingame", p and (math.floor(p:getX()) .. "," .. math.floor(p:getY()) .. "," .. math.floor(p:getZ())) or "")
end)

-- ---------- in game: commands ----------
-- RainbowLight_pilot_cmd.txt holds one line "<id> <command> <args...>"; output lines
-- "<id>|<kind>|<text>" go to RainbowLight_pilot_out.txt, the last one with kind done or error.

local OUT = "RainbowLight_pilot_out.txt"
local lastId = 0
do
    local r = getFileReader(OUT, false)
    if r then
        while true do
            local line = r:readLine()
            if line == nil then break end
            local id = tonumber(string.match(line, "^(%d+)|"))
            if id and id > lastId then lastId = id end
        end
        r:close()
    end
end

local function out(id, kind, text)
    local w = getFileWriter(OUT, true, true)
    if w then
        w:write(tostring(id) .. "|" .. kind .. "|" .. string.gsub(tostring(text), "[\r\n]", " ") .. "\n")
        w:close()
    end
end

local function readCommand()
    local r = getFileReader("RainbowLight_pilot_cmd.txt", false)
    if not r then return nil end
    local line = r:readLine()
    r:close()
    if not line then return nil end
    local words = {}
    for w in string.gmatch(line, "%S+") do table.insert(words, w) end
    local id = tonumber(words[1])
    if not id or id <= lastId then return nil end
    table.remove(words, 1)
    return id, words
end

local running = nil   -- { id, poll = function() -> true when finished, deadline }

local function finishCmd(kind, text)
    out(running.id, kind, text)
    running = nil
end

local reply = nil
Events.OnServerCommand.Add(function(module, command, args)
    if module == "RainbowLightTest" and command == "result" then reply = args end
end)

local function lampAt(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then return nil end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if instanceof(obj, "IsoLightSwitch") then return obj end
    end
    return nil
end

local function f2(v) return string.format("%.3f", v) end

-- light the player's game draws on the squares around the lamp (lamp square and the 8 next to it)
local function measure(x, y, z)
    local r, g, b, n = 0, 0, 0, 0
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sq = getCell():getGridSquare(x + dx, y + dy, z)
            local c = sq and sq:getLightInfo(0)
            if c then
                r, g, b, n = r + c:getR(), g + c:getG(), b + c:getB(), n + 1
            end
        end
    end
    if n == 0 then return nil end
    return r / n, g / n, b / n
end

-- the same for the ring of squares 3 tiles from the lamp
local function measureRing(x, y, z, d)
    local r, g, b, n = 0, 0, 0, 0
    for dx = -d, d do
        for dy = -d, d do
            if math.abs(dx) == d or math.abs(dy) == d then
                local sq = getCell():getGridSquare(x + dx, y + dy, z)
                local c = sq and sq:getLightInfo(0)
                if c then r, g, b, n = r + c:getR(), g + c:getG(), b + c:getB(), n + 1 end
            end
        end
    end
    if n == 0 then return nil end
    return r / n, g / n, b / n
end

local function describe(x, y, z)
    local lamp = lampAt(x, y, z)
    local text = "light"
    local r, g, b = measure(x, y, z)
    if r then text = text .. " r=" .. f2(r) .. " g=" .. f2(g) .. " b=" .. f2(b) else text = text .. " none" end
    r, g, b = measureRing(x, y, z, 3)
    if r then text = text .. " | 3 tiles r=" .. f2(r) .. " g=" .. f2(g) .. " b=" .. f2(b) end
    text = text .. " | extras=" .. RainbowLight.extraCount()
    if lamp then
        text = text .. " | lamp r=" .. f2(lamp:getPrimaryR()) .. " g=" .. f2(lamp:getPrimaryG()) .. " b=" .. f2(lamp:getPrimaryB())
            .. " bulb=" .. tostring(lamp:getBulbItem()) .. " on=" .. tostring(lamp:isActivated())
            .. " canSwitch=" .. tostring(lamp:canSwitchLight()) .. " modifiable=" .. tostring(lamp:getCanBeModified())
    else
        text = text .. " | no lamp"
    end
    text = text .. " | time=" .. f2(getGameTime():getTimeOfDay())
    return text
end

-- which channels stand out: "red", "green", "blue", "red+blue", ... or "none"
-- (the light values come in steps of about 0.08, so 0.03 separates one step)
local function colorClass(r, g, b)
    if not r then return "?" end
    local low = math.min(r, g, b)
    local names = {}
    if r - low > 0.03 then table.insert(names, "red") end
    if g - low > 0.03 then table.insert(names, "green") end
    if b - low > 0.03 then table.insert(names, "blue") end
    if #names == 0 or #names == 3 then return "none" end
    return table.concat(names, "+")
end

local function wantClass(r, g, b)
    return colorClass(r, g, b)
end

local COMMANDS = {}

-- ui on|off: every UI element (what the game's hide-UI key does)
COMMANDS.ui = function(id, w, p)
    UIManager.setVisibleAllUI(w[2] ~= "off")
    -- the hide-UI switch does not reach these two (seen in the screenshots): close them directly
    if w[2] == "off" then
        if SurvivalGuide and SurvivalGuide.instance then SurvivalGuide.instance:setVisible(false) end
        if ISChat and ISChat.instance then ISChat.instance:setVisible(false) end
    end
    finishCmd("done", "ui " .. w[2])
end

-- settle x y z: wait until the light around the lamp stops changing (night falling), up to 150 s
COMMANDS.settle = function(id, w, p)
    local x, y, z = tonumber(w[2]), tonumber(w[3]), tonumber(w[4])
    local last, since, t0 = nil, getTimestampMs(), getTimestampMs()
    running.deadline = t0 + 160000
    running.poll = function()
        local r, g, b = measure(x, y, z)
        local key = r and (f2(r) .. f2(g) .. f2(b)) or "none"
        local now = getTimestampMs()
        if key ~= last then last, since = key, now end
        -- the light can hold still for a while before night starts falling, so wait 60 s at least
        if now - since >= 15000 and now - t0 >= 60000 then
            finishCmd("done", "stable for 15 s after " .. math.floor((now - t0) / 1000) .. " s: " .. describe(x, y, z))
            return true
        end
        if now - t0 > 150000 then
            finishCmd("done", "still changing after 150 s: " .. describe(x, y, z))
            return true
        end
        return false
    end
end

-- watch none|switch r g b x y z: set the color (cycling paused) and time how long until the light
-- around the lamp shows that color; gives up after 8 s
COMMANDS.watch = function(id, w, p)
    local lamp = lampAt(tonumber(w[6]), tonumber(w[7]), tonumber(w[8]))
    if not lamp then finishCmd("error", "no lamp") return end
    local x, y, z = tonumber(w[6]), tonumber(w[7]), tonumber(w[8])
    local cr, cg, cb = tonumber(w[3]), tonumber(w[4]), tonumber(w[5])
    local want = wantClass(cr, cg, cb)
    RainbowLight.paused = true
    local saved = RainbowLight.REFRESH
    RainbowLight.REFRESH = w[2]
    RainbowLight.setColor(lamp, cr, cg, cb)
    RainbowLight.REFRESH = saved
    local t0 = getTimestampMs()
    running.deadline = t0 + 9000
    running.poll = function()
        local r, g, b = measure(x, y, z)
        local got = colorClass(r, g, b)
        local ms = getTimestampMs() - t0
        if got == want then
            finishCmd("done", "seen " .. want .. " after " .. ms .. " ms: " .. describe(x, y, z))
            return true
        end
        if ms > 8000 then
            finishCmd("done", "not seen " .. want .. " in 8000 ms (got " .. got .. "): " .. describe(x, y, z))
            return true
        end
        return false
    end
end

-- speed <period ms> <update ms>
COMMANDS.speed = function(id, w, p)
    RainbowLight.PERIOD_MS = tonumber(w[2])
    RainbowLight.UPDATE_MS = tonumber(w[3])
    finishCmd("done", "period=" .. RainbowLight.PERIOD_MS .. " update=" .. RainbowLight.UPDATE_MS)
end

-- perf <seconds>: frame rate and the game's CPU time per frame (the numbers of the vanilla
-- debug FPS display, ISEquippedItem), sampled every tick
COMMANDS.perf = function(id, w, p)
    local t0 = getTimestampMs()
    local secs = tonumber(w[2]) or 8
    local n, fps, cpu, cpuMax, fpsMin = 0, 0, 0, 0, 9999
    running.deadline = t0 + secs * 1000 + 5000
    running.poll = function()
        local f, c = getAverageFPS(), getCPUTime()
        n, fps, cpu = n + 1, fps + f, cpu + c
        if c > cpuMax then cpuMax = c end
        if f < fpsMin then fpsMin = f end
        if getTimestampMs() - t0 >= secs * 1000 then
            finishCmd("done", string.format("fps avg=%.1f min=%.1f cpu ms avg=%.2f max=%.2f ticks=%d",
                fps / n, fpsMin, cpu / n, cpuMax, n))
            return true
        end
        return false
    end
end

-- bench <count> x y z: time <count> color changes with switchLight on the lamp, in one go
COMMANDS.bench = function(id, w, p)
    local lamp = lampAt(tonumber(w[3]), tonumber(w[4]), tonumber(w[5]))
    if not lamp then finishCmd("error", "no lamp") return end
    local count = tonumber(w[2])
    local saved = RainbowLight.REFRESH
    local result = {}
    for _, mode in ipairs({ "none", "switch" }) do
        RainbowLight.REFRESH = mode
        local t0 = getTimestampMs()
        for i = 1, count do
            local r, g, b = RainbowLight.hueToRGB(i / count)
            RainbowLight.setColor(lamp, r, g, b)
        end
        table.insert(result, mode .. " " .. (getTimestampMs() - t0) .. " ms")
    end
    RainbowLight.REFRESH = saved
    finishCmd("done", count .. " changes: " .. table.concat(result, ", "))
end

-- extras <n> [radius]: extra lights per rainbow lamp
COMMANDS.extras = function(id, w, p)
    RainbowLight.EXTRA_LIGHTS = tonumber(w[2])
    RainbowLight.EXTRA_RADIUS = tonumber(w[3] or "0")
    RainbowLight.rebuildExtras()
    finishCmd("done", "extras=" .. RainbowLight.EXTRA_LIGHTS .. " radius=" .. RainbowLight.EXTRA_RADIUS
        .. " made=" .. RainbowLight.extraCount())
end

-- hue <0..1>: cycling paused, every rainbow lamp (and its extra lights) shows that hue
COMMANDS.hue = function(id, w, p)
    RainbowLight.paused = true
    RainbowLight.applyHue(tonumber(w[2]))
    finishCmd("done", "hue " .. w[2])
end

-- ---------- crafting (same steps as the crafting window, like CheeseMaking_DebugPilot.lua) ----------

local function craftLogic(player, name)
    local recipe = getScriptManager():getCraftRecipe(name)
    if not recipe then return nil, "recipe not found" end
    local logic = HandcraftLogic.new(player, nil, ISEntityUI.FindCraftSurface(player, 1))
    logic:setManualSelectInputs(true)
    logic:setContainers(ISInventoryPaneContextMenu.getContainers(player))
    logic:setRecipe(recipe)
    logic:autoPopulateInputs()
    return logic, recipe
end

local function countType(player, fullType)
    return player:getInventory():getCountTypeRecurse(fullType)
end

-- count <full type>...: how many of each the player carries
COMMANDS.count = function(id, w, p)
    local parts = {}
    for i = 2, #w do table.insert(parts, w[i] .. "=" .. countType(p, w[i])) end
    finishCmd("done", table.concat(parts, " "))
end

-- cancraft <recipe>: what the crafting window would say
COMMANDS.cancraft = function(id, w, p)
    local logic, recipe = craftLogic(p, w[2])
    if not logic then finishCmd("error", tostring(recipe)) return end
    finishCmd("done", tostring(logic:canPerformCurrentRecipe()))
end

-- craft <recipe>: start the real crafting action and wait until it is over
COMMANDS.craft = function(id, w, p)
    local logic, recipe = craftLogic(p, w[2])
    if not logic then finishCmd("error", tostring(recipe)) return end
    if not logic:canPerformCurrentRecipe() then finishCmd("done", "cannot") return end
    ISTimedActionQueue.add(ISHandcraftAction.FromLogic(logic))
    local started = getTimestampMs()
    running.deadline = started + 60000
    running.poll = function()
        local q = ISTimedActionQueue.getTimedActionQueue(p)
        if q and #q.queue > 0 then return false end
        if getTimestampMs() - started < 2500 then return false end
        finishCmd("done", "finished")
        return true
    end
end

-- class x y z: the color class of the light around the lamp now
COMMANDS.class = function(id, w, p)
    local r, g, b = measure(tonumber(w[2]), tonumber(w[3]), tonumber(w[4]))
    finishCmd("done", colorClass(r, g, b) .. " " .. describe(tonumber(w[2]), tonumber(w[3]), tonumber(w[4])))
end

-- ---------- headlights ----------

-- light on the strip of squares 4 to 9 squares from x,y in direction dx,dy, 3 squares wide
local function measureStrip(x, y, z, dx, dy)
    local r, g, b, n = 0, 0, 0, 0
    for d = 4, 9 do
        for s = -1, 1 do
            local sq = getCell():getGridSquare(x + dx * d + dy * s, y + dy * d + dx * s, z)
            local c = sq and sq:getLightInfo(0)
            if c then r, g, b, n = r + c:getR(), g + c:getG(), b + c:getB(), n + 1 end
        end
    end
    if n == 0 then return nil end
    return r / n, g / n, b / n
end

local DIRS = { E = { 1, 0 }, W = { -1, 0 }, S = { 0, 1 }, N = { 0, -1 } }

-- carlight <vehicle id>: the light on the strips east, west, south and north of the car, and its state
-- "E r=.. g=.. b=.. class | W ... | ... | on=.. battery=.. mark=.. active=.. colored=.. beam r=.."
COMMANDS.carlight = function(id, w, p)
    local v = getVehicleById(tonumber(w[2]))
    if not v then finishCmd("error", "no vehicle " .. tostring(w[2])) return end
    local x, y, z = math.floor(v:getX()), math.floor(v:getY()), math.floor(v:getZ())
    local parts = {}
    for _, name in ipairs({ "E", "W", "S", "N" }) do
        local r, g, b = measureStrip(x, y, z, DIRS[name][1], DIRS[name][2])
        if r then
            table.insert(parts, name .. " r=" .. f2(r) .. " g=" .. f2(g) .. " b=" .. f2(b) .. " " .. colorClass(r, g, b))
        else
            table.insert(parts, name .. " none")
        end
    end
    local left = v:getPartById("HeadlightLeft")
    local state = "on=" .. tostring(v:getHeadlightsOn()) .. " battery=" .. string.format("%.2f", v:getBatteryCharge())
        .. " mark=" .. tostring(RainbowLight.isRainbowHeadlight(left))
        .. " active=" .. tostring(left and left:getLight() and left:getLight():getActive())
        .. " colored=" .. RainbowLight.coloredHeadlightCount()
        .. " at=" .. x .. "," .. y .. " time=" .. f2(getGameTime():getTimeOfDay())
    table.insert(parts, state)
    finishCmd("done", table.concat(parts, " | "))
end

-- carhue <0..1>: cycling paused, every rainbow headlight around shows that hue
COMMANDS.carhue = function(id, w, p)
    RainbowLight.paused = true
    RainbowLight.colorHeadlights(RainbowLight.hueToRGB(tonumber(w[2])))
    finishCmd("done", "hue " .. w[2] .. " colored=" .. RainbowLight.coloredHeadlightCount())
end

-- carsettle <vehicle id>: wait until the light around the car stops changing (night falling)
COMMANDS.carsettle = function(id, w, p)
    local v = getVehicleById(tonumber(w[2]))
    if not v then finishCmd("error", "no vehicle " .. tostring(w[2])) return end
    local x, y, z = math.floor(v:getX()), math.floor(v:getY()), math.floor(v:getZ())
    w = { "settle", tostring(x), tostring(y), tostring(z) }
    COMMANDS.settle(id, w, p)
end

-- ---------- mirror ball ----------

local function brightness(sq)
    local c = sq:getLightInfo(0)
    return (c:getR() + c:getG() + c:getB()) / 3, c
end

-- ball: what the balls around have made
COMMANDS.ball = function(id, w, p)
    local info = RainbowLight.ballInfo()
    finishCmd("done", "balls=" .. info.balls .. " squares=" .. #info.squares .. " lights=" .. info.lights
        .. " lit=" .. info.lit .. " markers=" .. info.markers .. " mode=" .. RainbowLight.BALL_MODE
        .. " paused=" .. tostring(RainbowLight.ballPaused))
end

-- ballmode light|marker
COMMANDS.ballmode = function(id, w, p)
    RainbowLight.BALL_MODE = w[2]
    RainbowLight.rebuildBalls()
    finishCmd("done", "mode=" .. RainbowLight.BALL_MODE)
end

-- balloff: paused, every spot light off (with switchLight)
COMMANDS.balloff = function(id, w, p)
    local ball = RainbowLight.firstBall()
    if not ball or ball.mode ~= "light" then finishCmd("error", "no light-mode ball") return end
    RainbowLight.ballPaused = true
    for _, s in ipairs(ball.squares) do
        if s.on then RainbowLight.ballSetSquare(ball, s, nil, false) end
    end
    ball.lamp:switchLight(true)
    finishCmd("done", "all off")
end

-- ballpause on|off
COMMANDS.ballpause = function(id, w, p)
    RainbowLight.ballPaused = w[2] == "on"
    finishCmd("done", "paused=" .. tostring(RainbowLight.ballPaused))
end

-- ballturn <0..1>: paused, the ball turned to that part of a turn
COMMANDS.ballturn = function(id, w, p)
    RainbowLight.ballPaused = true
    RainbowLight.turnBalls(math.pi * 2 * tonumber(w[2]))
    finishCmd("done", "turn " .. w[2] .. " lit=" .. RainbowLight.ballInfo().lit)
end

-- ballmeasure: light on the spot squares, lit ones against dark ones, and how many lit ones show
-- their spot's color. A spot light reaches the squares next to it, so those count as neither.
COMMANDS.ballmeasure = function(id, w, p)
    local info = RainbowLight.ballInfo()
    local onSum, onN, offSum, offN, match, colored = 0, 0, 0, 0, 0, 0
    local function nextToLit(s)
        for _, o in ipairs(info.squares) do
            if o.on and math.abs(o.x - s.x) <= 1 and math.abs(o.y - s.y) <= 1 then return true end
        end
        return false
    end
    for _, s in ipairs(info.squares) do
        local v, c = brightness(s.sq)
        if s.on then
            onSum, onN = onSum + v, onN + 1
            local want = colorClass(s.color[1], s.color[2], s.color[3])
            if want ~= "none" then
                colored = colored + 1
                if colorClass(c:getR(), c:getG(), c:getB()) == want then match = match + 1 end
            end
        elseif not nextToLit(s) then
            offSum, offN = offSum + v, offN + 1
        end
    end
    finishCmd("done", string.format("lit=%d avg=%.3f dark=%d avg=%.3f colorMatch=%d/%d",
        onN, onN > 0 and onSum / onN or 0, offN, offN > 0 and offSum / offN or 0, match, colored))
end

-- balllatency switch|none: paused; one dark spot square far from lit ones that the player sees
-- (unseen squares read 0) is switched on (white), then off, and the time until its light rises and
-- falls back is taken (8 s at most each)
COMMANDS.balllatency = function(id, w, p)
    local ball = RainbowLight.firstBall()
    if not ball or ball.mode ~= "light" then finishCmd("error", "no light-mode ball") return end
    RainbowLight.ballPaused = true
    local target = nil
    for _, s in ipairs(ball.squares) do
        if not s.on and brightness(s.sq) > 0.05 then
            local alone = true
            for _, o in ipairs(ball.squares) do
                if o.on and math.abs(o.x - s.x) <= 3 and math.abs(o.y - s.y) <= 3 then alone = false break end
            end
            if alone then target = s break end
        end
    end
    if not target then finishCmd("error", "no dark square away from the spots") return end
    local refresh = w[2] == "switch"
    local base = brightness(target.sq)
    RainbowLight.ballSetSquare(ball, target, { 1, 1, 1 }, refresh)
    local t0 = getTimestampMs()
    local phase, upMs, peak = "up", nil, base
    running.deadline = t0 + 20000
    running.poll = function()
        local v = brightness(target.sq)
        local ms = getTimestampMs() - t0
        if phase == "up" then
            if v > peak then peak = v end
            if v > base + 0.1 or ms > 8000 then
                upMs = v > base + 0.1 and ms or -1
                RainbowLight.ballSetSquare(ball, target, nil, refresh)
                phase, t0 = "down", getTimestampMs()
            end
            return false
        end
        if v < base + 0.05 or ms > 8000 then
            finishCmd("done", string.format("%s: on after %s ms, off after %s ms (base=%.3f peak=%.3f at %d,%d)",
                w[2], upMs >= 0 and tostring(upMs) or "never", v < base + 0.05 and tostring(ms) or "never",
                base, peak, target.x, target.y))
            return true
        end
        return false
    end
end

-- ---------- mirror ball in a room ----------

-- spot squares of the ball next to (8 around) a square that is not in the lamp's room, and those
-- outside squares (outdoors, with a floor) that are within 2 of such a spot square
local function wallSides(ball)
    local cell = getCell()
    local room = ball.lamp:getSquare():getRoom()
    local z = ball.lamp:getZ()
    local sides, beyond, seen = {}, {}, {}
    for _, s in ipairs(ball.squares) do
        local side = false
        for dx = -1, 1 do
            for dy = -1, 1 do
                local o = cell:getGridSquare(s.x + dx, s.y + dy, z)
                if o and o:getRoom() ~= room then side = true end
            end
        end
        if side then
            table.insert(sides, s)
            for dx = -2, 2 do
                for dy = -2, 2 do
                    local o = cell:getGridSquare(s.x + dx, s.y + dy, z)
                    local key = (s.x + dx) .. "," .. (s.y + dy)
                    if o and not seen[key] and o:getRoom() == nil and o:isOutside() and o:getFloor() then
                        seen[key] = true
                        table.insert(beyond, o)
                    end
                end
            end
        end
    end
    return sides, beyond
end

-- ballgain <0..1>: paused, the ball turned there; the light on the lit spot squares, then on the
-- same squares with every spot light off (in a small room the spots' light fills the room, so lit
-- squares against the other squares says little there)
COMMANDS.ballgain = function(id, w, p)
    local ball = RainbowLight.firstBall()
    if not ball or ball.mode ~= "light" then finishCmd("error", "no light-mode ball") return end
    RainbowLight.ballPaused = true
    RainbowLight.turnBalls(math.pi * 2 * tonumber(w[2]))
    local lit = {}
    for _, s in ipairs(ball.squares) do
        if s.on then table.insert(lit, s) end
    end
    local function avg()
        local sum = 0
        for _, s in ipairs(lit) do sum = sum + brightness(s.sq) end
        return #lit > 0 and sum / #lit or 0
    end
    local t0, on = getTimestampMs(), nil
    running.deadline = t0 + 10000
    running.poll = function()
        if getTimestampMs() - t0 < 2000 then return false end
        if not on then
            on = avg()
            for _, s in ipairs(ball.squares) do
                if s.on then RainbowLight.ballSetSquare(ball, s, nil, false) end
            end
            ball.lamp:switchLight(true)
            t0 = getTimestampMs()
            return false
        end
        finishCmd("done", string.format("lit=%d on=%.3f off=%.3f of %d squares", #lit, on, avg(), #ball.squares))
        return true
    end
end

-- ballroom: are all the ball's lights in the lamp's room, and how many sit by a wall
COMMANDS.ballroom = function(id, w, p)
    local ball = RainbowLight.firstBall()
    if not ball or ball.mode ~= "light" then finishCmd("error", "no light-mode ball") return end
    local room = ball.lamp:getSquare():getRoom()
    local inRoom = 0
    for _, s in ipairs(ball.squares) do
        if s.sq:getRoom() == room then inRoom = inRoom + 1 end
    end
    local sides, beyond = wallSides(ball)
    finishCmd("done", "squares=" .. #ball.squares .. " inRoom=" .. inRoom .. " byWall=" .. #sides
        .. " outsideNear=" .. #beyond .. " room=" .. tostring(room and room:getName()))
end

-- ballwallspot: an outdoor square 2 to 4 from the room the player can stand on to look at the wall
COMMANDS.ballwallspot = function(id, w, p)
    local ball = RainbowLight.firstBall()
    if not ball or ball.mode ~= "light" then finishCmd("error", "no light-mode ball") return end
    local _, beyond = wallSides(ball)
    local room = ball.lamp:getSquare():getRoom()
    local cell = getCell()
    local z = ball.lamp:getZ()
    for _, o in ipairs(beyond) do
        local x, y = o:getX(), o:getY()
        -- step away from the room up to 2 more squares, staying outdoors
        local near = 0
        for dx = -1, 1 do
            for dy = -1, 1 do
                local n = cell:getGridSquare(x + dx, y + dy, z)
                if n and n:getRoom() == room then near = near + 1 end
            end
        end
        if near == 0 and o:isFree(false) then
            finishCmd("done", x .. " " .. y .. " " .. z)
            return
        end
    end
    finishCmd("error", "no outdoor square by the room (outsideNear=" .. #beyond .. ")")
end

-- ballwall: paused, all spot lights off. The outdoor squares near the room are read, then every
-- spot light by the wall goes on (white) and they are read again: does the light come through the
-- wall? Squares within 2 of a window or door of the room are counted apart from the others. Then,
-- to show the reading works, the same kind of light is put on a seen outdoor square by the wall.
-- Only squares the player sees count (unseen ones read 0).
COMMANDS.ballwall = function(id, w, p)
    local ball = RainbowLight.firstBall()
    if not ball or ball.mode ~= "light" then finishCmd("error", "no light-mode ball") return end
    RainbowLight.ballPaused = true
    local cell = getCell()
    local room = ball.lamp:getSquare():getRoom()
    local sides, beyond = wallSides(ball)
    local function nearOpening(o)
        for dx = -2, 2 do
            for dy = -2, 2 do
                local a = cell:getGridSquare(o:getX() + dx, o:getY() + dy, o:getZ())
                if a and a:getRoom() == room then
                    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                        local n = cell:getGridSquare(a:getX() + d[1], a:getY() + d[2], a:getZ())
                        if n and n:getRoom() ~= room and (a:isWindowTo(n) or a:isDoorTo(n)) then return true end
                    end
                end
            end
        end
        return false
    end
    local opening = {}
    for i, o in ipairs(beyond) do opening[i] = nearOpening(o) end
    local function read()
        local vals = {}
        for i, o in ipairs(beyond) do vals[i] = brightness(o) end
        return vals
    end
    -- {avg, max, count, max at} for the seen squares, by the openings (true) or not (false)
    local function gain(base, now, byOpening)
        local sum, n, most, at = 0, 0, 0, "-"
        for i, v in ipairs(now) do
            if base[i] > 0.02 and opening[i] == byOpening then
                sum, n = sum + (v - base[i]), n + 1
                if v - base[i] > most then most, at = v - base[i], beyond[i]:getX() .. "," .. beyond[i]:getY() end
            end
        end
        return string.format("avg %+.3f max %+.3f at %s (%d squares)", n > 0 and sum / n or 0, most, at, n), n > 0 and most or -1
    end
    local base = read()
    -- the probe square: a seen outdoor square next to a spot square by the wall, away from openings
    local probeSq
    for i, o in ipairs(beyond) do
        if not probeSq and base[i] > 0.02 and not opening[i] then
            for _, s in ipairs(sides) do
                if math.abs(o:getX() - s.x) <= 1 and math.abs(o:getY() - s.y) <= 1 then probeSq = o break end
            end
        end
    end
    for _, s in ipairs(sides) do RainbowLight.ballSetSquare(ball, s, { 1, 1, 1 }, false) end
    ball.lamp:switchLight(true)
    local t0, phase, wallText, wallMost, openText, probe = getTimestampMs(), "wall", nil, nil, nil, nil
    running.deadline = t0 + 15000
    running.poll = function()
        if getTimestampMs() - t0 < 3000 then return false end
        if phase == "wall" then
            local now = read()
            wallText, wallMost = gain(base, now, false)
            openText = gain(base, now, true)
            for _, s in ipairs(sides) do RainbowLight.ballSetSquare(ball, s, nil, false) end
            if probeSq then
                probe = cell:addLamppost(probeSq:getX(), probeSq:getY(), probeSq:getZ(), 0.5, 0.5, 0.5, RainbowLight.BALL_LIGHT_RADIUS)
            end
            ball.lamp:switchLight(true)
            phase, t0 = "probe", getTimestampMs()
            return false
        end
        local probeText, probeMost = "no seen outdoor square by the wall", -1
        if probe then
            probeText, probeMost = gain(base, read(), false)
            probeText = probeText .. " probe at " .. probeSq:getX() .. "," .. probeSq:getY()
            cell:removeLamppost(probe)
            ball.lamp:switchLight(true)
        end
        finishCmd("done", "byWall=" .. #sides .. " | wall: " .. wallText .. " | windows/doors: " .. openText
            .. " | same light outdoors: " .. probeText
            .. string.format(" | wallMax=%.3f probeMax=%.3f", wallMost, probeMost)
            .. " | player at " .. math.floor(p:getX()) .. "," .. math.floor(p:getY()))
        return true
    end
end

COMMANDS.ping = function(id, w, p)
    finishCmd("done", math.floor(p:getX()) .. "," .. math.floor(p:getY()) .. "," .. math.floor(p:getZ()))
end

-- server <command> [x y z] [more key=value]: ask lua/server/RainbowLight_ServerTest.lua, wait for the reply
COMMANDS.server = function(id, w, p)
    local args = { x = tonumber(w[3]), y = tonumber(w[4]), z = tonumber(w[5]) }
    for i = 6, #w do
        local k, v = string.match(w[i], "^([%w_]+)=(.*)$")
        if k then args[k] = tonumber(v) or v end
    end
    reply = nil
    sendClientCommand(p, "RainbowLightTest", w[2], args)
    running.deadline = getTimestampMs() + 20000
    running.poll = function()
        if not reply then return false end
        finishCmd(reply.ok and "done" or "error", tostring(reply.text))
        return true
    end
end

-- measure x y z
COMMANDS.measure = function(id, w, p)
    finishCmd("done", describe(tonumber(w[2]), tonumber(w[3]), tonumber(w[4])))
end

-- color none|switch r g b x y z: change the lamp color in this game only, cycling paused
COMMANDS.color = function(id, w, p)
    local lamp = lampAt(tonumber(w[6]), tonumber(w[7]), tonumber(w[8]))
    if not lamp then finishCmd("error", "no lamp") return end
    RainbowLight.paused = true
    local saved = RainbowLight.REFRESH
    RainbowLight.REFRESH = w[2]
    RainbowLight.setColor(lamp, tonumber(w[3]), tonumber(w[4]), tonumber(w[5]))
    RainbowLight.REFRESH = saved
    finishCmd("done", "set " .. w[2] .. " " .. w[3] .. "," .. w[4] .. "," .. w[5])
end

-- cycle on|off [none|switch]
COMMANDS.cycle = function(id, w, p)
    RainbowLight.paused = w[2] ~= "on"
    if w[3] then RainbowLight.REFRESH = w[3] end
    finishCmd("done", "paused=" .. tostring(RainbowLight.paused) .. " refresh=" .. RainbowLight.REFRESH
        .. " lampsNearby=" .. RainbowLight.lampCount())
end

-- time <hour>: this game's clock (the server's clock is set with "server night")
COMMANDS.time = function(id, w, p)
    getGameTime():setTimeOfDay(tonumber(w[2]))
    finishCmd("done", "time=" .. f2(getGameTime():getTimeOfDay()))
end

-- shot <file name>: whole game window to <cachedir>\Screenshots\<name>
COMMANDS.shot = function(id, w, p)
    getCore():TakeFullScreenshot(w[2])
    finishCmd("done", "screenshot " .. w[2])
end

COMMANDS.quit = function(id, w, p)
    finishCmd("done", "quitting")
    getCore():quitToDesktop()
end

Events.OnTick.Add(function()
    local p = getPlayer()
    if not p then return end
    if running then
        local ok, finished = pcall(running.poll)
        if not ok then
            finishCmd("error", "poll: " .. tostring(finished))
        elseif not finished and running and getTimestampMs() > running.deadline then
            finishCmd("error", "timeout")
        end
        return
    end
    local id, words = readCommand()
    if not id then return end
    lastId = id
    local fn = COMMANDS[words[1] or ""]
    out(id, "start", table.concat(words, " "))
    if not fn then out(id, "error", "unknown command " .. tostring(words[1])) return end
    running = { id = id, deadline = getTimestampMs() + 10000, poll = function() return false end }
    local ok, err = pcall(fn, id, words, p)
    if not ok and running then finishCmd("error", tostring(err)) end
end)

print(TAG .. "loaded for " .. cfg.user .. (isClient() and " (in game)" or " (main menu)"))
