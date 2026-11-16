-- ============================================================
-- Boss 自动开关 UI（参考 打BOOS.lua 技术方案）
-- 改动：击杀后传送到宝箱 → 模拟按住 E 键 3 秒领取
-- ============================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local lp = Players.LocalPlayer
local muscleEvent = lp:WaitForChild("muscleEvent")

-- ==================== 配置 ====================
local BOSS_HEIGHT = 66
local HOME_POS = Vector3.new(1, 44, -1251)
local BACKUP_CHEST_CF = CFrame.new(Vector3.new(
    -2.2187373638153076, 52.295745849609375, -1272.9957275390625
))

local CLAIM_WAIT_BEFORE_E = 3   -- 传送到宝箱后等待多少秒再按 E
local CLAIM_HOLD_E_TIME    = 3   -- 按住 E 键多少秒领取
local CLAIM_AFTER_WAIT     = 2   -- 领取后等待多久再回主循环找 Boss

local BossConfig = {
    { name = "普通", key = "Boss1" },
    { name = "稀有", key = "Boss2" },
    { name = "史诗", key = "Boss3" },
    { name = "传奇", key = "Boss4" },
    { name = "神话", key = "Boss5" },
    { name = "彩虹", key = "BossRainbow" },
}
for _, cfg in ipairs(BossConfig) do cfg.uiEnabled = false end

local global = {
    fighting       = false,
    bossActive     = false,
    currentBossKey = nil,
    conn           = nil,
    thread         = nil,
    claiming       = false,
}

-- ==================== 工具 ====================
local function pressKey(key, delay)
    delay = delay or 0.05
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        task.wait(delay)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

local function getBossHealth(key)
    local ev = workspace:FindFirstChild("Events")
    local arena = ev and ev:FindFirstChild("BossArena")
    local folder = arena and arena:FindFirstChild(key)
    if folder then
        local stats = folder:FindFirstChild("stats")
        local hp = stats and stats:FindFirstChild("Health")
        if hp then return hp.Value end
    end
    return 0
end

local function getBossPos(key)
    local ev = workspace:FindFirstChild("Events")
    local arena = ev and ev:FindFirstChild("BossArena")
    local folder = arena and arena:FindFirstChild(key)
    local boss = folder and folder:FindFirstChild("Boss")
    if not boss then return nil end
    if boss:IsA("Model") then
        return boss:GetPivot().Position
    elseif boss:IsA("BasePart") then
        return boss.Position
    end
    return nil
end

local function getConfigByKey(key)
    for _, cfg in ipairs(BossConfig) do
        if cfg.key == key then return cfg end
    end
    return nil
end

-- 只装备宠物（loadoutRemote Slot 3），只在开始击杀时调用
local function equipPet()
    local rEvents = ReplicatedStorage:FindFirstChild("rEvents")
    if not rEvents then return false end
    local remote = rEvents:FindFirstChild("loadoutRemote")
    if not remote then return false end
    local ok = pcall(function()
        remote:InvokeServer("Equip", { Slot = 3 })
    end)
    return ok
end

-- 领取宝箱：传送 → 等待 → 按住 E 键
local function claimChest()
    global.claiming = true

    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = BACKUP_CHEST_CF
    end

    -- 等待宝箱加载 / 站位稳定
    task.wait(CLAIM_WAIT_BEFORE_E)

    -- 按住 E 键领取
    pressKey(Enum.KeyCode.E, CLAIM_HOLD_E_TIME)

    -- 领取后短暂等待，避免和下一轮扫描冲突
    task.wait(CLAIM_AFTER_WAIT)

    global.claiming = false
end

-- ==================== 战斗 ====================
local function setFighting(on)
    if global.fighting == on then return end
    global.fighting = on
    if global.conn then global.conn:Disconnect(); global.conn = nil end
    if global.thread then pcall(task.cancel, global.thread); global.thread = nil end
    if not on then return end

    -- 每帧跟随 + 角色俯冲姿态
    global.conn = RunService.RenderStepped:Connect(function()
        if not global.fighting then return end
        local bp = getBossPos(global.currentBossKey)
        local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        if not hrp or not bp then return end
        local target = bp + Vector3.new(0, BOSS_HEIGHT, 0)
        local flat = Vector3.new(bp.X - target.X, 0, bp.Z - target.Z)
        if flat.Magnitude < 0.1 then flat = Vector3.new(0, 0, -1) end
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.CFrame = CFrame.lookAt(target, target + flat.Unit)
            * CFrame.Angles(math.rad(-90), 0, 0)
    end)

    -- 攻击循环（只处理 Punch 工具与动画，不触碰宠物）
    global.thread = task.spawn(function()
        local ids = {"3638729053","3638767427","507768375","522635514",
                     "522638767","182393478","129967390","129967478"}
        local isLeft, leftAnim, rightAnim, counter = true, nil, nil, 0
        while global.fighting do
            local char = lp.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 then
                task.wait(0.1)
                continue
            end
            local bp = getBossPos(global.currentBossKey)
            if not bp then
                task.wait(0.5)
            else
                counter = counter + 1
                if counter % 4 == 0 then
                    local p = lp.Backpack:FindFirstChild("Punch")
                    local d = p and p:FindFirstChildOfClass("NumberValue")
                    if d then d.Value = 0.01 end
                end
                pcall(function()
                    local p = lp.Backpack:FindFirstChild("Punch")
                    if p then hum:EquipTool(p) end
                    muscleEvent:FireServer("punch", isLeft and "leftHand" or "rightHand")
                    local anim = isLeft and leftAnim or rightAnim
                    if not anim then
                        local a = Instance.new("Animation")
                        a.AnimationId = "rbxassetid://" .. (isLeft and ids[1] or ids[2])
                        anim = hum:FindFirstChildOfClass("Animator"):LoadAnimation(a)
                        if isLeft then leftAnim = anim else rightAnim = anim end
                    end
                    anim:Stop(0)
                    anim:Play(0.1)
                    isLeft = not isLeft
                end)
            end
            task.wait(0.05)
        end
    end)
end

-- ==================== 主循环 ====================
task.spawn(function()
    while task.wait(0.1) do
        -- 掉虚空复位
        local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        if hrp and hrp.Position.Y < -100 then
            hrp.CFrame = CFrame.new(HOME_POS)
            task.wait(1)
            continue
        end

        -- 领取期间不做任何 Boss 处理
        if global.claiming then
            continue
        end

        if global.bossActive then
            local cfg = getConfigByKey(global.currentBossKey)
            local hp = getBossHealth(global.currentBossKey)
            if not cfg or not cfg.uiEnabled then
                setFighting(false)
                global.bossActive = false
                global.currentBossKey = nil
            elseif hp <= 0 then
                -- 击杀完成 → 传宝箱 + 按 E 键领取
                setFighting(false)
                global.bossActive = false
                global.currentBossKey = nil
                claimChest()
            end
        else
            -- 找第一个【已开启 且 有血】的 Boss
            local target = nil
            for _, cfg in ipairs(BossConfig) do
                if cfg.uiEnabled and getBossHealth(cfg.key) > 0 then
                    target = cfg
                    break
                end
            end
            if target then
                global.bossActive = true
                global.currentBossKey = target.key

                -- 1) 先跳跃进入战斗状态
                pressKey(Enum.KeyCode.Space)
                task.wait(0.05)
                pressKey(Enum.KeyCode.Space)
                task.wait(5)

                -- 2) 只在"即将开始击杀"时才装备宠物
                equipPet()
                task.wait(0.2)

                -- 3) 开始跟随 + 攻击
                setFighting(true)
            end
        end
    end
end)

-- 角色重生重置
lp.CharacterAdded:Connect(function()
    global.bossActive = false
    global.currentBossKey = nil
    setFighting(false)
end)

-- ==================== UI ====================
local function createUI()
    local existing = lp.PlayerGui:FindFirstChild("BossAutoUI")
    if existing then existing:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "BossAutoUI"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = lp:WaitForChild("PlayerGui")

    local expandedSize  = UDim2.fromOffset(270, 340)
    local minimizedSize = UDim2.fromOffset(270, 44)

    local main = Instance.new("Frame")
    main.Size = expandedSize
    main.Position = UDim2.new(0, 20, 0.5, -170)
    main.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    main.Active = true
    main.Draggable = true
    main.Parent = gui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(85, 85, 120)
    stroke.Thickness = 1
    stroke.Parent = main

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -90, 0, 36)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "BOSS 自动开关"
    title.TextColor3 = Color3.fromRGB(255, 200, 100)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = main

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(28, 28)
    closeBtn.Position = UDim2.new(1, -38, 0, 4)
    closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    closeBtn.Text = "X"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 16
    closeBtn.BorderSizePixel = 0
    closeBtn.Parent = main
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.fromOffset(28, 28)
    minBtn.Position = UDim2.new(1, -72, 0, 4)
    minBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 130)
    minBtn.Text = "—"
    minBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 16
    minBtn.BorderSizePixel = 0
    minBtn.Parent = main
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

    local list = Instance.new("Frame")
    list.Size = UDim2.new(1, -24, 0, 6 * 42 - 6)
    list.Position = UDim2.new(0, 12, 0, 44)
    list.BackgroundTransparency = 1
    list.Parent = main
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.Parent = list

    local statusBar = Instance.new("TextLabel")
    statusBar.Size = UDim2.new(1, -24, 0, 20)
    statusBar.Position = UDim2.new(0, 12, 1, -26)
    statusBar.BackgroundTransparency = 1
    statusBar.Text = "状态：等待"
    statusBar.TextColor3 = Color3.fromRGB(180, 180, 180)
    statusBar.Font = Enum.Font.Gotham
    statusBar.TextSize = 12
    statusBar.TextXAlignment = Enum.TextXAlignment.Left
    statusBar.Parent = main

    local function updateVisual(toggle, enabled)
        if enabled then
            toggle.Text = "关闭"
            toggle.BackgroundColor3 = Color3.fromRGB(60, 180, 90)
        else
            toggle.Text = "开启"
            toggle.BackgroundColor3 = Color3.fromRGB(60, 60, 85)
        end
    end

    for _, cfg in ipairs(BossConfig) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 36)
        row.BackgroundColor3 = Color3.fromRGB(45, 45, 62)
        row.BorderSizePixel = 0
        row.Parent = list
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -110, 1, 0)
        nameLabel.Position = UDim2.new(0, 12, 0, 0)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = cfg.name
        nameLabel.TextColor3 = Color3.fromRGB(220, 220, 240)
        nameLabel.Font = Enum.Font.Gotham
        nameLabel.TextSize = 14
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = row

        local toggle = Instance.new("TextButton")
        toggle.Size = UDim2.new(0, 80, 0, 26)
        toggle.Position = UDim2.new(1, -92, 0.5, -13)
        toggle.TextColor3 = Color3.fromRGB(255, 255, 255)
        toggle.Font = Enum.Font.GothamBold
        toggle.TextSize = 13
        toggle.BorderSizePixel = 0
        toggle.Parent = row
        Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 6)
        updateVisual(toggle, cfg.uiEnabled)

        toggle.MouseButton1Click:Connect(function()
            cfg.uiEnabled = not cfg.uiEnabled
            updateVisual(toggle, cfg.uiEnabled)
        end)
    end

    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        if minimized then
            list.Visible = false
            statusBar.Visible = false
            main.Size = minimizedSize
            minBtn.Text = "+"
        else
            list.Visible = true
            statusBar.Visible = true
            main.Size = expandedSize
            minBtn.Text = "—"
        end
    end)

    closeBtn.MouseButton1Click:Connect(function()
        for _, cfg in ipairs(BossConfig) do cfg.uiEnabled = false end
        global.bossActive = false
        global.currentBossKey = nil
        setFighting(false)
        gui:Destroy()
    end)

    task.spawn(function()
        while gui.Parent do
            if global.claiming then
                statusBar.Text = "状态：领取中"
                statusBar.TextColor3 = Color3.fromRGB(120, 180, 255)
            elseif global.bossActive and global.currentBossKey then
                local cfg = getConfigByKey(global.currentBossKey)
                statusBar.Text = "状态：打 " .. (cfg and cfg.name or "?") .. " 中"
                statusBar.TextColor3 = Color3.fromRGB(120, 220, 120)
            else
                statusBar.Text = "状态：等待"
                statusBar.TextColor3 = Color3.fromRGB(180, 180, 180)
            end
            task.wait(0.3)
        end
    end)

    return gui
end

createUI()