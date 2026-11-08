-- Mirror ball (prototype). A lit lamp with the mirror ball bulb dims its own light and throws
-- colored spots that turn around it, like light from a turning mirror ball.
--
-- MODE = "light": small colored lights (IsoCell:addLamppost, this game only) are laid on the
-- squares around the lamp once, and the spots are drawn by switching them on and off; nothing is
-- moved. A moved light has to be removed and added again, and the game relights for that.
-- LightingJNI notices on/off and color changes of a light by itself but shows them late (seen
-- with the lamps, 1 to 4 s), so after a change the lamp's switchLight is called: it makes the game
-- relight right away (IsoLightSwitch.switchLight: recalcLightTime, lightSourceUpdate,
-- doInvalidateGlobalLights), the same trick RainbowLight_Client.lua uses.
-- MODE = "marker": the spots are floor markers (getWorldMarkers():addGridSquareMarker, what the
-- debug horde spawner draws). Not light, so no relighting at all, but the floor does not light up.
--
-- Visual only, every client for itself, no network traffic.

require "RainbowLight_Client"

RainbowLight.BALL = "RainbowLight.LightBulbMirrorBall"
RainbowLight.BALL_MODE = "light"     -- "light" or "marker"
RainbowLight.BALL_TURN_MS = 6000     -- one turn of the ball
RainbowLight.BALL_STEP_MS = 100      -- how often the spots move
RainbowLight.BALL_SPOTS = 8          -- spots around the ball
RainbowLight.BALL_INNER = 2          -- spots land between these distances (squares) from the lamp
RainbowLight.BALL_OUTER = 5
RainbowLight.BALL_LIGHT_RADIUS = 2   -- radius of one spot light
RainbowLight.BALL_LAMP_LEVEL = 0.05  -- what is left of the lamp's own light
RainbowLight.ballPaused = false

local SCAN_RADIUS = 20
local SCAN_INTERVAL_MS = 1000
local TWO_PI = math.pi * 2
local lastScan, lastStep = 0, 0
local balls = {}   -- "x,y,z" -> ball (see makeBall)

-- spot colors: around the rainbow, and white
local PALETTE = {}
for i = 0, 5 do
    local r, g, b = RainbowLight.hueToRGB(i / 6)
    table.insert(PALETTE, { r, g, b })
end
table.insert(PALETTE, { 1, 1, 1 })

function RainbowLight.isMirrorBall(obj)
    return instanceof(obj, "IsoLightSwitch") and obj:getBulbItem() == RainbowLight.BALL
end

local function isLit(lamp)
    return lamp:getSquare() and lamp:isActivated() and lamp:getBulbItem() == RainbowLight.BALL
end

local function keyOf(lamp)
    return lamp:getX() .. "," .. lamp:getY() .. "," .. lamp:getZ()
end

-- squares a spot may land on: same level, same room as the lamp (or outdoors when the lamp is),
-- with a floor, between BALL_INNER and BALL_OUTER from the lamp
local function spotSquares(lamp)
    local cell = getCell()
    local lx, ly, lz = lamp:getX(), lamp:getY(), lamp:getZ()
    local room = lamp:getSquare():getRoom()
    local list = {}
    local outer = RainbowLight.BALL_OUTER
    for dx = -outer, outer do
        for dy = -outer, outer do
            local d = math.sqrt(dx * dx + dy * dy)
            if d >= RainbowLight.BALL_INNER and d <= outer + 0.5 then
                local sq = cell:getGridSquare(lx + dx, ly + dy, lz)
                if sq and sq:getFloor() and sq:getRoom() == room then
                    table.insert(list, { sq = sq, x = lx + dx, y = ly + dy, d = d, a = math.atan2(dy, dx) })
                end
            end
        end
    end
    return list
end

-- every spot keeps its distance from the ball and its color; the ball turns them all together
local function makeSpots()
    local spots = {}
    local n = RainbowLight.BALL_SPOTS
    for k = 1, n do
        local d = RainbowLight.BALL_INNER + (RainbowLight.BALL_OUTER - RainbowLight.BALL_INNER) * ZombRandFloat(0, 1)
        table.insert(spots, { d = d, a = TWO_PI * (k - 1) / n + ZombRandFloat(-0.3, 0.3), color = PALETTE[ZombRand(#PALETTE) + 1] })
    end
    return spots
end

local function dimLamp(lamp)
    local v = RainbowLight.BALL_LAMP_LEVEL
    if lamp:getPrimaryR() ~= v or lamp:getPrimaryG() ~= v or lamp:getPrimaryB() ~= v then
        lamp:setPrimaryR(v)
        lamp:setPrimaryG(v)
        lamp:setPrimaryB(v)
        lamp:switchLight(true)
    end
end

local function removeBall(key)
    local ball = balls[key]
    if not ball then return end
    for _, s in ipairs(ball.squares) do
        if s.light then getCell():removeLamppost(s.light) end
    end
    for _, m in ipairs(ball.markers) do m:remove() end
    balls[key] = nil
end

local function makeBall(lamp)
    local ball = { lamp = lamp, mode = RainbowLight.BALL_MODE, squares = spotSquares(lamp), spots = makeSpots(), markers = {} }
    if ball.mode == "light" then
        for _, s in ipairs(ball.squares) do
            s.light = getCell():addLamppost(s.x, s.y, lamp:getZ(), 1, 1, 1, RainbowLight.BALL_LIGHT_RADIUS)
            s.light:setActive(false)
            s.on = false
        end
    else
        for _ = 1, #ball.spots do
            local m = getWorldMarkers():addGridSquareMarker(lamp:getSquare(), 1, 1, 1, false, 0.6)
            m:setActive(false)
            table.insert(ball.markers, m)
        end
    end
    return ball
end

-- the game drops lights whose square left the loaded area: then the ball is made again
local function ballIntact(ball)
    if ball.mode ~= RainbowLight.BALL_MODE then return false end
    if ball.mode ~= "light" then return true end
    local registered = getCell():getLamppostPositions()
    for _, s in ipairs(ball.squares) do
        if not registered:contains(s.light) then return false end
    end
    return true
end

local function angleDiff(a, b)
    local d = (a - b) % TWO_PI
    if d > math.pi then d = d - TWO_PI end
    return math.abs(d)
end

-- turn the ball to angle `turn` (radians); returns true when a light changed
local function stepBall(ball, turn)
    if ball.mode == "light" then
        local changed = false
        for _, s in ipairs(ball.squares) do
            local want = nil
            for _, spot in ipairs(ball.spots) do
                -- within about one square of the spot (distance, and arc length at that distance)
                if math.abs(s.d - spot.d) < 0.8 and angleDiff(s.a, spot.a + turn) * s.d < 0.8 then
                    want = spot.color
                    break
                end
            end
            if want then
                if not s.on or s.color ~= want then
                    s.light:setR(want[1] * 0.5)
                    s.light:setG(want[2] * 0.5)
                    s.light:setB(want[3] * 0.5)
                    s.light:setActive(true)
                    s.on, s.color, changed = true, want, true
                end
            elseif s.on then
                s.light:setActive(false)
                s.on, s.color, changed = false, nil, true
            end
        end
        return changed
    end
    local lx, ly, lz = ball.lamp:getX(), ball.lamp:getY(), ball.lamp:getZ()
    local room = ball.lamp:getSquare():getRoom()
    for i, spot in ipairs(ball.spots) do
        local m = ball.markers[i]
        local x = lx + math.floor(math.cos(spot.a + turn) * spot.d + 0.5)
        local y = ly + math.floor(math.sin(spot.a + turn) * spot.d + 0.5)
        local sq = getCell():getGridSquare(x, y, lz)
        if sq and sq:getRoom() == room then
            m:setPos(x, y, lz)
            m:setR(spot.color[1])
            m:setG(spot.color[2])
            m:setB(spot.color[3])
            m:setActive(true)
        else
            m:setActive(false)
        end
    end
    return false
end

local function scan()
    local player = getSpecificPlayer(0)
    if not player then return end
    local cell = getCell()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local wanted = {}
    for z = pz - 1, pz + 1 do
        for x = px - SCAN_RADIUS, px + SCAN_RADIUS do
            for y = py - SCAN_RADIUS, py + SCAN_RADIUS do
                local sq = cell:getGridSquare(x, y, z)
                if sq then
                    local objects = sq:getObjects()
                    for i = 0, objects:size() - 1 do
                        local obj = objects:get(i)
                        if RainbowLight.isMirrorBall(obj) and isLit(obj) then
                            local key = keyOf(obj)
                            wanted[key] = true
                            local ball = balls[key]
                            if ball and (ball.lamp ~= obj or not ballIntact(ball)) then
                                removeBall(key)
                                ball = nil
                            end
                            if not ball then balls[key] = makeBall(obj) end
                            dimLamp(obj)
                        end
                    end
                end
            end
        end
    end
    for key, _ in pairs(balls) do
        if not wanted[key] then removeBall(key) end
    end
end

-- turn every ball to angle `turn` now
function RainbowLight.turnBalls(turn)
    for key, ball in pairs(balls) do
        if isLit(ball.lamp) then
            if stepBall(ball, turn) then ball.lamp:switchLight(true) end
        else
            removeBall(key)
        end
    end
end

-- after changing BALL_MODE, BALL_SPOTS and the like
function RainbowLight.rebuildBalls()
    for key, _ in pairs(balls) do removeBall(key) end
    lastScan = 0
end

-- for RainbowLight_TestPilot.lua: one spot square on (color {r, g, b}) or off (nil), with or without
-- the lamp's switchLight afterwards
function RainbowLight.ballSetSquare(ball, s, color, refresh)
    if color then
        s.light:setR(color[1] * 0.5)
        s.light:setG(color[2] * 0.5)
        s.light:setB(color[3] * 0.5)
        s.light:setActive(true)
        s.on, s.color = true, color
    else
        s.light:setActive(false)
        s.on, s.color = false, nil
    end
    if refresh then ball.lamp:switchLight(true) end
end

function RainbowLight.firstBall()
    for _, ball in pairs(balls) do return ball end
    return nil
end

-- for RainbowLight_TestPilot.lua: { lights, lit, markers, squares } over every ball
function RainbowLight.ballInfo()
    local info = { balls = 0, lights = 0, lit = 0, markers = 0, squares = {} }
    for _, ball in pairs(balls) do
        info.balls = info.balls + 1
        info.markers = info.markers + #ball.markers
        for _, s in ipairs(ball.squares) do
            table.insert(info.squares, s)
            if s.light then info.lights = info.lights + 1 end
            if s.on then info.lit = info.lit + 1 end
        end
    end
    return info
end

Events.OnTick.Add(function()
    local now = getTimestampMs()
    if now - lastScan >= SCAN_INTERVAL_MS then
        lastScan = now
        scan()
    end
    if RainbowLight.ballPaused or now - lastStep < RainbowLight.BALL_STEP_MS then return end
    lastStep = now
    RainbowLight.turnBalls(TWO_PI * (now % RainbowLight.BALL_TURN_MS) / RainbowLight.BALL_TURN_MS)
end)
