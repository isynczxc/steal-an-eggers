--!nonstrict
--[[
    synchub.lua - v2 UI framework. Yours end to end: no key, no remote fetch,
    no external library.

        local Hub = loadstring(readfile("SyncHub/synchub.lua"))()
        local win = Hub.new("SyncHub", "SyncHub/StealAnEgg")

        local tab = win:Tab("HOME", "Live")
        local box = tab:Group("Stats")
        box:Toggle("AutoSteal", "Auto Steal", false, function(on) end)
        box:Slider("StealSpeed", "Speed", 100, 1200, 960, 10, function(v) end)
        box:Dropdown("TargetPriority", "Priority", {"Rarity","KG"}, "Rarity", false, fn)
        box:Dropdown("TargetRarities", "Rarities", RARITIES, {}, true, fn)
        box:Input("Webhook", "URL", "", fn)
        box:Keybind("ToggleUI", "Menu", Enum.KeyCode.RightShift, fn)

    Every widget takes an `idx` as its first argument. That idx is the config
    key, so saving is automatic and renaming a label never breaks a saved file.

    Re-executing hot-reloads: the previous window is destroyed first.
--]]

local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")

local ENV = (typeof(getgenv) == "function" and getgenv()) or _G
local hasFS = isfile and readfile and writefile and isfolder and makefolder

local THEME = {
    bg      = Color3.fromRGB(18, 19, 24),
    panel   = Color3.fromRGB(24, 26, 32),
    bar     = Color3.fromRGB(28, 30, 37),
    row     = Color3.fromRGB(33, 35, 43),
    rowHi   = Color3.fromRGB(41, 44, 54),
    accent  = Color3.fromRGB(88, 214, 141),
    warn    = Color3.fromRGB(232, 176, 84),
    bad     = Color3.fromRGB(226, 98, 98),
    off     = Color3.fromRGB(58, 61, 72),
    text    = Color3.fromRGB(236, 238, 243),
    dim     = Color3.fromRGB(146, 152, 166),
    stroke  = Color3.fromRGB(44, 47, 57),
}

local TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--------------------------------------------------------------------- helpers
local function create(class, props, parent)
    local inst = Instance.new(class)
    for k, v in props do
        inst[k] = v
    end
    if parent then inst.Parent = parent end
    return inst
end

local function corner(inst, radius)
    create("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, inst)
    return inst
end

local function stroke(inst, colour, thickness)
    create("UIStroke", {
        Color = colour or THEME.stroke,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
    return inst
end

local function list(parent, padding)
    return create("UIListLayout", {
        Padding = UDim.new(0, padding or 5),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, parent)
end

local function pad(parent, all)
    return create("UIPadding", {
        PaddingLeft = UDim.new(0, all or 8), PaddingRight = UDim.new(0, all or 8),
        PaddingTop = UDim.new(0, all or 8), PaddingBottom = UDim.new(0, all or 8),
    }, parent)
end

local function label(parent, text, size, colour, bold)
    return create("TextLabel", {
        BackgroundTransparency = 1,
        Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham,
        TextSize = size or 12,
        TextColor3 = colour or THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = text,
    }, parent)
end

local function join(values)
    local parts = {}
    for value, on in values do
        if on then table.insert(parts, tostring(value)) end
    end
    table.sort(parts)
    return parts
end

--=========================================================================--
--                                 WINDOW                                  --
--=========================================================================--
local Window = {}
Window.__index = Window

function Window.new(title, dir)
    local self = setmetatable({}, Window)

    self.title       = title or "SyncHub"
    self.dir         = dir or "SyncHub"
    self.cfgDir      = self.dir .. "/configs"
    self.connections = {}
    self.loops       = {}
    self.widgets     = {}          -- idx -> widget handle
    self.tabs        = {}
    self.keybinds    = {}
    self.config      = {}
    self.activeTab   = nil
    self.order       = 0
    self.uiVisible   = true

    self:_ensureDirs()
    self.config = self:LoadConfig("default", true)
    self:_build()
    self:_bindHotkeys()
    return self
end

------------------------------------------------------------------- config io
function Window:_ensureDirs()
    if not hasFS then return end
    pcall(function()
        if not isfolder(self.dir) then makefolder(self.dir) end
        if not isfolder(self.cfgDir) then makefolder(self.cfgDir) end
    end)
end

function Window:_cfgPath(name)
    return self.cfgDir .. "/" .. (name or "default") .. ".json"
end

-- Reads a config file into a plain table. Does not apply it.
function Window:ReadConfig(name)
    if not hasFS then return {} end
    local path = self:_cfgPath(name)
    if not isfile(path) then return {} end
    local ok, raw = pcall(readfile, path)
    if not ok then return {} end
    local decoded, result = pcall(function() return HttpService:JSONDecode(raw) end)
    return (decoded and type(result) == "table") and result or {}
end

-- Loads a config. `quiet` skips pushing values into widgets, which is what the
-- constructor wants because no widgets exist yet.
function Window:LoadConfig(name, quiet)
    local data = self:ReadConfig(name)
    self.config = data
    self.configName = name or "default"
    if not quiet then
        for idx, widget in self.widgets do
            if data[idx] ~= nil and widget.Set then
                pcall(widget.Set, data[idx], true)
            end
        end
        self:Notify("Loaded config: " .. self.configName, "ok")
    end
    return data
end

function Window:SaveConfig(name)
    name = name or self.configName or "default"
    self.configName = name
    if not hasFS then return false end
    self:_ensureDirs()
    local ok = pcall(function()
        writefile(self:_cfgPath(name), HttpService:JSONEncode(self.config))
    end)
    if ok then self:Notify("Saved config: " .. name, "ok")
    else self:Notify("Save failed", "bad") end
    return ok
end

function Window:ListConfigs()
    local names = {}
    if not hasFS or not listfiles then return names end
    local ok, files = pcall(listfiles, self.cfgDir)
    if not ok then return names end
    for _, path in files do
        local name = string.match(path, "([^/\\]+)%.json$")
        if name then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

-- Writes are debounced: dragging a slider fires Set on every frame and a
-- writefile per frame will stutter the client. One save, one second after the
-- last change wins.
function Window:Set(idx, value)
    self.config[idx] = value
    if not hasFS or self.autosave == false then return end

    self._saveToken = (self._saveToken or 0) + 1
    local token = self._saveToken
    task.delay(1, function()
        if self._saveToken ~= token then return end
        pcall(function()
            writefile(self:_cfgPath(self.configName or "default"),
                HttpService:JSONEncode(self.config))
        end)
    end)
end

function Window:Get(idx, fallback)
    local value = self.config[idx]
    return value == nil and fallback or value
end

------------------------------------------------------------------- lifetime
function Window:Track(connection)
    table.insert(self.connections, connection)
    return connection
end

-- A loop bound to the window's lifetime. Returns a stop function.
-- `guard` is checked every tick; when it returns false the body is skipped
-- without killing the loop, which is how toggles gate their workers.
function Window:Loop(interval, fn, guard)
    local alive = true
    table.insert(self.loops, function() alive = false end)
    task.spawn(function()
        while alive do
            if not guard or guard() then
                local ok, err = pcall(fn)
                if not ok then warn("[SyncHub] loop: " .. tostring(err)) end
            end
            task.wait(interval)
        end
    end)
    return function() alive = false end
end

function Window:Destroy()
    for _, stop in self.loops do pcall(stop) end
    for _, c in self.connections do pcall(function() c:Disconnect() end) end
    self.loops, self.connections = {}, {}
    if self.onDestroy then pcall(self.onDestroy) end
    if self.gui then pcall(function() self.gui:Destroy() end) end
    if ENV.SyncHub == self then ENV.SyncHub = nil end
end

--------------------------------------------------------------------- build
function Window:_parent()
    if gethui then
        local ok, hidden = pcall(gethui)
        if ok and hidden then return hidden end
    end
    local ok, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if ok and coreGui then return coreGui end
    return Players.LocalPlayer:WaitForChild("PlayerGui")
end

function Window:_build()
    self.gui = create("ScreenGui", {
        Name           = "SyncHub_" .. tostring(math.random(1e5, 1e6)),
        IgnoreGuiInset = true,
        ResetOnSpawn   = false,
        DisplayOrder   = 999,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, self:_parent())

    local root = corner(create("Frame", {
        Name = "Window",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(520, 420),
        BackgroundColor3 = THEME.bg,
        BorderSizePixel = 0,
        Active = true,
        ClipsDescendants = true,
    }, self.gui), 10)
    stroke(root)
    self.root = root

    -- title bar ---------------------------------------------------------
    local bar = create("Frame", {
        Name = "TitleBar", Size = UDim2.new(1, 0, 0, 38),
        BackgroundColor3 = THEME.bar, BorderSizePixel = 0,
    }, root)

    create("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = THEME.stroke, BorderSizePixel = 0,
    }, bar)

    local titleLabel = label(bar, self.title, 14, THEME.text, true)
    titleLabel.Position = UDim2.fromOffset(13, 0)
    titleLabel.Size = UDim2.new(0, 160, 1, 0)

    self.status = label(bar, "", 11, THEME.dim)
    self.status.Position = UDim2.new(0, 180, 0, 0)
    self.status.Size = UDim2.new(1, -250, 1, 0)

    local function barButton(offset, text, colour)
        local button = corner(create("TextButton", {
            AutoButtonColor = false,
            Position = UDim2.new(1, offset, 0.5, -11),
            Size = UDim2.fromOffset(24, 22),
            BackgroundColor3 = THEME.row, BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, TextSize = 14,
            TextColor3 = colour or THEME.dim, Text = text,
        }, bar), 5)
        return button
    end

    local closeButton    = barButton(-30, "x", THEME.bad)
    local minimiseButton = barButton(-60, "-")

    -- tab rail ----------------------------------------------------------
    local rail = create("ScrollingFrame", {
        Name = "Tabs",
        Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = THEME.panel, BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.X,
        ScrollBarThickness = 0,
        ScrollingDirection = Enum.ScrollingDirection.X,
    }, root)
    create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Center,
    }, rail)
    create("UIPadding", {
        PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
    }, rail)
    create("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = THEME.stroke, BorderSizePixel = 0, ZIndex = 2,
    }, rail)
    self.rail = rail

    -- page host ---------------------------------------------------------
    self.pages = create("Frame", {
        Name = "Pages",
        Position = UDim2.fromOffset(0, 72), Size = UDim2.new(1, 0, 1, -72),
        BackgroundTransparency = 1,
    }, root)

    -- toasts ------------------------------------------------------------
    self.toasts = create("Frame", {
        Name = "Toasts",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -12, 1, -12),
        Size = UDim2.fromOffset(250, 300),
        BackgroundTransparency = 1,
    }, self.gui)
    create("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
    }, self.toasts)

    -- mobile reopen bubble ----------------------------------------------
    local bubble = corner(create("TextButton", {
        Name = "Reopen", AutoButtonColor = false, Visible = false,
        Position = UDim2.fromScale(0.02, 0.4), Size = UDim2.fromOffset(44, 44),
        BackgroundColor3 = THEME.accent, BorderSizePixel = 0,
        Font = Enum.Font.GothamBold, TextSize = 17,
        TextColor3 = THEME.bg, Text = "S",
    }, self.gui), 22)
    self.bubble = bubble

    self:Track(minimiseButton.MouseButton1Click:Connect(function()
        self:SetVisible(false)
    end))
    self:Track(bubble.MouseButton1Click:Connect(function()
        self:SetVisible(true)
    end))
    self:Track(closeButton.MouseButton1Click:Connect(function()
        self:Destroy()
    end))

    self:_drag(bar, root)
    self:_drag(bubble, bubble)
end

function Window:SetVisible(visible)
    self.uiVisible = visible and true or false
    self.root.Visible = self.uiVisible
    self.bubble.Visible = not self.uiVisible
end

function Window:ToggleVisible()
    self:SetVisible(not self.uiVisible)
end

function Window:SetStatus(text, colour)
    if not self.status then return end
    self.status.Text = tostring(text or "")
    self.status.TextColor3 = colour or THEME.dim
end

-- Touch and mouse both route through InputBegan/InputChanged.
function Window:_drag(handle, target)
    local dragging, origin, startPos = false, nil, nil

    self:Track(handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging, origin, startPos = true, input.Position, target.Position
            self:Track(input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end))
        end
    end))

    self:Track(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - origin
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))
end

function Window:_bindHotkeys()
    self:Track(UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        for _, bind in self.keybinds do
            if bind.key == input.KeyCode then
                pcall(bind.fn)
            end
        end
    end))
end

--=========================================================================--
--                              TABS & GROUPS                              --
--=========================================================================--
local Tab, Group = {}, {}
Tab.__index, Group.__index = Tab, Group

function Window:Tab(name)
    local win = self
    local self = setmetatable({}, Tab)
    self.win, self.name, self.order = win, name, #win.tabs + 1

    self.button = corner(create("TextButton", {
        Name = name, AutoButtonColor = false,
        Size = UDim2.fromOffset(math.max(58, #name * 8 + 20), 24),
        LayoutOrder = self.order,
        BackgroundColor3 = THEME.row, BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium, TextSize = 12,
        TextColor3 = THEME.dim, Text = name,
    }, win.rail), 5)

    self.page = create("ScrollingFrame", {
        Name = name .. "Page", Visible = false,
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = THEME.off,
    }, win.pages)
    list(self.page, 7)
    pad(self.page, 10)

    win:Track(self.button.MouseButton1Click:Connect(function()
        win:Select(name)
    end))

    win.tabs[name] = self
    if not win.activeTab then win:Select(name) end
    return self
end

function Window:Select(name)
    for tabName, tab in self.tabs do
        local active = tabName == name
        tab.page.Visible = active
        TweenService:Create(tab.button, TWEEN, {
            BackgroundColor3 = active and THEME.accent or THEME.row,
        }):Play()
        tab.button.TextColor3 = active and THEME.bg or THEME.dim
    end
    self.activeTab = name
end

-- A collapsible titled container. The collapsed state persists per title.
function Tab:Group(title, collapsed)
    local tab = self
    local win = tab.win
    local self = setmetatable({}, Group)
    self.win, self.title = win, title

    tab.groupCount = (tab.groupCount or 0) + 1

    local key = "__group_" .. tab.name .. "_" .. title
    local isCollapsed = win:Get(key, collapsed and true or false)

    local frame = corner(create("Frame", {
        Name = title,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = THEME.panel, BorderSizePixel = 0,
        LayoutOrder = tab.groupCount,
        ClipsDescendants = true,
    }, tab.page), 8)
    stroke(frame)
    self.frame = frame

    local header = create("TextButton", {
        Name = "Header", AutoButtonColor = false,
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1, Text = "",
    }, frame)

    local titleLabel = label(header, title, 12, THEME.text, true)
    titleLabel.Position = UDim2.fromOffset(10, 0)
    titleLabel.Size = UDim2.new(1, -40, 1, 0)

    local chevron = label(header, isCollapsed and "+" or "-", 15, THEME.dim, true)
    chevron.Position = UDim2.new(1, -24, 0, 0)
    chevron.Size = UDim2.fromOffset(16, 30)
    chevron.TextXAlignment = Enum.TextXAlignment.Center

    local body = create("Frame", {
        Name = "Body", Visible = not isCollapsed,
        Position = UDim2.fromOffset(0, 30),
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
    }, frame)
    list(body, 5)
    create("UIPadding", {
        PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
    }, body)
    self.body = body
    self.order = 0

    -- The frame auto-sizes from its children, so collapsing means hiding the
    -- body and pinning the height to the header.
    local function render()
        body.Visible = not isCollapsed
        chevron.Text = isCollapsed and "+" or "-"
        frame.AutomaticSize = isCollapsed and Enum.AutomaticSize.None
            or Enum.AutomaticSize.Y
        if isCollapsed then frame.Size = UDim2.new(1, 0, 0, 30) end
    end

    win:Track(header.MouseButton1Click:Connect(function()
        isCollapsed = not isCollapsed
        win:Set(key, isCollapsed)
        render()
    end))

    render()
    return self
end

function Group:_next()
    self.order += 1
    return self.order
end

function Group:_row(height)
    return corner(create("Frame", {
        Size = UDim2.new(1, 0, 0, height or 32),
        LayoutOrder = self:_next(),
        BackgroundColor3 = THEME.row, BorderSizePixel = 0,
    }, self.body), 5)
end

-- Registers a widget so config load can push values back into the UI.
function Group:_register(idx, handle)
    if idx then self.win.widgets[idx] = handle end
    return handle
end

function Group:_fail(idx, err)
    warn("[SyncHub] " .. tostring(idx) .. ": " .. tostring(err))
    self.win:SetStatus("error in " .. tostring(idx), THEME.bad)
end

--------------------------------------------------------------------- widgets
function Group:Label(text)
    local widget = label(self.body, text, 12, THEME.dim)
    widget.Size = UDim2.new(1, 0, 0, 0)
    widget.AutomaticSize = Enum.AutomaticSize.Y
    widget.TextWrapped = true
    widget.TextTruncate = Enum.TextTruncate.None
    widget.LayoutOrder = self:_next()
    return {
        Instance = widget,
        Set = function(value) widget.Text = tostring(value) end,
    }
end

function Group:Divider()
    local line = create("Frame", {
        Size = UDim2.new(1, 0, 0, 1), LayoutOrder = self:_next(),
        BackgroundColor3 = THEME.stroke, BorderSizePixel = 0,
    }, self.body)
    return line
end

function Group:Button(text, callback)
    local button = corner(create("TextButton", {
        Name = text, AutoButtonColor = false,
        Size = UDim2.new(1, 0, 0, 30), LayoutOrder = self:_next(),
        BackgroundColor3 = THEME.row, BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium, TextSize = 12,
        TextColor3 = THEME.text, Text = text,
    }, self.body), 5)

    self.win:Track(button.MouseEnter:Connect(function()
        TweenService:Create(button, TWEEN, { BackgroundColor3 = THEME.rowHi }):Play()
    end))
    self.win:Track(button.MouseLeave:Connect(function()
        TweenService:Create(button, TWEEN, { BackgroundColor3 = THEME.row }):Play()
    end))
    self.win:Track(button.MouseButton1Click:Connect(function()
        local ok, err = pcall(callback)
        if not ok then self:_fail(text, err) end
    end))
    return button
end

function Group:Toggle(idx, text, default, callback)
    local win = self.win
    local saved = win:Get(idx)
    local state = if type(saved) == "boolean" then saved else (default or false)

    local row = self:_row(32)
    local name = label(row, text, 12, THEME.text)
    name.Position = UDim2.fromOffset(10, 0)
    name.Size = UDim2.new(1, -62, 1, 0)

    local track = corner(create("Frame", {
        Position = UDim2.new(1, -48, 0.5, -10), Size = UDim2.fromOffset(38, 20),
        BackgroundColor3 = THEME.off, BorderSizePixel = 0,
    }, row), 10)
    local knob = corner(create("Frame", {
        Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = THEME.text, BorderSizePixel = 0,
    }, track), 7)

    local hit = create("TextButton", {
        BackgroundTransparency = 1, Text = "",
        Size = UDim2.fromScale(1, 1), ZIndex = 3,
    }, row)

    local function render(animate)
        local info = animate and TWEEN or TweenInfo.new(0)
        TweenService:Create(track, info, {
            BackgroundColor3 = state and THEME.accent or THEME.off,
        }):Play()
        TweenService:Create(knob, info, {
            Position = state and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3),
        }):Play()
    end

    local function apply(animate, silent)
        render(animate)
        win:Set(idx, state)
        if not silent and callback then
            local ok, err = pcall(callback, state)
            if not ok then self:_fail(idx, err) end
        end
    end

    win:Track(hit.MouseButton1Click:Connect(function()
        state = not state
        apply(true)
    end))

    render(false)
    -- Fire once on construction so a saved "on" state actually starts its worker.
    task.defer(function()
        if callback then
            local ok, err = pcall(callback, state)
            if not ok then self:_fail(idx, err) end
        end
    end)

    return self:_register(idx, {
        Instance = row,
        Get = function() return state end,
        Set = function(value, silent)
            state = value and true or false
            apply(true, silent)
        end,
    })
end

function Group:Slider(idx, text, min, max, default, step, callback)
    local win = self.win
    step = step or 1
    local saved = tonumber(win:Get(idx))
    local value = math.clamp(saved or default or min, min, max)

    local row = self:_row(44)
    local name = label(row, text, 12, THEME.text)
    name.Position = UDim2.fromOffset(10, 2)
    name.Size = UDim2.new(1, -80, 0, 18)

    local readout = label(row, tostring(value), 12, THEME.accent, true)
    readout.Position = UDim2.new(1, -74, 0, 2)
    readout.Size = UDim2.fromOffset(64, 18)
    readout.TextXAlignment = Enum.TextXAlignment.Right

    local bar = corner(create("Frame", {
        Position = UDim2.fromOffset(10, 26), Size = UDim2.new(1, -20, 0, 8),
        BackgroundColor3 = THEME.off, BorderSizePixel = 0,
    }, row), 4)
    local fill = corner(create("Frame", {
        Size = UDim2.fromScale((value - min) / math.max(max - min, 1), 1),
        BackgroundColor3 = THEME.accent, BorderSizePixel = 0,
    }, bar), 4)

    local function setFromScale(scale, silent)
        local raw = min + (max - min) * math.clamp(scale, 0, 1)
        local snapped = math.clamp(math.floor(raw / step + 0.5) * step, min, max)
        if snapped == value and not silent then return end
        value = snapped
        readout.Text = tostring(value)
        fill.Size = UDim2.fromScale((value - min) / math.max(max - min, 1), 1)
        win:Set(idx, value)
        if not silent and callback then
            local ok, err = pcall(callback, value)
            if not ok then self:_fail(idx, err) end
        end
    end

    local dragging = false
    local function track(input)
        local scale = (input.Position.X - bar.AbsolutePosition.X)
            / math.max(bar.AbsoluteSize.X, 1)
        setFromScale(scale)
    end

    win:Track(bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            track(input)
        end
    end))
    win:Track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    win:Track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            track(input)
        end
    end))

    task.defer(function()
        if callback then pcall(callback, value) end
    end)

    return self:_register(idx, {
        Instance = row,
        Get = function() return value end,
        Set = function(newValue, silent)
            setFromScale(((tonumber(newValue) or min) - min) / math.max(max - min, 1), silent)
        end,
    })
end

function Group:Input(idx, text, default, callback)
    local win = self.win
    local value = tostring(win:Get(idx, default or ""))

    local row = self:_row(48)
    local name = label(row, text, 12, THEME.text)
    name.Position = UDim2.fromOffset(10, 2)
    name.Size = UDim2.new(1, -20, 0, 16)

    local box = corner(create("TextBox", {
        Position = UDim2.fromOffset(10, 22), Size = UDim2.new(1, -20, 0, 20),
        BackgroundColor3 = THEME.bg, BorderSizePixel = 0,
        Font = Enum.Font.Gotham, TextSize = 12,
        TextColor3 = THEME.text, TextXAlignment = Enum.TextXAlignment.Left,
        PlaceholderText = "...", PlaceholderColor3 = THEME.dim,
        ClearTextOnFocus = false, Text = value,
    }, row), 4)
    create("UIPadding", { PaddingLeft = UDim.new(0, 6) }, box)

    win:Track(box.FocusLost:Connect(function()
        value = box.Text
        win:Set(idx, value)
        if callback then
            local ok, err = pcall(callback, value)
            if not ok then self:_fail(idx, err) end
        end
    end))

    return self:_register(idx, {
        Instance = row,
        Get = function() return value end,
        Set = function(newValue, silent)
            value = tostring(newValue or "")
            box.Text = value
            win:Set(idx, value)
            if not silent and callback then pcall(callback, value) end
        end,
    })
end

-- multi=false -> value is a string. multi=true -> value is { option = true }.
function Group:Dropdown(idx, text, options, default, multi, callback)
    local win = self.win
    local saved = win:Get(idx)
    local value
    if multi then
        value = type(saved) == "table" and saved or {}
        if type(default) == "table" and saved == nil then
            for k, v in default do value[k] = v end
        end
    else
        value = type(saved) == "string" and saved or (default or options[1])
    end

    local row = self:_row(32)
    local name = label(row, text, 12, THEME.text)
    name.Position = UDim2.fromOffset(10, 0)
    name.Size = UDim2.new(0.45, -10, 1, 0)

    local summary = label(row, "", 11, THEME.accent)
    summary.Position = UDim2.new(0.45, 0, 0, 0)
    summary.Size = UDim2.new(0.55, -28, 1, 0)
    summary.TextXAlignment = Enum.TextXAlignment.Right

    local chevron = label(row, "v", 11, THEME.dim, true)
    chevron.Position = UDim2.new(1, -20, 0, 0)
    chevron.Size = UDim2.fromOffset(14, 32)

    local hit = create("TextButton", {
        BackgroundTransparency = 1, Text = "",
        Size = UDim2.fromScale(1, 1), ZIndex = 3,
    }, row)

    local menu = corner(create("Frame", {
        Visible = false,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = self:_next(),
        BackgroundColor3 = THEME.bg, BorderSizePixel = 0,
    }, self.body), 5)
    stroke(menu)
    local menuList = create("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        CanvasSize = UDim2.new(), ScrollBarThickness = 2,
        ScrollBarImageColor3 = THEME.off,
    }, menu)
    list(menuList, 2)
    pad(menuList, 4)

    local function describe()
        if multi then
            local picked = join(value)
            summary.Text = #picked == 0 and "none"
                or (#picked <= 2 and table.concat(picked, ", ")
                or (#picked .. " selected"))
        else
            summary.Text = tostring(value)
        end
    end

    local rows = {}
    local function renderRows()
        for option, entry in rows do
            local on = if multi then value[option] == true else value == option
            entry.tick.BackgroundColor3 = on and THEME.accent or THEME.off
            entry.text.TextColor3 = on and THEME.text or THEME.dim
        end
        describe()
    end

    for order, option in options do
        local entry = corner(create("TextButton", {
            Name = tostring(option), AutoButtonColor = false,
            Size = UDim2.new(1, 0, 0, 24), LayoutOrder = order,
            BackgroundColor3 = THEME.row, BorderSizePixel = 0, Text = "",
        }, menuList), 4)

        local tick = corner(create("Frame", {
            Position = UDim2.fromOffset(6, 7), Size = UDim2.fromOffset(10, 10),
            BackgroundColor3 = THEME.off, BorderSizePixel = 0,
        }, entry), 3)

        local entryText = label(entry, tostring(option), 11, THEME.dim)
        entryText.Position = UDim2.fromOffset(24, 0)
        entryText.Size = UDim2.new(1, -30, 1, 0)

        rows[option] = { tick = tick, text = entryText }

        win:Track(entry.MouseButton1Click:Connect(function()
            if multi then
                value[option] = not value[option] or nil
            else
                value = option
                menu.Visible = false
                chevron.Text = "v"
            end
            win:Set(idx, value)
            renderRows()
            if callback then
                local ok, err = pcall(callback, value)
                if not ok then self:_fail(idx, err) end
            end
        end))
    end

    win:Track(hit.MouseButton1Click:Connect(function()
        menu.Visible = not menu.Visible
        chevron.Text = menu.Visible and "^" or "v"
    end))

    renderRows()
    task.defer(function()
        if callback then pcall(callback, value) end
    end)

    return self:_register(idx, {
        Instance = row,
        Get = function() return value end,
        Set = function(newValue, silent)
            value = newValue
            win:Set(idx, value)
            renderRows()
            if not silent and callback then pcall(callback, value) end
        end,
    })
end

function Group:Keybind(idx, text, default, callback)
    local win = self.win
    local savedName = win:Get(idx)
    local key = (savedName and Enum.KeyCode[savedName]) or default

    local row = self:_row(32)
    local name = label(row, text, 12, THEME.text)
    name.Position = UDim2.fromOffset(10, 0)
    name.Size = UDim2.new(1, -110, 1, 0)

    local button = corner(create("TextButton", {
        AutoButtonColor = false,
        Position = UDim2.new(1, -96, 0.5, -11), Size = UDim2.fromOffset(86, 22),
        BackgroundColor3 = THEME.bg, BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium, TextSize = 11,
        TextColor3 = THEME.accent, Text = key and key.Name or "none",
    }, row), 4)

    local bind = { key = key, fn = callback }
    table.insert(win.keybinds, bind)

    local listening = false
    win:Track(button.MouseButton1Click:Connect(function()
        listening = true
        button.Text = "press..."
    end))
    win:Track(UserInputService.InputBegan:Connect(function(input, processed)
        if not listening then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        listening = false
        if input.KeyCode == Enum.KeyCode.Escape then
            bind.key = nil
            button.Text = "none"
            win:Set(idx, nil)
            return
        end
        bind.key = input.KeyCode
        button.Text = input.KeyCode.Name
        win:Set(idx, input.KeyCode.Name)
    end))

    return self:_register(idx, {
        Instance = row,
        Get = function() return bind.key end,
        Set = function(newValue)
            local newKey = type(newValue) == "string" and Enum.KeyCode[newValue] or newValue
            bind.key = newKey
            button.Text = newKey and newKey.Name or "none"
        end,
    })
end

--=========================================================================--
--                          TOASTS & OVERLAY HUD                           --
--=========================================================================--
function Window:Notify(text, kind, duration)
    if not self.toasts then return end
    local colour = kind == "ok" and THEME.accent
        or kind == "bad" and THEME.bad
        or kind == "warn" and THEME.warn
        or THEME.dim

    local toast = corner(create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = THEME.bar, BorderSizePixel = 0,
        BackgroundTransparency = 1,
    }, self.toasts), 6)
    stroke(toast, colour)

    create("Frame", {
        Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = colour,
        BorderSizePixel = 0, ZIndex = 2,
    }, toast)

    local body = label(toast, tostring(text), 12, THEME.text)
    body.Position = UDim2.fromOffset(11, 0)
    body.Size = UDim2.new(1, -20, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.TextWrapped = true
    body.TextTruncate = Enum.TextTruncate.None
    create("UIPadding", {
        PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
    }, toast)

    TweenService:Create(toast, TWEEN, { BackgroundTransparency = 0 }):Play()
    task.delay(duration or 3.5, function()
        TweenService:Create(toast, TWEEN, { BackgroundTransparency = 1 }):Play()
        body.TextTransparency = 1
        task.wait(0.2)
        pcall(function() toast:Destroy() end)
    end)
end

-- A small always-on-top readout, separate from the main window so it survives
-- the menu being closed. Lines are keyed so workers can update them cheaply.
function Window:Overlay(enabled)
    if not enabled then
        if self.overlay then self.overlay.Visible = false end
        return
    end
    if self.overlay then
        self.overlay.Visible = true
        return
    end

    local frame = corner(create("Frame", {
        Name = "Overlay",
        Position = UDim2.fromOffset(12, 12),
        Size = UDim2.fromOffset(190, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = THEME.bg, BackgroundTransparency = 0.15,
        BorderSizePixel = 0, Active = true,
    }, self.gui), 8)
    stroke(frame)
    list(frame, 2)
    pad(frame, 8)
    self.overlay = frame
    self.overlayLines = {}
    self:_drag(frame, frame)

    local header = label(frame, self.title, 12, THEME.accent, true)
    header.Size = UDim2.new(1, 0, 0, 16)
    header.LayoutOrder = 0
    return frame
end

function Window:OverlaySet(key, text)
    if not self.overlay then return end
    local line = self.overlayLines[key]
    if not line then
        line = label(self.overlay, "", 11, THEME.dim)
        line.Size = UDim2.new(1, 0, 0, 14)
        line.LayoutOrder = #self.overlayLines + 1
        self.overlayLines[key] = line
    end
    line.Text = tostring(text)
end

--=========================================================================--
--                                 EXPORT                                  --
--=========================================================================--
if ENV.SyncHub then
    pcall(function() ENV.SyncHub:Destroy() end)
    ENV.SyncHub = nil
end

return {
    new    = function(title, dir)
        local win = Window.new(title, dir)
        ENV.SyncHub = win
        return win
    end,
    THEME  = THEME,
    create = create,
    corner = corner,
}
