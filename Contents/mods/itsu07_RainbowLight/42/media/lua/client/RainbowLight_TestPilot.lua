if not isDebugEnabled() then return end
-- Test autopilot for tools/light_test.py. Does nothing unless the game runs with -debug AND
-- <cachedir>\Lua\RainbowLight_pilot.txt exists (light_test.py writes it only into its own test folder).
-- Main menu: connects to the test server by itself (same way as CheeseMaking_DebugPilot.lua).
-- In game: runs commands from RainbowLight_pilot_cmd.txt, answers in RainbowLight_pilot_out.txt.

require "RainbowLight_Client"

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
