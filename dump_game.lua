--!nonstrict
--[[
    dump_game.lua - read-only reconnaissance for Steal an Egg (or any game).

    Run once in the game, then send me SyncHub/dump.txt. Nothing is fired,
    nothing is changed; this only walks the tree and prints what it finds so
    the hub's features can be bound to the game's real remotes instead of
    guessed names.
--]]

local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService      = game:GetService("HttpService")

local MAX_DEPTH   = 4      -- how deep to walk workspace containers
local MAX_SIBLING = 12     -- children listed per container before summarising
local lp          = Players.LocalPlayer

local out = {}
local function add(fmt, ...)
    table.insert(out, select("#", ...) > 0 and string.format(fmt, ...) or fmt)
end

local function safe(fn, fallback)
    local ok, result = pcall(fn)
    return ok and result or fallback
end

------------------------------------------------------------------ environment
add("== environment ==")
add("executor    : %s", safe(function()
    return identifyexecutor and identifyexecutor() or "unknown"
end, "unknown"))
add("game        : %s", safe(function()
    return game:GetService("MarketplaceService")
        :GetProductInfo(game.PlaceId).Name
end, "?"))
add("PlaceId     : %d", game.PlaceId)
add("GameId      : %d", game.GameId)
add("player      : %s (%d)", lp and lp.Name or "?", lp and lp.UserId or 0)
add("capabilities: hookmetamethod=%s getnamecallmethod=%s getconnections=%s firesignal=%s getgc=%s",
    type(hookmetamethod), type(getnamecallmethod), type(getconnections),
    type(firesignal), type(getgc))

------------------------------------------------------------------- leaderstats
add("\n== leaderstats / player values ==")
local stats = lp and lp:FindFirstChild("leaderstats")
if stats then
    for _, v in stats:GetChildren() do
        add("  %s = %s (%s)", v.Name, tostring(safe(function() return v.Value end, "?")), v.ClassName)
    end
else
    add("  (no leaderstats)")
end
for _, name in { "Attributes", "Data", "PlayerData", "Stats" } do
    local folder = lp and lp:FindFirstChild(name)
    if folder then
        add("  [%s]", name)
        for _, v in folder:GetChildren() do
            add("    %s = %s (%s)", v.Name,
                tostring(safe(function() return v.Value end, "-")), v.ClassName)
        end
    end
end
local attrs = lp and safe(function() return lp:GetAttributes() end, nil)
if attrs then
    for k, v in attrs do add("  attr %s = %s", k, tostring(v)) end
end

----------------------------------------------------------------------- remotes
add("\n== remotes ==")
local remoteClasses = {
    RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true,
}
local remotes = {}
for _, service in { ReplicatedStorage, workspace, game:GetService("Lighting"),
                    game:GetService("StarterGui") } do
    for _, d in safe(function() return service:GetDescendants() end, {}) do
        if remoteClasses[d.ClassName] then
            table.insert(remotes, { path = d:GetFullName(), class = d.ClassName })
        end
    end
end
table.sort(remotes, function(a, b) return a.path < b.path end)
add("  %d found", #remotes)
for _, r in remotes do
    add("  %-22s %s", r.class, r.path)
end

----------------------------------------------------------------------- modules
add("\n== ReplicatedStorage modules (top 60) ==")
local modules = {}
for _, d in safe(function() return ReplicatedStorage:GetDescendants() end, {}) do
    if d.ClassName == "ModuleScript" then
        table.insert(modules, d:GetFullName())
    end
end
table.sort(modules)
for i = 1, math.min(#modules, 60) do add("  %s", modules[i]) end
if #modules > 60 then add("  ... %d more", #modules - 60) end

--------------------------------------------------------------------- workspace
add("\n== workspace tree ==")
local skip = { Terrain = true, Camera = true, CurrentCamera = true }

local function walk(node, depth, prefix)
    if depth > MAX_DEPTH then return end
    local children = safe(function() return node:GetChildren() end, {})
    local shown = 0
    for _, child in children do
        if not skip[child.Name] and not skip[child.ClassName] then
            shown += 1
            if shown > MAX_SIBLING then
                add("%s... %d more siblings", prefix, #children - MAX_SIBLING)
                break
            end
            local kids = #safe(function() return child:GetChildren() end, {})
            local extra = ""
            if child:IsA("BasePart") or child:IsA("Model") then
                local pos = safe(function()
                    return child:IsA("Model")
                        and (child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")).Position
                        or child.Position
                end, nil)
                if pos then
                    extra = string.format("  @(%d,%d,%d)",
                        math.floor(pos.X), math.floor(pos.Y), math.floor(pos.Z))
                end
            end
            add("%s%s [%s] %s%s", prefix, child.Name, child.ClassName,
                kids > 0 and ("{" .. kids .. "}") or "", extra)
            if kids > 0 then walk(child, depth + 1, prefix .. "  ") end
        end
    end
end
walk(workspace, 1, "  ")

---------------------------------------------------------- interesting keywords
add("\n== keyword matches (plots / eggs / steal / conveyor) ==")
local keywords = {
    "plot", "base", "egg", "steal", "hatch", "conveyor", "spawn", "claim",
    "pet", "podium", "stand", "lock", "barrier", "cash", "money", "sell",
}
local hits, seen = {}, {}
for _, d in safe(function() return workspace:GetDescendants() end, {}) do
    local lower = string.lower(d.Name)
    for _, word in keywords do
        if string.find(lower, word, 1, true) then
            local key = d.Name .. "|" .. d.ClassName
            if not seen[key] then
                seen[key] = true
                table.insert(hits, string.format("  %-28s [%-16s] %s",
                    d.Name, d.ClassName, d:GetFullName()))
            end
            break
        end
    end
end
table.sort(hits)
for i = 1, math.min(#hits, 120) do add("%s", hits[i]) end
if #hits > 120 then add("  ... %d more unique names", #hits - 120) end

------------------------------------------------------------------- player gui
add("\n== PlayerGui screens ==")
local pg = lp and lp:FindFirstChild("PlayerGui")
if pg then
    for _, screen in pg:GetChildren() do
        add("  %s [%s] visible=%s children=%d", screen.Name, screen.ClassName,
            tostring(safe(function() return screen.Enabled end, "-")),
            #screen:GetChildren())
    end
end

-------------------------------------------------------------------- character
add("\n== character ==")
local char = lp and lp.Character
if char then
    for _, d in char:GetChildren() do
        if not d:IsA("BasePart") then
            add("  %s [%s]", d.Name, d.ClassName)
        end
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        add("  WalkSpeed=%s JumpPower=%s HipHeight=%s",
            tostring(hum.WalkSpeed), tostring(hum.JumpPower), tostring(hum.HipHeight))
    end
end
local bp = lp and lp:FindFirstChild("Backpack")
if bp then
    add("  backpack:")
    for _, tool in bp:GetChildren() do
        add("    %s [%s]", tool.Name, tool.ClassName)
    end
end

------------------------------------------------------------------------ output
local report = table.concat(out, "\n")
print(report)

if writefile then
    pcall(function()
        if isfolder and makefolder and not isfolder("SyncHub") then makefolder("SyncHub") end
        writefile("SyncHub/dump.txt", report)
        print("\n[dump] saved to SyncHub/dump.txt (" .. #report .. " bytes)")
    end)
end
if setclipboard then
    pcall(setclipboard, report)
    print("[dump] copied to clipboard")
end

return report
