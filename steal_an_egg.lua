--!nonstrict
--[[
    steal_an_egg.lua - SyncHub feature set for Steal an Egg.

    Needs synchub.lua next to it (or at SyncHub/synchub.lua). No key, no
    remote fetch, nothing phones home except the Discord webhook you supply.

    Design note: this file never hardcodes remote names. Roblox games rename
    and reshuffle remotes constantly, so instead there is an Adapter that
    discovers them at runtime plus a Remote Logger that records what the game
    actually fires when you play manually. You bind a logged call to an action
    once, it saves to config, and every automation loop uses that binding.
    That is why nothing here breaks on a game update.
--]]

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local TeleportService    = game:GetService("TeleportService")
local HttpService        = game:GetService("HttpService")
local Lighting           = game:GetService("Lighting")
local VirtualUser        = game:GetService("VirtualUser")

local ENV   = (typeof(getgenv) == "function" and getgenv()) or _G
local hasFS = isfile and readfile and writefile

local DIR  = "SyncHub"
local REPO = "https://raw.githubusercontent.com/isynczxc/steal-an-eggers/main/"

--------------------------------------------------------------------- library
-- Three ways in, tried in order:
--   1. ENV.SyncHubInline - set by build.ps1 in the single-file release. This is
--      what runs when someone loadstrings sae.lua off GitHub.
--   2. a local file - what runs while you are editing.
--   3. HttpGet from the repo - fallback if only this file was loaded.
-- Nothing is cached, so editing synchub.lua and re-executing picks up the
-- change instead of serving a stale copy.
local function loadLibrary()
    if type(ENV.SyncHubInline) == "function" then
        return ENV.SyncHubInline()
    end

    for _, path in { DIR .. "/synchub.lua", "synchub.lua" } do
        if hasFS and isfile(path) then
            local chunk, err = loadstring(readfile(path), "@synchub")
            if not chunk then
                error("synchub.lua failed to compile: " .. tostring(err))
            end
            return chunk()
        end
    end

    local ok, body = pcall(function()
        return game:HttpGet(REPO .. "synchub.lua", true)
    end)
    if ok and type(body) == "string" and #body > 0 then
        local chunk, err = loadstring(body, "@synchub")
        if not chunk then
            error("synchub.lua from repo failed to compile: " .. tostring(err))
        end
        return chunk()
    end

    error("synchub.lua unavailable (no inline copy, no file, no network)")
end

local Hub = loadLibrary()
local win = Hub.new("SyncHub - Steal an Egg", DIR .. "/StealAnEgg")

--------------------------------------------------------------------- domain
-- Taken from your own config file, so the filter lists match what the game
-- actually uses rather than guesses.
local RARITIES = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary",
    "Mythic", "Cosmic", "Divine", "Eternal", "Secret",
}
local AREAS = {
    "Cherry Blossom", "Cosmic", "Volcano", "Prehistoric", "Abyss Ocean",
}
local PRIORITIES = { "Rarity", "KG", "Nearest", "Value" }
local KG_MODES   = { "Any", "Above", "Below" }
local MOVE_MODES = { "Walk", "Glide", "Teleport" }
local ACTIONS    = {
    "Steal", "Place", "Hatch", "CollectCash", "OpenChest", "SkipChest",
    "SellPet", "SellEgg", "EquipBest", "UpgradePen", "Treadmill",
    "UpgradeTreadmill", "BuyTrail", "ClaimIndex", "HungryMonster",
}

--------------------------------------------------------------------- state
local State = {
    lp        = Players.LocalPlayer,
    session   = os.time(),
    steals    = 0,
    hatches   = 0,
    cash      = 0,
    lastSteal = 0,
    logging   = false,
    log       = {},        -- ordered list of unique captured calls
    logSeen   = {},        -- signature -> index
    esp       = {},        -- instance -> Highlight
    noclip    = false,
    hooked    = false,
}

local function lp() return State.lp end
local function char() return lp().Character end
local function root()
    local c = char()
    return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart)
end
local function humanoid()
    local c = char()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function elapsed()
    local seconds = os.time() - State.session
    return string.format("%02d:%02d:%02d",
        seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

--=========================================================================--
--                                JOURNAL                                  --
--=========================================================================--
-- A kick tears down the Lua VM and takes any in-memory log with it, so every
-- notable action is appended to disk the moment it happens. After a kick, open
-- SyncHub/journal.txt: the last line is what the hub did immediately before.
local Journal = {}

function Journal:write(fmt, ...)
    local ok, body = pcall(string.format, fmt, ...)
    local line = string.format("[%s] %s", os.date("%H:%M:%S"),
        ok and body or tostring(fmt))

    if appendfile then
        pcall(appendfile, DIR .. "/journal.txt", line .. "\n")
    elseif hasFS and writefile then
        State.journalBuffer = (State.journalBuffer or "") .. line .. "\n"
        pcall(writefile, DIR .. "/journal.txt", State.journalBuffer)
    end
end

function Journal:reset()
    local header = string.format(
        "=== session %s | place %d | job %s | executor %s ===\n",
        os.date("%Y-%m-%d %H:%M:%S"), game.PlaceId, game.JobId,
        (identifyexecutor and identifyexecutor()) or "unknown")
    State.journalBuffer = header
    if hasFS and writefile then
        pcall(writefile, DIR .. "/journal.txt", header)
    end
end

--=========================================================================--
--                                ADAPTER                                  --
--=========================================================================--
-- Discovers the game's remotes and containers instead of assuming paths.
local Adapter = { remotes = {}, containers = {} }

local REMOTE_CLASSES = {
    RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true,
}

function Adapter:scan()
    self.remotes, self.containers = {}, {}

    for _, service in { ReplicatedStorage, workspace } do
        local ok, descendants = pcall(function() return service:GetDescendants() end)
        if ok then
            for _, d in descendants do
                if REMOTE_CLASSES[d.ClassName] then
                    -- Keep the shortest path per name; games often mirror remotes.
                    local existing = self.remotes[d.Name]
                    if not existing or #d:GetFullName() < #existing:GetFullName() then
                        self.remotes[d.Name] = d
                    end
                end
            end
        end
    end

    -- Containers are matched loosely because names vary between updates.
    local wanted = {
        plots     = { "plot", "base", "pen", "island" },
        eggs      = { "egg" },
        conveyor  = { "conveyor", "belt" },
        chests    = { "chest" },
    }
    for _, child in workspace:GetChildren() do
        local lower = string.lower(child.Name)
        for slot, words in wanted do
            if not self.containers[slot] then
                for _, word in words do
                    if string.find(lower, word, 1, true) then
                        self.containers[slot] = child
                        break
                    end
                end
            end
        end
    end

    local count = 0
    for _ in self.remotes do count += 1 end
    return count
end

function Adapter:names()
    local names = {}
    for name in self.remotes do table.insert(names, name) end
    table.sort(names)
    return names
end

-- Resolves a binding saved in config into something callable.
-- A binding is { remote = "Name", method = "FireServer", args = { ... } }.
function Adapter:invoke(action, ...)
    local binding = win:Get("bind_" .. action)
    if type(binding) ~= "table" or not binding.remote then
        return false, "unbound"
    end

    local remote = self.remotes[binding.remote]
    if not remote then
        self:scan()
        remote = self.remotes[binding.remote]
    end
    if not remote then return false, "remote missing: " .. binding.remote end

    -- Saved args act as a template. Runtime args replace any "%s" placeholder,
    -- otherwise they are appended.
    local args = {}
    local runtime = { ... }
    local used = 0
    for i, value in binding.args or {} do
        if value == "%s" then
            used += 1
            args[i] = runtime[used]
        else
            args[i] = value
        end
    end
    for i = used + 1, #runtime do
        table.insert(args, runtime[i])
    end

    local method = binding.method == "InvokeServer" and "InvokeServer" or "FireServer"
    Journal:write("invoke %s -> %s:%s (%d args)", action, binding.remote,
        method, #args)
    local ok, result = pcall(function()
        return remote[method](remote, table.unpack(args))
    end)
    if not ok then
        Journal:write("invoke %s FAILED: %s", action, tostring(result))
    end
    return ok, result
end

function Adapter:bound(action)
    local binding = win:Get("bind_" .. action)
    return type(binding) == "table" and binding.remote ~= nil
end

--=========================================================================--
--                             REMOTE LOGGER                               --
--=========================================================================--
-- Hooks __namecall once and records outgoing FireServer/InvokeServer calls.
-- This is how you find the real "steal" remote: turn logging on, steal one egg
-- by hand, and the call shows up in the list ready to bind.
local Logger = {}

local function describeArg(value)
    local kind = typeof(value)
    if kind == "Instance" then
        return string.format("<%s:%s>", value.ClassName, value.Name)
    elseif kind == "table" then
        local ok, encoded = pcall(function() return HttpService:JSONEncode(value) end)
        return ok and encoded or "<table>"
    elseif kind == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

local function signature(remoteName, method, args)
    local parts = { remoteName, method }
    for _, value in args do table.insert(parts, describeArg(value)) end
    return table.concat(parts, "|")
end

function Logger:record(remote, method, args)
    local sig = signature(remote.Name, method, args)
    local index = State.logSeen[sig]
    if index then
        State.log[index].hits += 1
        State.log[index].at = os.clock()
        return
    end

    -- Store a serialisable copy. Instances cannot go into a config file, so
    -- they are kept as live references for replay and as text for display.
    local template = {}
    for i, value in args do
        template[i] = typeof(value) == "Instance" and value or value
    end

    table.insert(State.log, {
        remote   = remote.Name,
        path     = remote:GetFullName(),
        method   = method,
        args     = template,
        display  = sig,
        hits     = 1,
        at       = os.clock(),
    })
    State.logSeen[sig] = #State.log
    win:Notify("logged " .. remote.Name, "ok", 2)
end

function Logger:install()
    if State.hooked then return true end
    if not (hookmetamethod and getnamecallmethod and checkcaller) then
        return false
    end

    local original
    original = hookmetamethod(game, "__namecall", function(instance, ...)
        if State.logging and not checkcaller() then
            local ok, method = pcall(getnamecallmethod)
            if ok and (method == "FireServer" or method == "InvokeServer")
                and REMOTE_CLASSES[instance.ClassName] then
                -- Varargs cannot cross into a nested closure, so capture first.
                local args = { ... }
                pcall(function() Logger:record(instance, method, args) end)
            end
        end
        return original(instance, ...)
    end)

    State.hooked = true
    return true
end

function Logger:dump()
    local lines = {}
    for i, entry in State.log do
        table.insert(lines, string.format("%2d. [%s] %s  hits=%d\n    %s",
            i, entry.method, entry.path, entry.hits, entry.display))
    end
    local report = table.concat(lines, "\n")
    if hasFS and writefile then
        pcall(writefile, DIR .. "/remotes.txt", report)
    end
    if setclipboard then pcall(setclipboard, report) end
    print(report)
    return report
end

-- Plot ownership is exposed differently per game version: sometimes an
-- attribute, sometimes a StringValue, sometimes a surface label. Try all three
-- and never let a missing one throw.
local function ownerOf(plot)
    local ok, value = pcall(function() return plot:GetAttribute("Owner") end)
    if ok and value ~= nil and value ~= "" then return tostring(value) end

    local holder = plot:FindFirstChild("Owner", true)
    if holder and holder:IsA("ValueBase") then
        local read, inner = pcall(function() return holder.Value end)
        if read and inner ~= nil and inner ~= "" then return tostring(inner) end
    end

    for _, d in plot:GetDescendants() do
        if d:IsA("TextLabel") then
            local name = string.match(d.Text, "^(%w+)'s")
            if name then return name end
        end
    end
    return nil
end

--=========================================================================--
--                             EGG INSPECTION                              --
--=========================================================================--
-- Reads whatever the game exposes about an egg. Attributes first, then value
-- objects, then the billboard text, because these games usually render the
-- rarity and weight above the egg even when they hide it from the client tree.
local function readInfo(model)
    local info = { name = model.Name, instance = model }

    local ok, attrs = pcall(function() return model:GetAttributes() end)
    if ok and type(attrs) == "table" then
        for rawKey, value in attrs do
            local key = string.lower(rawKey)
            if string.find(key, "rarity") then info.rarity = tostring(value)
            elseif string.find(key, "mutation") then info.mutation = tostring(value)
            elseif string.find(key, "kg") or string.find(key, "weight") then
                info.kg = tonumber(value) or info.kg
            elseif string.find(key, "area") or string.find(key, "biome") then
                info.area = tostring(value)
            elseif string.find(key, "eggname") or string.find(key, "display") then
                info.name = tostring(value)
            end
        end
    end

    for _, d in model:GetDescendants() do
        if d:IsA("ValueBase") then
            local key = string.lower(d.Name)
            local value = select(2, pcall(function() return d.Value end))
            if string.find(key, "rarity") then info.rarity = tostring(value)
            elseif string.find(key, "mutation") then info.mutation = tostring(value)
            elseif string.find(key, "kg") or string.find(key, "weight") then
                info.kg = tonumber(value) or info.kg
            end
        elseif d:IsA("TextLabel") and d.Text ~= "" then
            local text = d.Text
            local kg = string.match(text, "([%d%.]+)%s*[kK][gG]")
            if kg then info.kg = tonumber(kg) or info.kg end
            for _, rarity in RARITIES do
                if string.find(text, rarity, 1, true) then info.rarity = rarity end
            end
        end
    end

    return info
end

-- True when the egg passes every filter the user has switched on.
local function matchesFilter(info)
    local rarities = win:Get("TargetRarities")
    if type(rarities) == "table" and next(rarities) then
        if not (info.rarity and rarities[info.rarity]) then return false end
    end

    local areas = win:Get("TargetAreas")
    if type(areas) == "table" and next(areas) and info.area then
        if not areas[info.area] then return false end
    end

    local mode = win:Get("TargetKGMode", "Any")
    local threshold = tonumber(win:Get("TargetKGThreshold", 0)) or 0
    if mode ~= "Any" and threshold > 0 then
        local kg = info.kg or 0
        if mode == "Above" and kg < threshold then return false end
        if mode == "Below" and kg > threshold then return false end
    end

    return true
end

local RARITY_RANK = {}
for index, rarity in RARITIES do RARITY_RANK[rarity] = index end

local function scoreOf(info, origin)
    local priority = win:Get("TargetPriority", "Rarity")
    if priority == "KG" then
        return info.kg or 0
    elseif priority == "Nearest" then
        local part = info.instance:IsA("BasePart") and info.instance
            or info.instance:FindFirstChildWhichIsA("BasePart")
        if not part or not origin then return -math.huge end
        return -(part.Position - origin).Magnitude
    elseif priority == "Value" then
        return (RARITY_RANK[info.rarity] or 0) * 1000 + (info.kg or 0)
    end
    return RARITY_RANK[info.rarity] or 0
end

--=========================================================================--
--                                FEATURES                                 --
--=========================================================================--
local Features = {}

------------------------------------------------------------------- movement
function Features.applyCharacter()
    local hum = humanoid()
    if not hum then return end
    local speed = tonumber(win:Get("WalkSpeed", 16)) or 16
    local jump  = tonumber(win:Get("JumpPower", 50)) or 50
    pcall(function()
        hum.WalkSpeed = speed
        hum.UseJumpPower = true
        hum.JumpPower = jump
    end)
end

function Features.noclip(on)
    State.noclip = on
    if on and not State.noclipConn then
        State.noclipConn = win:Track(RunService.Stepped:Connect(function()
            local c = char()
            if not c then return end
            for _, part in c:GetDescendants() do
                if part:IsA("BasePart") and part.CanCollide then
                    part.CanCollide = false
                end
            end
        end))
    elseif not on and State.noclipConn then
        State.noclipConn:Disconnect()
        State.noclipConn = nil
    end
end

function Features.infiniteJump(on)
    if on and not State.jumpConn then
        local UIS = game:GetService("UserInputService")
        State.jumpConn = win:Track(UIS.JumpRequest:Connect(function()
            local hum = humanoid()
            if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
        end))
    elseif not on and State.jumpConn then
        State.jumpConn:Disconnect()
        State.jumpConn = nil
    end
end

-- Three ways to reach a target, in ascending order of how obvious each is to a
-- server-side check:
--   Walk     - Humanoid:MoveTo. Real pathing, real physics, nothing to detect.
--   Glide    - small per-frame CFrame nudges, hard capped so no single step
--              exceeds what a fast legitimate player covers in one frame.
--   Teleport - one jump straight to the target. Fastest and loudest.
-- Walk is the default on purpose. Teleport at 900+ studs/sec is the single most
-- reliable way to get kicked from a game like this.
local ARRIVE   = 7    -- studs; close enough to interact
local MAX_STEP = 18   -- studs per frame ceiling in Glide mode

function Features.moveTo(position, speed, mode)
    local part = root()
    if not part then return false end

    mode  = mode or win:Get("StealMode", "Walk")
    speed = math.max(tonumber(speed) or 120, 16)
    local deadline = os.clock() + (tonumber(win:Get("MoveTimeout", 20)) or 20)
    local distance = (position - part.Position).Magnitude

    if mode == "Teleport" then
        Journal:write("teleport %.0f studs", distance)
        part.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
            * (part.CFrame - part.Position)
        return true
    end

    if mode == "Walk" then
        local hum = humanoid()
        if not hum then return false end
        Journal:write("walk %.0f studs", distance)
        while os.clock() < deadline do
            part = root()
            if not part then return false end
            if (position - part.Position).Magnitude < ARRIVE then return true end
            hum:MoveTo(position)   -- re-issued because MoveTo gives up after 8s
            task.wait(0.25)
        end
        Journal:write("walk timed out")
        return false
    end

    Journal:write("glide %.0f studs at %d", distance, speed)
    while os.clock() < deadline do
        part = root()
        if not part then return false end
        local offset = position - part.Position
        if offset.Magnitude < ARRIVE then return true end
        local dt = RunService.Heartbeat:Wait()
        local step = math.min(offset.Magnitude, speed * dt, MAX_STEP)
        local rotation = part.CFrame - part.Position
        part.CFrame = CFrame.new(part.Position + offset.Unit * step) * rotation
    end
    Journal:write("glide timed out")
    return false
end

---------------------------------------------------------------- performance
local STRIP = {
    ParticleEmitter = true, Trail = true, Smoke = true, Fire = true,
    Sparkles = true, Explosion = true, Beam = true,
}
local POST = {
    BloomEffect = true, BlurEffect = true, SunRaysEffect = true,
    DepthOfFieldEffect = true, ColorCorrectionEffect = true,
}

function Features.extremeFPS()
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e6
        workspace.Terrain.WaterWaveSize = 0
        workspace.Terrain.WaterWaveSpeed = 0
        workspace.Terrain.WaterReflectance = 0
        workspace.Terrain.WaterTransparency = 0
    end)
    for _, fx in Lighting:GetChildren() do
        if POST[fx.ClassName] then pcall(function() fx.Enabled = false end) end
    end

    local seen = 0
    for _, inst in workspace:GetDescendants() do
        seen += 1
        if seen % 600 == 0 then task.wait() end   -- keep the frame alive on mobile
        local class = inst.ClassName
        if STRIP[class] then
            pcall(function() inst.Enabled = false end)
        elseif class == "MeshPart" then
            pcall(function()
                inst.RenderFidelity = Enum.RenderFidelity.Performance
            end)
        elseif inst:IsA("BasePart") then
            pcall(function()
                inst.Material = Enum.Material.SmoothPlastic
                inst.Reflectance = 0
                inst.CastShadow = false
            end)
        end
    end
    win:Notify(string.format("render sweep: %d objects", seen), "ok")
end

function Features.tickRate(on)
    if setfpscap then pcall(setfpscap, on and 240 or 60) end
end

function Features.blackScreen(on)
    if on then
        if not State.blackout then
            State.blackout = Hub.create("Frame", {
                Name = "Blackout", Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Color3.new(), BorderSizePixel = 0,
                ZIndex = -10,
            }, win.gui)
        end
        State.blackout.Visible = true
    elseif State.blackout then
        State.blackout.Visible = false
    end
end

-- Pets are the heaviest thing on screen in these games; hiding them is the
-- single biggest client-side win after the render sweep.
function Features.hidePets(on)
    local plots = Adapter.containers.plots
    if not plots then return end
    for _, d in plots:GetDescendants() do
        local lower = string.lower(d.Name)
        if string.find(lower, "pet", 1, true) and d:IsA("BasePart") then
            pcall(function() d.Transparency = on and 1 or 0 end)
        end
    end
end

------------------------------------------------------------------------ esp
local function clearESP()
    for inst, highlight in State.esp do
        pcall(function() highlight:Destroy() end)
        State.esp[inst] = nil
    end
end

local function markESP(model, text, colour)
    if State.esp[model] then
        local existing = State.esp[model]:FindFirstChild("Tag")
        if existing then
            local body = existing:FindFirstChildWhichIsA("TextLabel")
            if body then body.Text = text end
        end
        return
    end

    local highlight = Instance.new("Highlight")
    highlight.FillColor = colour
    highlight.FillTransparency = 0.55
    highlight.OutlineColor = colour
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Adornee = model
    highlight.Parent = win.gui

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "Tag"
    billboard.Adornee = model:IsA("Model")
        and (model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart"))
        or model
    billboard.Size = UDim2.fromOffset(170, 30)
    billboard.StudsOffset = Vector3.new(0, 2.5, 0)
    billboard.AlwaysOnTop = true
    billboard.Parent = highlight

    local body = Instance.new("TextLabel")
    body.BackgroundTransparency = 1
    body.Size = UDim2.fromScale(1, 1)
    body.Font = Enum.Font.GothamBold
    body.TextSize = 12
    body.TextColor3 = colour
    body.TextStrokeTransparency = 0.4
    body.Text = text
    body.Parent = billboard

    State.esp[model] = highlight
end

local RARITY_COLOUR = {
    Common = Color3.fromRGB(180, 185, 195),
    Uncommon = Color3.fromRGB(120, 210, 130),
    Rare = Color3.fromRGB(90, 160, 235),
    Epic = Color3.fromRGB(175, 120, 235),
    Legendary = Color3.fromRGB(240, 190, 80),
    Mythic = Color3.fromRGB(235, 110, 110),
    Cosmic = Color3.fromRGB(140, 240, 235),
    Divine = Color3.fromRGB(255, 245, 170),
    Eternal = Color3.fromRGB(255, 140, 220),
    Secret = Color3.fromRGB(255, 255, 255),
}

function Features.refreshESP()
    local wantEggs = win:Get("EggESP") == true
    local wantPens = win:Get("PenESP") == true

    if not wantEggs and not wantPens then
        clearESP()
        return
    end

    local live = {}

    if wantEggs then
        local areaFilter = win:Get("EggESPAreas")
        for _, model in Features.eggs() do
            local info = readInfo(model)
            local pass = true
            if type(areaFilter) == "table" and next(areaFilter) and info.area then
                pass = areaFilter[info.area] == true
            end
            if pass then
                live[model] = true
                local bits = { info.name }
                if info.rarity then table.insert(bits, info.rarity) end
                if info.kg then table.insert(bits, string.format("%.1fkg", info.kg)) end
                markESP(model, table.concat(bits, " | "),
                    RARITY_COLOUR[info.rarity] or Hub.THEME.accent)
            end
        end
    end

    if wantPens then
        local plots = Adapter.containers.plots
        if plots then
            for _, plot in plots:GetChildren() do
                local owner = ownerOf(plot)
                if owner then
                    live[plot] = true
                    markESP(plot, "Pen: " .. tostring(owner), Hub.THEME.warn)
                end
            end
        end
    end

    for model, highlight in State.esp do
        if not live[model] or not model.Parent then
            pcall(function() highlight:Destroy() end)
            State.esp[model] = nil
        end
    end
end

-- Every model in the game that looks like an egg, excluding your own pen.
function Features.eggs()
    local found = {}
    local source = Adapter.containers.eggs or Adapter.containers.plots or workspace
    local myName = lp().Name

    local ok, descendants = pcall(function() return source:GetDescendants() end)
    if not ok then return found end

    for _, d in descendants do
        if d:IsA("Model") and string.find(string.lower(d.Name), "egg", 1, true) then
            local full = d:GetFullName()
            if not string.find(full, myName, 1, true) then
                table.insert(found, d)
            end
        end
    end
    return found
end

------------------------------------------------------------------- anti afk
function Features.antiAFK(on)
    if on and not State.afkConn then
        State.afkConn = win:Track(lp().Idled:Connect(function()
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end))
    elseif not on and State.afkConn then
        State.afkConn:Disconnect()
        State.afkConn = nil
    end
end

-------------------------------------------------------------------- webhook
local webhookQueue, webhookBusy = {}, false

local function httpPost(url, body)
    local request = ENV.request or ENV.http_request
        or (ENV.syn and ENV.syn.request)
    if not request then return false, "no request function" end
    local ok, response = pcall(request, {
        Url = url,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode(body),
    })
    if not ok then return false, tostring(response) end
    local status = tonumber(response.StatusCode or response.Status) or 0
    return status >= 200 and status < 300, status
end

-- Discord rate limits hard, so posts are queued and drained one per second.
function Features.webhook(title, description, colour)
    local url = win:Get("WebhookURL", "")
    if type(url) ~= "string" or not string.find(url, "discord", 1, true) then
        return
    end

    table.insert(webhookQueue, {
        embeds = {{
            title = title,
            description = description,
            color = colour or 0x58D68D,
            footer = { text = "SyncHub - " .. lp().Name },
            timestamp = DateTime.now():ToIsoDate(),
        }},
    })

    if webhookBusy then return end
    webhookBusy = true
    task.spawn(function()
        while #webhookQueue > 0 do
            local payload = table.remove(webhookQueue, 1)
            httpPost(url, payload)
            task.wait(1.1)
        end
        webhookBusy = false
    end)
end

--------------------------------------------------------------------- server
-- A teleport tears down the Lua VM, so the hub dies on rejoin and on every
-- server hop unless the executor is told to run it again on the other side.
local RELOAD = 'loadstring(game:HttpGet("' .. REPO .. 'sae.lua"))()'

local function persistThroughTeleport()
    local queue = ENV.queue_on_teleport or queue_on_teleport
    if not queue then
        win:Notify("executor has no queue_on_teleport - reload manually "
            .. "after the hop", "warn", 6)
        return false
    end
    local ok = pcall(queue, RELOAD)
    return ok
end

function Features.rejoin()
    persistThroughTeleport()
    if #Players:GetPlayers() <= 1 then
        pcall(function() TeleportService:Teleport(game.PlaceId, lp()) end)
    else
        pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp())
        end)
    end
end

function Features.serverHop()
    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100",
        game.PlaceId)

    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok then return win:Notify("hop failed: http", "bad") end

    local decoded, payload = pcall(function() return HttpService:JSONDecode(body) end)
    if not decoded or type(payload.data) ~= "table" then
        return win:Notify("hop failed: parse", "bad")
    end

    for _, server in payload.data do
        if server.id ~= game.JobId and server.playing < server.maxPlayers then
            win:Notify("hopping...", "warn")
            persistThroughTeleport()
            local sent = pcall(function()
                TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, lp())
            end)
            if sent then return end
        end
    end
    win:Notify("no open server found", "bad")
end

--=========================================================================--
--                               AUTOMATION                                --
--=========================================================================--
-- Your own pen, found by owner attribute rather than by index, because plot
-- numbering is not stable across servers.
function Features.myPen()
    local plots = Adapter.containers.plots
    if not plots then return nil end
    local myName = lp().Name
    for _, plot in plots:GetChildren() do
        if ownerOf(plot) == myName then return plot end
    end
    return nil
end

local function pivotOf(model)
    if not model then return nil end
    if model:IsA("BasePart") then return model.Position end
    local ok, pivot = pcall(function() return model:GetPivot().Position end)
    if ok then return pivot end
    local part = model:FindFirstChildWhichIsA("BasePart")
    return part and part.Position or nil
end

local function nearTrap(position)
    if win:Get("PreventTraps") ~= true then return false end
    local plots = Adapter.containers.plots
    if not plots or not position then return false end
    for _, d in plots:GetDescendants() do
        if d:IsA("BasePart") then
            local lower = string.lower(d.Name)
            if string.find(lower, "trap", 1, true)
                or string.find(lower, "guard", 1, true) then
                if (d.Position - position).Magnitude < 12 then return true end
            end
        end
    end
    return false
end

-- One steal attempt: pick the best egg that passes the filter, go to it, fire
-- the bound remote, come home.
function Features.stealOnce()
    if not Adapter:bound("Steal") then
        win:Notify("Steal is unbound - see the REMOTES tab", "warn", 5)
        return false
    end

    local origin = pivotOf(char())
    local best, bestScore = nil, -math.huge

    for _, model in Features.eggs() do
        local info = readInfo(model)
        if matchesFilter(info) then
            local position = pivotOf(model)
            if position and not nearTrap(position) then
                local score = scoreOf(info, origin)
                if score > bestScore then
                    best, bestScore = info, score
                end
            end
        end
    end

    if not best then return false end

    local home = pivotOf(Features.myPen())
    local target = pivotOf(best.instance)
    if not target then return false end

    Features.moveTo(target, win:Get("StealSpeed", 120))
    local ok = Adapter:invoke("Steal", best.instance)

    if ok then
        State.steals += 1
        State.lastSteal = os.time()
        if win:Get("WebhookSteals") == true then
            Features.webhook("Egg stolen", string.format(
                "**%s**\nRarity: %s\nWeight: %s kg\nTotal this session: %d",
                best.name, tostring(best.rarity or "?"),
                tostring(best.kg or "?"), State.steals))
        end
    end

    if home then Features.moveTo(home, win:Get("StealSpeed", 120)) end
    return ok
end

-- Most automations are "fire this remote on a timer". One helper covers them
-- all, so adding a new one is a single line in the UI section.
local function simpleWorker(idx, action, interval)
    local warned = false
    win:Loop(interval, function()
        if not Adapter:bound(action) then
            if not warned then
                warned = true
                win:Notify(action .. " is unbound", "warn", 4)
            end
            return
        end
        warned = false
        Adapter:invoke(action)
    end, function()
        return win:Get(idx) == true
    end)
end

--=========================================================================--
--                                   UI                                    --
--=========================================================================--
local tabHome     = win:Tab("HOME")
local tabEggs     = win:Tab("EGGS")
local tabProgress = win:Tab("PROGRESS")
local tabSell     = win:Tab("SELL")
local tabRemotes  = win:Tab("REMOTES")
local tabSettings = win:Tab("SETTINGS")
local tabWebhook  = win:Tab("WEBHOOK")

------------------------------------------------------------------------ home
do
    local session = tabHome:Group("Session")
    local statLines = {
        session:Label("uptime: 00:00:00"),
        session:Label("steals: 0"),
        session:Label("eggs visible: 0"),
        session:Label("remotes found: 0"),
    }

    win:Loop(1, function()
        statLines[1].Set("uptime: " .. elapsed())
        statLines[2].Set(string.format("steals: %d   hatches: %d",
            State.steals, State.hatches))
        statLines[3].Set("eggs visible: " .. #Features.eggs())

        local count = 0
        for _ in Adapter.remotes do count += 1 end
        statLines[4].Set("remotes found: " .. count)

        if win:Get("ShowStatusOverlay") == true then
            win:OverlaySet("up", "uptime " .. elapsed())
            win:OverlaySet("steal", "steals " .. State.steals)
            win:OverlaySet("ping", string.format("players %d/%d",
                #Players:GetPlayers(), Players.MaxPlayers))
        end
    end)

    local server = tabHome:Group("Server")
    server:Button("Rejoin", Features.rejoin)
    server:Button("Server hop", Features.serverHop)
    server:Button("Copy JobId", function()
        if setclipboard then setclipboard(game.JobId) end
        win:Notify("JobId copied", "ok")
    end)
    server:Button("Rescan remotes", function()
        win:Notify(Adapter:scan() .. " remotes found", "ok")
    end)
    server:Button("Unload hub", function() win:Destroy() end)
end

------------------------------------------------------------------------ eggs
do
    local filter = tabEggs:Group("Steal filter")
    filter:Dropdown("TargetRarities", "Rarities", RARITIES, {}, true)
    filter:Dropdown("TargetAreas", "Areas", AREAS, {}, true)
    filter:Dropdown("TargetPriority", "Priority", PRIORITIES, "Rarity")
    filter:Dropdown("TargetKGMode", "Weight mode", KG_MODES, "Any")
    filter:Slider("TargetKGThreshold", "Weight threshold", 0, 100, 0, 1)

    local steal = tabEggs:Group("Auto steal")
    steal:Toggle("AutoSteal", "Auto steal", false)
    steal:Toggle("PersistentSteal", "Retry on failure", true)
    steal:Toggle("PreventTraps", "Avoid traps and guards", true)
    steal:Dropdown("StealMode", "Travel mode", MOVE_MODES, "Walk")
    steal:Label("Walk is real movement and cannot be detected. Glide is "
        .. "capped per frame. Teleport is fast and the most likely to get "
        .. "you kicked.")
    steal:Slider("StealSpeed", "Glide speed", 40, 400, 120, 10)
    steal:Slider("StealDelay", "Delay between steals", 0.5, 15, 3, 0.5)
    steal:Slider("MoveTimeout", "Give up after", 5, 60, 20, 1)
    steal:Button("Steal once (test)", function()
        local ok = Features.stealOnce()
        win:Notify(ok and "steal fired" or "no valid target", ok and "ok" or "warn")
    end)

    local place = tabEggs:Group("Auto place / hatch", true)
    place:Toggle("AutoPlace", "Auto place eggs", false)
    place:Toggle("AutoHatch", "Auto hatch", false)
    place:Slider("HatchInterval", "Hatch interval", 0.5, 30, 2, 0.5)

    -- The steal loop is hand written because it has real logic; everything
    -- else on this tab is a timed remote call.
    win:Loop(0.1, function()
        local ok = Features.stealOnce()
        if not ok and win:Get("PersistentSteal") ~= true then
            task.wait(2)
        end
        task.wait(tonumber(win:Get("StealDelay", 1)) or 1)
    end, function()
        return win:Get("AutoSteal") == true
    end)

    simpleWorker("AutoPlace", "Place", 1.5)
    win:Loop(0.5, function()
        Adapter:invoke("Hatch")
        State.hatches += 1
        if win:Get("WebhookHatches") == true then
            Features.webhook("Egg hatched", "Session total: " .. State.hatches)
        end
        task.wait(tonumber(win:Get("HatchInterval", 2)) or 2)
    end, function()
        return win:Get("AutoHatch") == true and Adapter:bound("Hatch")
    end)
end

-------------------------------------------------------------------- progress
do
    local cash = tabProgress:Group("Economy")
    cash:Toggle("AutoCollectCash", "Auto collect cash", true)
    cash:Toggle("AutoOpenChest", "Auto open chests", true)
    cash:Toggle("AutoSkipChest", "Auto skip chest timer", true)
    cash:Toggle("AutoClaimIndex", "Auto claim index rewards", true)

    local pets = tabProgress:Group("Pets")
    pets:Toggle("AutoEquipBest", "Equip best pets", true)
    pets:Slider("EquipInterval", "Equip interval", 5, 300, 30, 5)

    local upgrades = tabProgress:Group("Upgrades")
    upgrades:Toggle("AutoUpgradePen", "Auto upgrade pen", true)
    upgrades:Toggle("AutoTreadmill", "Auto treadmill", true)
    upgrades:Toggle("AutoUpgradeTreadmill", "Auto upgrade treadmill", true)
    upgrades:Toggle("AutoBuyTrail", "Auto buy trail", false)

    local event = tabProgress:Group("Event")
    event:Toggle("AutoHungryMonster", "Auto hungry monster", false)
    event:Label("Feeds the monster with anything not protected below.")
    event:Dropdown("MonsterProtected", "Never feed", RARITIES,
        { Divine = true, Eternal = true, Secret = true }, true)

    simpleWorker("AutoCollectCash", "CollectCash", 1)
    simpleWorker("AutoOpenChest", "OpenChest", 2)
    simpleWorker("AutoSkipChest", "SkipChest", 2)
    simpleWorker("AutoClaimIndex", "ClaimIndex", 10)
    simpleWorker("AutoUpgradePen", "UpgradePen", 5)
    simpleWorker("AutoTreadmill", "Treadmill", 3)
    simpleWorker("AutoUpgradeTreadmill", "UpgradeTreadmill", 8)
    simpleWorker("AutoBuyTrail", "BuyTrail", 15)
    simpleWorker("AutoHungryMonster", "HungryMonster", 4)

    win:Loop(1, function()
        Adapter:invoke("EquipBest")
        task.wait(tonumber(win:Get("EquipInterval", 30)) or 30)
    end, function()
        return win:Get("AutoEquipBest") == true and Adapter:bound("EquipBest")
    end)
end

------------------------------------------------------------------------ sell
do
    local pets = tabSell:Group("Sell pets")
    pets:Toggle("AutoSellPets", "Auto sell pets", false)
    pets:Toggle("SellPetsWhenFull", "Only when inventory full", false)
    pets:Dropdown("SellRarities", "Rarities to sell", RARITIES, {}, true)
    pets:Dropdown("SellPetKGMode", "Weight mode", KG_MODES, "Any")
    pets:Slider("SellPetKGThreshold", "Weight threshold", 0, 100, 0, 1)

    local eggs = tabSell:Group("Sell eggs")
    eggs:Toggle("AutoSellEggs", "Auto sell eggs", false)
    eggs:Toggle("SellEggsWhenFull", "Only when inventory full", false)
    eggs:Dropdown("SellEggRarities", "Rarities to sell", RARITIES, {}, true)
    eggs:Slider("SellEggKGThreshold", "Weight threshold", 0, 100, 0, 1)

    simpleWorker("AutoSellPets", "SellPet", 5)
    simpleWorker("AutoSellEggs", "SellEgg", 5)
end

--------------------------------------------------------------------- remotes
do
    local capture = tabRemotes:Group("Remote logger")
    capture:Label("1. Turn logging on. 2. Do the action once by hand. "
        .. "3. Dump the log and note the number. 4. Bind it below.")
    capture:Toggle("RemoteLogging", "Log outgoing remotes", false, function(on)
        State.logging = on
        if on and not Logger:install() then
            win:Notify("executor lacks hookmetamethod", "bad", 6)
        end
    end)
    capture:Button("Dump log to file + clipboard", function()
        if #State.log == 0 then return win:Notify("log is empty", "warn") end
        Logger:dump()
        win:Notify(#State.log .. " calls written to " .. DIR .. "/remotes.txt", "ok")
    end)
    capture:Button("Clear log", function()
        State.log, State.logSeen = {}, {}
        win:Notify("log cleared", "ok")
    end)

    local bind = tabRemotes:Group("Bind a call to an action")
    bind:Dropdown("BindAction", "Action", ACTIONS, "Steal")
    bind:Input("BindIndex", "Log entry number", "1")
    bind:Button("Bind", function()
        local action = win:Get("BindAction", "Steal")
        local index = tonumber(win:Get("BindIndex", "1"))
        local entry = index and State.log[index]
        if not entry then return win:Notify("no log entry " .. tostring(index), "bad") end

        -- Instance arguments are stored as a marker so the automation can
        -- substitute a live target at call time.
        local args = {}
        for i, value in entry.args do
            args[i] = typeof(value) == "Instance" and "%s" or value
        end

        win:Set("bind_" .. action, {
            remote = entry.remote,
            method = entry.method,
            args   = args,
        })
        win:Notify(action .. " -> " .. entry.remote, "ok", 5)
    end)
    bind:Button("Show current bindings", function()
        local lines = {}
        for _, action in ACTIONS do
            local binding = win:Get("bind_" .. action)
            table.insert(lines, string.format("%-18s %s", action,
                type(binding) == "table" and binding.remote or "-"))
        end
        local report = table.concat(lines, "\n")
        print(report)
        if setclipboard then setclipboard(report) end
        win:Notify("bindings printed to console", "ok")
    end)
    bind:Button("Clear all bindings", function()
        for _, action in ACTIONS do win:Set("bind_" .. action, nil) end
        win:Notify("bindings cleared", "warn")
    end)
end

-------------------------------------------------------------------- settings
do
    local movement = tabSettings:Group("Movement")
    movement:Slider("WalkSpeed", "Walk speed", 16, 120, 16, 1, Features.applyCharacter)
    movement:Slider("JumpPower", "Jump power", 50, 150, 50, 5, Features.applyCharacter)
    movement:Toggle("Noclip", "Noclip", false, Features.noclip)
    movement:Toggle("InfiniteJump", "Infinite jump", false, Features.infiniteJump)
    movement:Label("Walk speed above about 40 and noclip are what simple "
        .. "anti-cheats look for. Raise them a little at a time.")

    local perf = tabSettings:Group("Performance")
    perf:Toggle("ExtremeFPS", "Extreme FPS mode", false, function(on)
        if on then task.spawn(Features.extremeFPS) end
    end)
    perf:Toggle("BoostTickRate", "Uncap FPS", false, Features.tickRate)
    perf:Toggle("HidePets", "Hide pets", false, Features.hidePets)
    perf:Toggle("BlackScreen", "Black screen", false, Features.blackScreen)
    perf:Button("Run render sweep now", function()
        task.spawn(Features.extremeFPS)
    end)

    local esp = tabSettings:Group("ESP")
    esp:Toggle("EggESP", "Egg ESP", false)
    esp:Toggle("PenESP", "Pen ESP", false)
    esp:Dropdown("EggESPAreas", "Only these areas", AREAS, {}, true)
    esp:Slider("ESPRefresh", "Refresh rate", 0.2, 5, 1, 0.1)

    local misc = tabSettings:Group("Misc")
    misc:Toggle("AntiAFK", "Anti AFK", true, Features.antiAFK)
    misc:Toggle("ShowStatusOverlay", "Status overlay", true, function(on)
        win:Overlay(on)
    end)
    misc:Keybind("MenuKey", "Toggle menu", Enum.KeyCode.RightShift, function()
        win:ToggleVisible()
    end)

    local config = tabSettings:Group("Config")
    config:Input("ConfigName", "Config name", "default")
    config:Button("Save", function()
        win:SaveConfig(win:Get("ConfigName", "default"))
    end)
    config:Button("Load", function()
        win:LoadConfig(win:Get("ConfigName", "default"))
    end)
    config:Button("List saved configs", function()
        local names = win:ListConfigs()
        win:Notify(#names > 0 and table.concat(names, ", ") or "none saved", "ok", 6)
    end)

    win:Loop(1, function()
        Features.refreshESP()
        task.wait(tonumber(win:Get("ESPRefresh", 1)) or 1)
    end, function()
        return win:Get("EggESP") == true or win:Get("PenESP") == true
    end)
end

--------------------------------------------------------------------- webhook
do
    local hook = tabWebhook:Group("Webhook")
    hook:Input("WebhookURL", "Discord webhook URL", "")
    hook:Button("Send test message", function()
        Features.webhook("SyncHub online",
            string.format("Player: %s\nServer: %d players", lp().Name,
                #Players:GetPlayers()))
        win:Notify("test queued", "ok")
    end)

    local alerts = tabWebhook:Group("Alerts")
    alerts:Toggle("WebhookSteals", "On steal", false)
    alerts:Toggle("WebhookHatches", "On hatch", false)
    alerts:Toggle("WebhookDisconnects", "On disconnect", false)
    alerts:Toggle("WebhookInventoryFull", "On inventory full", false)
    alerts:Label("The URL stays in your local config and is only ever "
        .. "posted to Discord.")
end

--=========================================================================--
--                                  BOOT                                   --
--=========================================================================--
local found = Adapter:scan()

Journal:reset()
Journal:write("boot: %d remotes, hook=%s, queue_on_teleport=%s",
    found, tostring(hookmetamethod ~= nil),
    tostring((ENV.queue_on_teleport or queue_on_teleport) ~= nil))

win:Track(lp().CharacterAdded:Connect(function()
    task.wait(0.6)
    Journal:write("respawn")
    Features.applyCharacter()
    if State.noclip then Features.noclip(true) end
end))

if win:Get("ShowStatusOverlay") ~= false then win:Overlay(true) end

-- Re-scan periodically: streaming and round resets add remotes after join.
win:Loop(30, function() Adapter:scan() end)

win:Select("HOME")
win:SetStatus(string.format("%d remotes | %s", found,
    (hookmetamethod and "hook ok") or "no hook"), Hub.THEME.accent)

win:Notify(string.format("SyncHub ready. %d remotes discovered.", found), "ok", 5)
if not hookmetamethod then
    win:Notify("This executor cannot log remotes. Automation will need "
        .. "manual bindings.", "warn", 8)
end

win.onDestroy = function()
    State.logging = false
    clearESP()
    Features.noclip(false)
    Features.blackScreen(false)
end

return win


