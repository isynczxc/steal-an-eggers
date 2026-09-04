--!nonstrict
-- CloverHub bootstrap: key injection, cached fetch, Delta-safe HTTP, optional FPS sweep

local ENV = (typeof(getgenv) == "function" and getgenv()) or _G

----------------------------------------------------------------- config
local KEY        = "CH-8FA82EA2-366D4DB1-A085FF0E-CE75D5C2"
local LOADER_URL = "https://cloverhub.app/clover.lua"
local CACHE_DIR  = "CloverHub"
local CACHE_TTL  = 6 * 60 * 60   -- seconds of source reuse; 0 = always download
local FPS_SWEEP  = true          -- client-side render cleanup
local FPS_CAP    = 60            -- 0 = leave alone
-------------------------------------------------------------------------

local SRC_FILE, META_FILE = CACHE_DIR .. "/loader.lua", CACHE_DIR .. "/loader.stamp"

local function log(fmt, ...)
    warn(string.format("[clover] " .. fmt, ...))
end

-- Key injection. Hubs disagree on the global name; keep the one CloverHub
-- documents and delete the rest.
for _, name in { "Key", "key", "script_key", "CloverKey" } do
    ENV[name] = KEY
end
ENV.CloverHub = ENV.CloverHub or {}
ENV.CloverHub.Key = KEY

--------------------------------------------------------------- filesystem
local hasFS = isfile and readfile and writefile and isfolder and makefolder

local function cacheRead(): string?
    if CACHE_TTL <= 0 or not hasFS then return nil end
    if not isfile(SRC_FILE) or not isfile(META_FILE) then return nil end
    local okStamp, stamp = pcall(readfile, META_FILE)
    if not okStamp then return nil end
    local age = os.time() - (tonumber(stamp) or 0)
    if age < 0 or age > CACHE_TTL then return nil end
    local okSrc, src = pcall(readfile, SRC_FILE)
    if okSrc and type(src) == "string" and #src > 0 then
        log("using cached loader (%ds old, %d bytes)", age, #src)
        return src
    end
    return nil
end

local function cacheWrite(src: string)
    if CACHE_TTL <= 0 or not hasFS then return end
    pcall(function()
        if not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
        writefile(SRC_FILE, src)
        writefile(META_FILE, tostring(os.time()))
    end)
end

--------------------------------------------------------------------- http
local function fetch(url: string): (string?, string?)
    local req = ENV.request or ENV.http_request
        or (ENV.syn and ENV.syn.request) or (ENV.http and ENV.http.request)

    if req then
        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if not ok then return nil, tostring(res) end
        local status = tonumber(res.StatusCode or res.Status) or 0
        if status ~= 200 then return nil, "HTTP " .. status end
        if type(res.Body) ~= "string" or #res.Body == 0 then return nil, "empty body" end
        return res.Body
    end

    local ok, body = pcall(game.HttpGet, game, url, true)
    if not ok then return nil, tostring(body) end
    if type(body) ~= "string" or #body == 0 then return nil, "empty body" end
    if body:match("^404") then return nil, "HTTP 404" end
    return body
end

local function download(): (string?, string?)
    local lastError
    for attempt = 1, 3 do
        local src, err = fetch(LOADER_URL)
        if src then cacheWrite(src); return src end
        lastError = err
        if attempt < 3 then task.wait(0.5 * 2 ^ (attempt - 1)) end
    end
    return nil, lastError
end

------------------------------------------------------------- render sweep
local STRIP = {
    ParticleEmitter = true, Trail = true, Smoke = true, Fire = true,
    Sparkles = true, Explosion = true, Beam = true,
}
local POST = {
    BloomEffect = true, BlurEffect = true, SunRaysEffect = true,
    DepthOfFieldEffect = true, ColorCorrectionEffect = true,
}

local function fpsSweep()
    local Lighting, Terrain = game:GetService("Lighting"), workspace.Terrain

    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function() if setfpscap and FPS_CAP > 0 then setfpscap(FPS_CAP) end end)
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e6
        Terrain.WaterWaveSize, Terrain.WaterWaveSpeed = 0, 0
        Terrain.WaterReflectance, Terrain.WaterTransparency = 0, 0
    end)

    for _, fx in Lighting:GetChildren() do
        if POST[fx.ClassName] then pcall(function() fx.Enabled = false end) end
    end

    local n = 0
    for _, inst in workspace:GetDescendants() do
        n += 1
        if n % 500 == 0 then task.wait() end -- keep the frame alive on mobile
        local class = inst.ClassName
        if STRIP[class] then
            pcall(function() inst.Enabled = false end)
        elseif class == "MeshPart" then
            pcall(function() inst.RenderFidelity = Enum.RenderFidelity.Performance end)
        elseif inst:IsA("BasePart") then
            pcall(function()
                inst.Material = Enum.Material.SmoothPlastic
                inst.Reflectance, inst.CastShadow = 0, false
            end)
        end
    end
    log("render sweep done (%d descendants)", n)
end

-------------------------------------------------------------------- main
if ENV.__cloverBootstrap then
    return log("already running; ignoring duplicate execution")
end
ENV.__cloverBootstrap = true

if not game:IsLoaded() then game.Loaded:Wait() end

local source, err = cacheRead(), nil
if not source then
    source, err = download()
end
if not source then
    ENV.__cloverBootstrap = nil
    return log("download failed: %s", tostring(err))
end

local chunk, compileError = loadstring(source, "@clover")
if not chunk then
    ENV.__cloverBootstrap = nil
    return log("compile failed: %s", tostring(compileError))
end

local ok, runError = xpcall(chunk, function(e)
    return debug.traceback(tostring(e), 2)
end)
if not ok then
    log("hub errored: %s", tostring(runError))
end

if FPS_SWEEP then
    task.defer(function()
        local swept, sweepError = pcall(fpsSweep)
        if not swept then log("sweep failed: %s", tostring(sweepError)) end
    end)
end
