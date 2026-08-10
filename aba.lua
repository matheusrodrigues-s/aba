if not game:IsLoaded() then
	game.Loaded:Wait()
end

--==============================================================
--  SINGLETON GUARD (identity based)
--  Executors re-inject on teleport, and every live instance queues the
--  script again — so copies double on each hop. A shared boolean flag
--  cannot fix this: the newcomer overwrites the slot, and the older
--  instance then reads the NEWCOMER's flag (false) and keeps running.
--  Instead each instance holds its own token and simply asks
--  "is the shared slot still me?".
--==============================================================
local MY_TOKEN = {}
local JJ_SLOT = "__JOBJOINER_SLOT__"

do
	if getgenv then
		getgenv()[JJ_SLOT] = MY_TOKEN
	end

	-- destroy any GUI left behind by a previous injection
	for _, container in ipairs({
		(gethui and gethui()) or nil,
		game:GetService("CoreGui"),
		game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui"),
	}) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child.Name == "JobIdJoiner" then
					pcall(function()
						child:Destroy()
					end)
				end
			end
		end
	end
end

-- true as soon as a newer injection claims the slot
local function should_stop()
	if not getgenv then
		return false
	end
	return getgenv()[JJ_SLOT] ~= MY_TOKEN
end

--==============================================================
--  JOB ID JOINER — LocalScript (timer-aware + auto explore + stats)
--  StarterPlayer > StarterPlayerScripts > JobJoiner (LocalScript)
--==============================================================

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

--// config
local CACHE_SIZE = 50 -- servers held in memory
local CACHE_TTL = 180 -- seconds before cache is considered stale
local MAX_FAILS = 3 -- consecutive fails before forcing a refetch
local MAX_ATTEMPTS = 6 -- total join attempts per hop
local FETCH_PAGES = 3 -- max API pages per fetch
local MAX_VISITED = 120 -- remembered job ids
local MAX_TIMERS = 120 -- hard cap on tracked servers (evicts worst)
local MAX_ROWS = 40 -- pooled UI rows on the Servers tab
local TP_DATA_MAX = 25 -- servers carried in teleportData
local TP_TIMER_MAX = 60 -- timers carried in teleportData
local TP_HIST_MAX = 60 -- history points carried in teleportData
local MAX_HISTORY = 400 -- history points kept in memory
local GRAPH_POINTS = 48 -- bars drawn in the sparkline

--// tuning (grouped: Luau caps a function at 200 locals)
local CFG = {
	DISK_INTERVAL = 20, -- min seconds between writefile calls
	EXPLORE_COOLDOWN = 3, -- pause between exploration hops
	MAX_EXPLORE_FAILS = 3, -- give up exploring after this many empty picks
	AUTO_MAX_HOURS = 0, -- stop auto after N hours (0 = run forever)
	MEM_GROWTH_MB = 400, -- pause when Lua heap grows this much past baseline
	MEM_PAUSE_SECS = 30, -- how long to idle while memory settles
	MEM_GIVEUP_MIN = 10, -- turn auto off if memory never recovers in N minutes
	MIN_HOP_INTERVAL = 0, -- hard floor in seconds between teleports (0 = off)
	LOW_GRAPHICS = true, -- force the lowest quality level on every join
	DISABLE_3D = false, -- stop rendering the world entirely (GUI still shows)
	LOG_FILE = "jobjoiner_log.txt", -- crash breadcrumbs (executor only)
	LOG_MAX_KB = 512, -- rotate the log past this size
	TARGET_FILE = "next_target.txt", -- where the AHK watchdog should rejoin
	TARGET_INTERVAL = 20, -- seconds between target file writes
}

--// timer tracking
local HINT_NAME = "Message" -- workspace child holding the countdown
local CYCLE = 30 -- countdown length in seconds
local TIMER_OFFSET = 1 -- display rounds down; add this to each reading
local TIMER_TTL = 3600 -- forget a phase after this many seconds

--// money tracking
local MONEY_GUI = "ScreenGui" -- PlayerGui child holding the labels
local MONEY_LABEL = "TextLabel" -- "Gold : $1321"
local LEVEL_LABEL = "TextLabel2" -- "Level : 30"
local HEARTBEAT = 15 -- seconds between forced history samples

--// sliders / inputs
local MIN_LEAD_MIN, MIN_LEAD_MAX = 1, 20
local WINDOW_MIN, WINDOW_MAX = 2, 25
local CLAIM_MIN, CLAIM_MAX, CLAIM_STEP = 0, 6, 0.5
local min_lead = 6 -- need at least this much time to land
local hop_window = 8 -- ...and no more than lead+window, else explore
local claim_offset = 1.5 -- stay this long past zero to collect
local explore_target = 8 -- grow the pool to this size before timing hops

--// persistence
local PERSIST_FILE = "jobjoiner_cache.json"
local PERSIST_KEY = "JobJoinerCache"
local SCRIPT_URL = nil

--// theme
local T = {
	bg = Color3.fromRGB(18, 18, 20),
	panel = Color3.fromRGB(26, 26, 30),
	input = Color3.fromRGB(34, 34, 39),
	stroke = Color3.fromRGB(48, 48, 55),
	text = Color3.fromRGB(235, 235, 240),
	dim = Color3.fromRGB(130, 130, 140),
	accent = Color3.fromRGB(90, 140, 255),
	ok = Color3.fromRGB(80, 200, 120),
	err = Color3.fromRGB(235, 90, 90),
	warn = Color3.fromRGB(240, 180, 70),
}

--// create helper
local function new(class, props, children)
	local inst = Instance.new(class)
	local parent = props.Parent
	props.Parent = nil
	for k, v in pairs(props) do
		inst[k] = v
	end
	for _, c in ipairs(children or {}) do
		c.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function corner(r, p)
	return new("UICorner", { CornerRadius = UDim.new(0, r), Parent = p })
end
local function stroke(c, p)
	return new("UIStroke", { Color = c or T.stroke, Thickness = 1, Parent = p })
end

-- synced clock, consistent across servers
local function now_secs()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and type(t) == "number" and t > 0 then
		return t
	end
	return DateTime.now().UnixTimestampMillis / 1000
end

local function comma(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function dur(sec)
	sec = math.max(0, math.floor(sec or 0))
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = sec % 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	if m > 0 then
		return string.format("%dm %02ds", m, s)
	end
	return string.format("%ds", s)
end

--==============================================================
--  ROOT
--==============================================================
local gui = new("ScreenGui", {
	Name = "JobIdJoiner",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 9999,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = LocalPlayer:WaitForChild("PlayerGui"),
})
-- Executor? troque a linha acima por:
-- pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)

--==============================================================
--  TOAST / NOTIFY
--==============================================================
local toastHolder = new("Frame", {
	Name = "Toasts",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -16),
	Size = UDim2.new(0, 280, 0, 400),
	BackgroundTransparency = 1,
	Parent = gui,
}, {
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 8),
	}),
})

local library = {}

function library:Notify(msg, kind, duration)
	local color = (kind == "error" and T.err) or (kind == "ok" and T.ok) or (kind == "warn" and T.warn) or T.accent

	local card = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.panel,
		BackgroundTransparency = 1,
		Parent = toastHolder,
	})
	corner(8, card)
	local st = stroke(T.stroke, card)
	st.Transparency = 1

	local accentBar = new("Frame", {
		Size = UDim2.new(0, 3, 1, -12),
		Position = UDim2.new(0, 8, 0, 6),
		BackgroundColor3 = color,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = card,
	})
	corner(2, accentBar)

	local label = new("TextLabel", {
		Position = UDim2.new(0, 20, 0, 10),
		Size = UDim2.new(1, -30, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = T.text,
		TextTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Text = tostring(msg),
		Parent = card,
	})
	new("UIPadding", { PaddingBottom = UDim.new(0, 10), Parent = card })

	local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(card, info, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(st, info, { Transparency = 0 }):Play()
	TweenService:Create(accentBar, info, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(label, info, { TextTransparency = 0 }):Play()

	task.delay(duration or 3.5, function()
		if not card.Parent then
			return
		end
		TweenService:Create(card, info, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(st, info, { Transparency = 1 }):Play()
		TweenService:Create(accentBar, info, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(label, info, { TextTransparency = 1 }):Play()
		task.wait(0.25)
		card:Destroy()
	end)
end

--==============================================================
--  WINDOW
--==============================================================
local EXPANDED = UDim2.new(0, 330, 0, 474)
local COLLAPSED = UDim2.new(0, 330, 0, 38)

local main = new("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = EXPANDED,
	BackgroundColor3 = T.bg,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Parent = gui,
})
corner(10, main)
stroke(T.stroke, main)

--// title bar
local titleBar = new("Frame", {
	Size = UDim2.new(1, 0, 0, 38),
	BackgroundTransparency = 1,
	Parent = main,
})

local statusDot = new("Frame", {
	Size = UDim2.new(0, 6, 0, 6),
	Position = UDim2.new(0, 14, 0.5, -3),
	BackgroundColor3 = T.accent,
	BorderSizePixel = 0,
	Parent = titleBar,
}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })

new("TextLabel", {
	Position = UDim2.new(0, 28, 0, 0),
	Size = UDim2.new(1, -100, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 13,
	TextColor3 = T.text,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Server Joiner",
	Parent = titleBar,
})

local function iconButton(txt, x)
	local b = new("TextButton", {
		Size = UDim2.new(0, 24, 0, 24),
		Position = UDim2.new(1, x, 0.5, -12),
		BackgroundColor3 = T.input,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = T.dim,
		Text = txt,
		Parent = titleBar,
	})
	corner(6, b)
	b.MouseEnter:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 0, TextColor3 = T.text }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 1, TextColor3 = T.dim }):Play()
	end)
	return b
end

local btnMin = iconButton("–", -62)
local btnClose = iconButton("×", -32)

--==============================================================
--  TABS
--==============================================================
local tabBar = new("Frame", {
	Position = UDim2.new(0, 14, 0, 38),
	Size = UDim2.new(1, -28, 0, 24),
	BackgroundTransparency = 1,
	Parent = main,
}, {
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 5),
	}),
})

local body = new("Frame", {
	Position = UDim2.new(0, 0, 0, 66),
	Size = UDim2.new(1, 0, 1, -66),
	BackgroundTransparency = 1,
	Parent = main,
})

local pages, tabButtons = {}, {}

local function makePage(name, order, label)
	local page = new("Frame", {
		Name = name,
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Visible = (order == 1),
		Parent = body,
	}, {
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 14),
			PaddingRight = UDim.new(0, 14),
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 10),
		}),
		new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
	})

	local btn = new("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(0, 96, 1, 0),
		BackgroundColor3 = (order == 1) and T.input or T.panel,
		BackgroundTransparency = (order == 1) and 0 or 1,
		AutoButtonColor = false,
		Font = Enum.Font.GothamMedium,
		TextSize = 11,
		TextColor3 = (order == 1) and T.text or T.dim,
		Text = label,
		Parent = tabBar,
	})
	corner(6, btn)

	pages[name] = page
	tabButtons[name] = btn

	btn.MouseButton1Click:Connect(function()
		for n, p in pairs(pages) do
			local on = (n == name)
			p.Visible = on
			local tb = tabButtons[n]
			tb.BackgroundColor3 = on and T.input or T.panel
			TweenService:Create(tb, TweenInfo.new(0.12), {
				BackgroundTransparency = on and 0 or 1,
				TextColor3 = on and T.text or T.dim,
			}):Play()
		end
	end)

	return page, btn
end

local pageJoin, tabJoin = makePage("Join", 1, "Join")
local pageServers, tabServers = makePage("Servers", 2, "Servers (0)")
local pageStats, tabStats = makePage("Stats", 3, "Stats")

--==============================================================
--  JOIN PAGE
--==============================================================
local box = new("TextBox", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundColor3 = T.input,
	BorderSizePixel = 0,
	Font = Enum.Font.Code,
	TextSize = 11,
	TextColor3 = T.text,
	PlaceholderText = "paste a Job ID or a game link",
	PlaceholderColor3 = T.dim,
	ClearTextOnFocus = false,
	Text = "",
	Parent = pageJoin,
}, {
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
})
corner(7, box)
stroke(T.stroke, box)

local function makeButton(parent, order, text, style, size)
	local primary = (style == "primary")
	local b = new("TextButton", {
		LayoutOrder = order,
		Size = size or UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = primary and T.accent or T.panel,
		AutoButtonColor = false,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = primary and Color3.new(1, 1, 1) or T.dim,
		Text = text,
		Parent = parent,
	})
	corner(7, b)
	if not primary then
		stroke(T.stroke, b)
	end

	local base = primary and T.accent or T.panel
	local hover = primary and Color3.fromRGB(110, 158, 255) or T.input
	b.MouseEnter:Connect(function()
		if b:GetAttribute("locked") then
			return
		end
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = hover }):Play()
	end)
	b.MouseLeave:Connect(function()
		if b:GetAttribute("locked") then
			return
		end
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = base }):Play()
	end)
	return b
end

local btnJoin = makeButton(pageJoin, 2, "Join Server", "primary")
local btnSmart = makeButton(pageJoin, 3, "Hop to Ending Soonest")
btnSmart.TextColor3 = T.accent

--// explore budget input
local exploreRow = new("Frame", {
	LayoutOrder = 4,
	Size = UDim2.new(1, 0, 0, 28),
	BackgroundTransparency = 1,
	Parent = pageJoin,
})

new("TextLabel", {
	Size = UDim2.new(1, -70, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextColor3 = T.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Servers to explore",
	Parent = exploreRow,
})

local exploreBox = new("TextBox", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, 0, 0.5, 0),
	Size = UDim2.new(0, 62, 0, 24),
	BackgroundColor3 = T.input,
	BorderSizePixel = 0,
	Font = Enum.Font.Code,
	TextSize = 12,
	TextColor3 = T.text,
	ClearTextOnFocus = false,
	Text = tostring(explore_target),
	Parent = exploreRow,
})
corner(6, exploreBox)
stroke(T.stroke, exploreBox)

local btnAuto = makeButton(pageJoin, 5, "AUTO: OFF")

local btnRow = new("Frame", {
	LayoutOrder = 6,
	Size = UDim2.new(1, 0, 0, 28),
	BackgroundTransparency = 1,
	Parent = pageJoin,
}, {
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	}),
})

local halfSize = UDim2.new(0.5, -3, 1, 0)
local btnSmallest = makeButton(btnRow, 1, "Smallest", nil, halfSize)
local btnHop = makeButton(btnRow, 2, "Random Hop", nil, halfSize)

--// generic slider (supports decimal steps)
local function makeSlider(parent, order, labelFmt, minV, maxV, getV, setV, step)
	step = step or 1
	local block = new("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Parent = parent,
	})

	local lbl = new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 12),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = T.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = block,
	})

	local track = new("Frame", {
		Position = UDim2.new(0, 0, 0, 19),
		Size = UDim2.new(1, 0, 0, 5),
		BackgroundColor3 = T.input,
		BorderSizePixel = 0,
		Parent = block,
	})
	corner(3, track)

	local fill = new("Frame", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = T.accent,
		BorderSizePixel = 0,
		Parent = track,
	})
	corner(3, fill)

	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 11, 0, 11),
		BackgroundColor3 = T.text,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = track,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local api = { sliding = false }

	function api.render()
		local v = getV()
		local a = (v - minV) / (maxV - minV)
		fill.Size = UDim2.new(a, 0, 1, 0)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
		lbl.Text = string.format(labelFmt, v)
	end

	function api.fromX(px)
		local a = math.clamp((px - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		local raw = minV + a * (maxV - minV)
		local v = math.clamp(math.floor(raw / step + 0.5) * step, minV, maxV)
		setV(tonumber(string.format("%.2f", v)))
		api.render()
	end

	track.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			api.sliding = true
			api.fromX(input.Position.X)
		end
	end)

	api.render()
	return api
end

local sliderLead = makeSlider(pageJoin, 7, "MIN LEAD: %ds", MIN_LEAD_MIN, MIN_LEAD_MAX, function()
	return min_lead
end, function(v)
	min_lead = v
end)

local sliderWindow = makeSlider(pageJoin, 8, "HOP WINDOW: +%ds", WINDOW_MIN, WINDOW_MAX, function()
	return hop_window
end, function(v)
	hop_window = v
end)

local sliderClaim = makeSlider(pageJoin, 9, "CLAIM OFFSET: %.1fs", CLAIM_MIN, CLAIM_MAX, function()
	return claim_offset
end, function(v)
	claim_offset = v
end, CLAIM_STEP)

--// cache status
local cacheLabel = new("TextButton", {
	LayoutOrder = 10,
	Size = UDim2.new(1, 0, 0, 13),
	BackgroundTransparency = 1,
	AutoButtonColor = false,
	Font = Enum.Font.Gotham,
	TextSize = 10,
	TextColor3 = T.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "cache: empty — click to refresh",
	Parent = pageJoin,
})

cacheLabel.MouseEnter:Connect(function()
	TweenService:Create(cacheLabel, TweenInfo.new(0.12), { TextColor3 = T.text }):Play()
end)
cacheLabel.MouseLeave:Connect(function()
	TweenService:Create(cacheLabel, TweenInfo.new(0.12), { TextColor3 = T.dim }):Play()
end)

--// current server + live timer
local current = new("TextButton", {
	LayoutOrder = 11,
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundColor3 = T.panel,
	AutoButtonColor = false,
	Font = Enum.Font.Code,
	TextSize = 10,
	TextColor3 = T.dim,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Text = "current: " .. (game.JobId ~= "" and game.JobId or "studio / no JobId"),
	Parent = pageJoin,
})
corner(6, current)

current.MouseButton1Click:Connect(function()
	if setclipboard then
		setclipboard(game.JobId)
		library:Notify("Current Job ID copied", "ok")
	else
		library:Notify("setclipboard unavailable — check console", "warn")
		print("[JOBID] " .. game.JobId)
	end
end)

--==============================================================
--  SERVERS PAGE
--==============================================================
local serversHeader = new("TextLabel", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 14),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	TextSize = 10,
	TextColor3 = T.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "DISCOVERED — waiting for first reading",
	Parent = pageServers,
})

local scroll = new("ScrollingFrame", {
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 1, -24),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = T.stroke,
	Parent = pageServers,
}, {
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
})

--==============================================================
--  STATS PAGE
--==============================================================
local statLabels = {}

local function statRow(order, key, label)
	local row = new("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 17),
		BackgroundTransparency = 1,
		Parent = pageStats,
	})
	new("TextLabel", {
		Size = UDim2.new(0.5, 0, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = T.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = label,
		Parent = row,
	})
	local val = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 11,
		TextColor3 = T.text,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "--",
		Parent = row,
	})
	statLabels[key] = val
	return val
end

new("TextLabel", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 13),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 10,
	TextColor3 = T.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "SESSION",
	Parent = pageStats,
})

statRow(2, "started", "Started at")
statRow(3, "elapsed", "Elapsed")
statRow(4, "startGold", "Starting gold")
statRow(5, "nowGold", "Current gold")
statRow(6, "gained", "Gained")
statRow(7, "rate", "Per hour")
statRow(8, "claims", "Claims")
statRow(9, "avgClaim", "Avg / best claim")
statRow(10, "hops", "Hops / explored")
statRow(11, "level", "Level")

local graphHeader = new("TextLabel", {
	LayoutOrder = 12,
	Size = UDim2.new(1, 0, 0, 15),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium,
	TextSize = 10,
	TextColor3 = T.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "GOLD OVER TIME",
	Parent = pageStats,
})

local graphFrame = new("Frame", {
	LayoutOrder = 13,
	Size = UDim2.new(1, 0, 0, 92),
	BackgroundColor3 = T.panel,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Parent = pageStats,
})
corner(6, graphFrame)

local graphCanvas = new("Frame", {
	Position = UDim2.new(0, 6, 0, 16),
	Size = UDim2.new(1, -12, 1, -24),
	BackgroundTransparency = 1,
	Parent = graphFrame,
})

local graphMax = new("TextLabel", {
	Position = UDim2.new(0, 8, 0, 2),
	Size = UDim2.new(0.5, 0, 0, 13),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextSize = 9,
	TextColor3 = T.dim,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "",
	Parent = graphFrame,
})

local graphSpan = new("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -8, 0, 2),
	Size = UDim2.new(0.5, 0, 0, 13),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextSize = 9,
	TextColor3 = T.dim,
	TextXAlignment = Enum.TextXAlignment.Right,
	Text = "",
	Parent = graphFrame,
})

local btnResetStats = makeButton(pageStats, 14, "Reset session")

--==============================================================
--  DRAG + SLIDER INPUT
--==============================================================
local dragging, dragStart, startPos
local dragConn
titleBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging, dragStart, startPos = true, input.Position, main.Position
		if dragConn then
			dragConn:Disconnect()
			dragConn = nil
		end
		dragConn = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				if dragConn then
					dragConn:Disconnect()
					dragConn = nil
				end
			end
		end)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		if sliderLead.sliding then
			sliderLead.fromX(input.Position.X)
		end
		if sliderWindow.sliding then
			sliderWindow.fromX(input.Position.X)
		end
		if sliderClaim.sliding then
			sliderClaim.fromX(input.Position.X)
		end
		if dragging then
			local d = input.Position - dragStart
			main.Position =
				UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		sliderLead.sliding = false
		sliderWindow.sliding = false
		sliderClaim.sliding = false
	end
end)

--==============================================================
--  MINIMIZE / CLOSE
--==============================================================
local minimized = false
btnMin.MouseButton1Click:Connect(function()
	minimized = not minimized
	btnMin.Text = minimized and "+" or "–"
	tabBar.Visible = not minimized
	body.Visible = not minimized
	TweenService:Create(
		main,
		TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = minimized and COLLAPSED or EXPANDED }
	):Play()
end)

btnClose.MouseButton1Click:Connect(function()
	TweenService:Create(main, TweenInfo.new(0.15), { Size = UDim2.new(0, 330, 0, 0) }):Play()
	task.wait(0.18)
	gui:Destroy()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then
		return
	end
	if input.KeyCode == Enum.KeyCode.RightShift then
		main.Visible = not main.Visible
	end
end)

--==============================================================
--  HTTP (executor only)
--==============================================================
local function get_request_fn()
	local ok, fn = pcall(function()
		if syn and syn.request then
			return syn.request
		end
		if fluxus and fluxus.request then
			return fluxus.request
		end
		if http and http.request then
			return http.request
		end
		if http_request then
			return http_request
		end
		if request then
			return request
		end
		return nil
	end)
	return ok and fn or nil
end

local function get_json(url, retries)
	retries = retries or 2
	local req = get_request_fn()
	if not req then
		return nil, "no HTTP function (executor required)"
	end

	for attempt = 1, retries + 1 do
		local ok, res = pcall(req, { Url = url, Method = "GET" })
		if ok then
			local code = res.StatusCode or res.Status or 0

			if code == 200 then
				local ok2, data = pcall(function()
					return HttpService:JSONDecode(res.Body)
				end)
				if ok2 then
					return data
				end
				return nil, "invalid JSON response"
			end

			if code == 429 and attempt <= retries then
				local waitTime = attempt * 3
				warn(("[HTTP] rate limited, retrying in %ds"):format(waitTime))
				task.wait(waitTime)
			else
				return nil, "HTTP " .. tostring(code)
			end
		elseif attempt > retries then
			return nil, tostring(res)
		end
	end

	return nil, "rate limited (429)"
end

--==============================================================
--  STATE
--==============================================================
local server_cache = {}
local visited = {}
local visited_order = {}
local timers = {} -- jobId -> {phase, samples, seenAt, playing, max, gain}
local cache_fetched_at = 0
local fail_streak = 0
local persist_backend = "memory"
local auto_enabled = false
local auto_status = "idle"
local explore_fails = 0
local auto_started_at = nil -- os.time() when auto was switched on
local mem_baseline = nil -- Lua heap MB shortly after boot
local mem_pressure_since = nil -- when memory first went over budget

local stats = {
	sessionStart = os.time(),
	startGold = nil,
	lastGold = nil,
	level = nil,
	claims = 0,
	claimTotal = 0,
	bestClaim = 0,
	hops = 0,
	explored = 0,
	history = {}, -- {t = os.time, g = gold}
}

local function has_files()
	return (writefile and readfile and isfile) and true or false
end

--// hand-off to an external watchdog: if the client dies, this is where it
--// should come back to. Written to disk so it survives the process.
local last_target_write = 0

local function write_next_target(force)
	if not has_files() then
		return
	end
	if not force and (tick() - last_target_write) < CFG.TARGET_INTERVAL then
		return
	end
	last_target_write = tick()

	local id = game.JobId
	if id == "" then
		return
	end
	pcall(writefile, CFG.TARGET_FILE, id)
end

--// breadcrumb log: survives the crash, unlike anything held in memory
local log_ready = false
local log_lines = 0

local function log_rotate()
	if not has_files() then
		return
	end
	local okE, exists = pcall(isfile, CFG.LOG_FILE)
	if not (okE and exists) then
		return
	end
	local okR, body = pcall(readfile, CFG.LOG_FILE)
	if okR and #body > CFG.LOG_MAX_KB * 1024 then
		-- keep the newest half so a long session still has context
		pcall(writefile, CFG.LOG_FILE, body:sub(math.floor(#body / 2)))
	end
end

local function logf(fmt, ...)
	local okMsg, msg = pcall(string.format, fmt, ...)
	if not okMsg then
		msg = tostring(fmt)
	end

	local okMem, kb = pcall(collectgarbage, "count")
	local line = string.format(
		"[%s] [%5.0fMB] [%s] %s",
		os.date("%H:%M:%S"),
		(okMem and type(kb) == "number") and (kb / 1024) or 0,
		(game.JobId ~= "" and game.JobId:sub(1, 8) or "studio"),
		msg
	)

	print("[JJ] " .. msg)

	if not has_files() then
		return
	end

	if not log_ready then
		log_ready = true
		log_rotate()
	end

	if appendfile then
		pcall(appendfile, CFG.LOG_FILE, line .. "\n")
	else
		local okR, body = pcall(readfile, CFG.LOG_FILE)
		pcall(writefile, CFG.LOG_FILE, (okR and body or "") .. line .. "\n")
	end

	log_lines += 1
	if log_lines % 200 == 0 then
		log_rotate()
	end
end

local function timer_count()
	local n = 0
	for _ in pairs(timers) do
		n += 1
	end
	return n
end

-- remaining seconds on a known server, at time t
local function remaining_at(phase, t)
	local r = (phase - t) % CYCLE
	if r <= 0.001 then
		r = CYCLE
	end
	return r
end

--==============================================================
--  PERSISTENCE
--==============================================================
local function build_payload(serverLimit, timerLimit, histLimit)
	local servers = {}
	for i, s in ipairs(server_cache) do
		if serverLimit and i > serverLimit then
			break
		end
		table.insert(servers, s)
	end

	local tlist = {}
	for id, t in pairs(timers) do
		table.insert(tlist, {
			id = id,
			phase = t.phase,
			samples = t.samples,
			seenAt = t.seenAt,
			playing = t.playing,
			max = t.max,
			gain = t.gain,
		})
	end
	table.sort(tlist, function(a, b)
		if (a.samples or 0) ~= (b.samples or 0) then
			return (a.samples or 0) > (b.samples or 0)
		end
		return (a.seenAt or 0) > (b.seenAt or 0)
	end)
	if timerLimit then
		while #tlist > timerLimit do
			table.remove(tlist)
		end
	end

	-- history: keep the newest points when trimming
	local hist = stats.history
	local hlist = {}
	local hStart = 1
	if histLimit and #hist > histLimit then
		hStart = #hist - histLimit + 1
	end
	for i = hStart, #hist do
		table.insert(hlist, hist[i])
	end

	return {
		placeId = game.PlaceId,
		savedAt = os.time(),
		servers = servers,
		visited = visited_order,
		timers = tlist,
		auto = auto_enabled,
		autoStart = auto_started_at,
		lead = min_lead,
		window = hop_window,
		claim = claim_offset,
		explore = explore_target,
		stats = {
			sessionStart = stats.sessionStart,
			startGold = stats.startGold,
			lastGold = stats.lastGold,
			level = stats.level,
			claims = stats.claims,
			claimTotal = stats.claimTotal,
			bestClaim = stats.bestClaim,
			hops = stats.hops,
			explored = stats.explored,
			history = hlist,
		},
	}
end

local last_save, last_disk = 0, 0
local function persist_save(force)
	if not force and (tick() - last_save) < 3 then
		return
	end
	last_save = tick()

	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(build_payload(nil, nil, MAX_HISTORY))
	end)
	if not ok then
		return
	end

	-- cheap, in-memory: safe to do often
	pcall(function()
		TeleportService:SetTeleportSetting(PERSIST_KEY, encoded)
	end)

	-- expensive, synchronous I/O: rate limit it hard
	if has_files() and (force or (tick() - last_disk) > CFG.DISK_INTERVAL) then
		last_disk = tick()
		pcall(writefile, PERSIST_FILE, encoded)
	end
end

local function persist_load()
	local ok, data = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)
	if ok and type(data) == "table" and type(data.jobjoiner) == "table" then
		return data.jobjoiner, "teleportData"
	end

	local ok2, raw = pcall(function()
		return TeleportService:GetTeleportSetting(PERSIST_KEY)
	end)
	if ok2 and type(raw) == "string" and raw ~= "" then
		local ok3, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok3 and type(decoded) == "table" then
			return decoded, "teleportSetting"
		end
	end

	if has_files() then
		local okE, exists = pcall(isfile, PERSIST_FILE)
		if okE and exists then
			local ok4, raw2 = pcall(readfile, PERSIST_FILE)
			if ok4 then
				local ok5, decoded = pcall(function()
					return HttpService:JSONDecode(raw2)
				end)
				if ok5 and type(decoded) == "table" then
					return decoded, "file"
				end
			end
		end
	end

	return nil, "none"
end

local function mark_visited(jobId)
	if not jobId or jobId == "" or visited[jobId] then
		return
	end
	visited[jobId] = true
	table.insert(visited_order, jobId)
	while #visited_order > MAX_VISITED do
		local old = table.remove(visited_order, 1)
		visited[old] = nil
	end
end

--==============================================================
--  TIMER TRACKER
--==============================================================
local live_remaining = nil

-- keep the table bounded: drop least-sampled, then oldest
local function evict_timers()
	local n = timer_count()
	if n <= MAX_TIMERS then
		return
	end
	local list = {}
	for id, e in pairs(timers) do
		if id ~= game.JobId then
			table.insert(list, { id = id, samples = e.samples or 1, seenAt = e.seenAt or 0 })
		end
	end
	table.sort(list, function(a, b)
		if a.samples ~= b.samples then
			return a.samples < b.samples
		end
		return a.seenAt < b.seenAt
	end)
	local toRemove = n - MAX_TIMERS
	for i = 1, math.min(toRemove, #list) do
		timers[list[i].id] = nil
	end
end

local function record_timer(jobId, remaining, playing, maxP)
	if not jobId or jobId == "" then
		return
	end
	if type(remaining) ~= "number" or remaining < 0 or remaining > CYCLE + 2 then
		return
	end

	local t = now_secs()
	local entry = timers[jobId] or { samples = 0 }
	entry.phase = (t + remaining) % CYCLE
	entry.samples = (entry.samples or 0) + 1
	entry.seenAt = t
	entry.playing = playing or entry.playing
	entry.max = maxP or entry.max
	timers[jobId] = entry

	evict_timers()
	persist_save()
end

local function prune_timers()
	local t = now_secs()
	for id, e in pairs(timers) do
		if (t - (e.seenAt or 0)) > TIMER_TTL then
			timers[id] = nil
		end
	end
	evict_timers()
end

-- best target inside [min_lead, min_lead + hop_window]
local function best_in_window()
	local t = now_secs()
	local bestId, bestR = nil, nil
	for id, e in pairs(timers) do
		if id ~= game.JobId and e.phase then
			local r = remaining_at(e.phase, t)
			if r >= min_lead and r <= (min_lead + hop_window) then
				if not bestR or r < bestR then
					bestId, bestR = id, r
				end
			end
		end
	end
	return bestId, bestR
end

-- all candidates, soonest first
local function timer_candidates()
	local t = now_secs()
	local list = {}
	for id, e in pairs(timers) do
		if id ~= game.JobId and e.phase then
			table.insert(list, { id = id, remaining = remaining_at(e.phase, t) })
		end
	end
	table.sort(list, function(a, b)
		if math.abs(a.remaining - b.remaining) > 0.001 then
			return a.remaining < b.remaining
		end
		return a.id < b.id
	end)
	return list
end

local function my_remaining()
	local e = timers[game.JobId]
	if e and e.phase then
		return remaining_at(e.phase, now_secs())
	end
	return live_remaining
end

--// parse the countdown out of the hint text
local function parse_seconds(txt)
	if type(txt) ~= "string" then
		return nil
	end
	local m, s = txt:match("(%d+):(%d%d)")
	if m then
		return tonumber(m) * 60 + tonumber(s)
	end
	local n = txt:match("(%d+%.?%d*)")
	return n and tonumber(n) or nil
end

local function watch_hint()
	local hint = workspace:FindFirstChild(HINT_NAME)
	if not hint then
		local t0 = tick()
		while tick() - t0 < 30 do
			hint = workspace:FindFirstChild(HINT_NAME)
			if hint then
				break
			end
			task.wait(0.5)
		end
	end
	if not hint then
		warn("[TIMER] no '" .. HINT_NAME .. "' found in workspace")
		return
	end

	local function handle()
		local r = parse_seconds(hint.Text)
		if not r then
			return
		end
		live_remaining = r + TIMER_OFFSET
		record_timer(game.JobId, live_remaining, #Players:GetPlayers(), Players.MaxPlayers)
	end

	handle()
	hint:GetPropertyChangedSignal("Text"):Connect(handle)
	library:Notify("Timer source hooked", "ok")
end

task.spawn(watch_hint)

--==============================================================
--  MONEY TRACKER
--==============================================================
local function parse_number(txt)
	if type(txt) ~= "string" then
		return nil
	end
	local digits = txt:gsub("[^%d]", "")
	if digits == "" then
		return nil
	end
	return tonumber(digits)
end

local function push_history(gold, force)
	local h = stats.history
	local t = os.time()
	local last = h[#h]
	if last and not force and (t - last.t) < 1 and last.g == gold then
		return
	end
	table.insert(h, { t = t, g = gold })
	while #h > MAX_HISTORY do
		table.remove(h, 1)
	end
end

local function record_gold(gold)
	if type(gold) ~= "number" then
		return
	end

	if not stats.startGold then
		stats.startGold = gold
		stats.sessionStart = os.time()
	end

	local prev = stats.lastGold
	stats.lastGold = gold

	if prev and gold > prev then
		local delta = gold - prev
		stats.claims += 1
		stats.claimTotal += delta
		if delta > stats.bestClaim then
			stats.bestClaim = delta
		end
		local e = timers[game.JobId]
		if e then
			e.gain = delta
		end
		logf("CLAIM +$%s (total $%s, claim #%d)", comma(delta), comma(gold), stats.claims)
	end

	push_history(gold)
	write_next_target()
	persist_save()
end

local function watch_money()
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local sg
	local t0 = tick()
	while tick() - t0 < 30 do
		sg = pg:FindFirstChild(MONEY_GUI)
		if sg then
			break
		end
		task.wait(0.5)
	end
	if not sg then
		warn("[MONEY] no '" .. MONEY_GUI .. "' found in PlayerGui")
		return
	end

	local goldLbl = sg:FindFirstChild(MONEY_LABEL, true)
	local lvlLbl = sg:FindFirstChild(LEVEL_LABEL, true)

	if goldLbl then
		record_gold(parse_number(goldLbl.Text))
		goldLbl:GetPropertyChangedSignal("Text"):Connect(function()
			record_gold(parse_number(goldLbl.Text))
		end)
		library:Notify("Money source hooked", "ok")
	else
		warn("[MONEY] no '" .. MONEY_LABEL .. "' found")
	end

	if lvlLbl then
		stats.level = parse_number(lvlLbl.Text)
		lvlLbl:GetPropertyChangedSignal("Text"):Connect(function()
			stats.level = parse_number(lvlLbl.Text)
		end)
	end

	-- heartbeat so idle time still shows on the graph
	task.spawn(function()
		while gui.Parent do
			if stats.lastGold then
				push_history(stats.lastGold, true)
			end
			task.wait(HEARTBEAT)
		end
	end)
end

task.spawn(watch_money)

--==============================================================
--  SERVER CACHE
--==============================================================
-- Roblox's Luau only exposes collectgarbage("count"); we cannot force a
-- collection, so the watchdog can only observe and back off.
local function mem_mb()
	local ok, kb = pcall(collectgarbage, "count")
	if not ok or type(kb) ~= "number" then
		return 0
	end
	return kb / 1024
end

local function mem_over_budget()
	if not mem_baseline then
		return false, 0
	end
	local growth = mem_mb() - mem_baseline
	return growth > CFG.MEM_GROWTH_MB, growth
end

local function auto_runtime()
	if not auto_started_at then
		return 0
	end
	return math.max(0, os.time() - auto_started_at)
end

local function update_cache_label()
	local age = (cache_fetched_at > 0) and math.max(0, os.time() - cache_fetched_at) or 0
	local mem = math.floor(mem_mb())
	local run = auto_started_at and (" · " .. dur(auto_runtime())) or ""
	cacheLabel.Text = string.format(
		"cache %d · pool %d/%d · %ds · %dMB · h%d%s · %s",
		#server_cache,
		timer_count(),
		explore_target,
		age,
		mem,
		stats.hops,
		run,
		auto_status
	)
end

local function cache_is_valid()
	return #server_cache > 0 and (os.time() - cache_fetched_at) < CACHE_TTL
end

local function invalidate_cache()
	server_cache = {}
	cache_fetched_at = 0
	persist_save(true)
	update_cache_label()
end

local function fetch_cache(ignoreVisited)
	if not get_request_fn() then
		return false, "no HTTP function (executor required)"
	end

	local collected, seen = {}, {}
	local cursor, pages_done = nil, 0
	local lastErr = nil

	repeat
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?limit=100&excludeFullGames=true",
			game.PlaceId
		)
		if cursor then
			url = url .. "&cursor=" .. cursor
		end

		local data, err = get_json(url)
		if not data then
			lastErr = err
			break
		end

		for _, s in ipairs(data.data or {}) do
			local playing = tonumber(s.playing) or 0
			local maxP = tonumber(s.maxPlayers) or 0
			local fresh = ignoreVisited or not visited[s.id]
			if s.id and s.id ~= game.JobId and not seen[s.id] and fresh and playing < maxP then
				seen[s.id] = true
				table.insert(collected, { id = s.id, playing = playing, max = maxP })
			end
			if s.id and timers[s.id] then
				timers[s.id].playing = playing
				timers[s.id].max = maxP
			end
		end

		cursor = data.nextPageCursor
		pages_done += 1
		if cursor and #collected < CACHE_SIZE and pages_done < FETCH_PAGES then
			task.wait(0.35)
		end
	until not cursor or #collected >= CACHE_SIZE or pages_done >= FETCH_PAGES

	if #collected == 0 then
		return false, lastErr or "no joinable server found"
	end

	while #collected > CACHE_SIZE do
		table.remove(collected)
	end

	server_cache = collected
	cache_fetched_at = os.time()
	fail_streak = 0
	persist_save(true)
	update_cache_label()
	return true
end

local function take_random()
	if #server_cache == 0 then
		return nil
	end
	local i = math.random(1, #server_cache)
	local s = table.remove(server_cache, i)
	persist_save()
	update_cache_label()
	return s
end

local function take_smallest()
	if #server_cache == 0 then
		return nil
	end
	local bestI, bestCount = 1, math.huge
	for i, s in ipairs(server_cache) do
		if s.playing < bestCount then
			bestI, bestCount = i, s.playing
		end
	end
	local s = table.remove(server_cache, bestI)
	persist_save()
	update_cache_label()
	return s
end

-- a cached entry we have never sampled a timer for (random pick)
local function take_unsampled()
	local pool = {}
	for i, s in ipairs(server_cache) do
		if s.id ~= game.JobId and not timers[s.id] then
			table.insert(pool, i)
		end
	end
	if #pool == 0 then
		return nil
	end
	local idx = pool[math.random(1, #pool)]
	local s = table.remove(server_cache, idx)
	persist_save()
	update_cache_label()
	return s
end

--==============================================================
--  RESTORE ON BOOT
--==============================================================
local function restore_cache()
	local saved, backend = persist_load()
	persist_backend = backend

	if not saved or saved.placeId ~= game.PlaceId then
		update_cache_label()
		return false
	end

	for _, id in ipairs(saved.visited or {}) do
		mark_visited(id)
	end

	if type(saved.lead) == "number" then
		min_lead = saved.lead
	end
	if type(saved.window) == "number" then
		hop_window = saved.window
	end
	if type(saved.claim) == "number" then
		claim_offset = saved.claim
	end
	if type(saved.explore) == "number" then
		explore_target = math.clamp(math.floor(saved.explore), 1, MAX_TIMERS)
		exploreBox.Text = tostring(explore_target)
	end
	auto_enabled = saved.auto == true
	auto_started_at = tonumber(saved.autoStart)
	sliderLead.render()
	sliderWindow.render()
	sliderClaim.render()

	local st = saved.stats
	if type(st) == "table" then
		stats.sessionStart = tonumber(st.sessionStart) or stats.sessionStart
		stats.startGold = tonumber(st.startGold)
		stats.lastGold = tonumber(st.lastGold)
		stats.level = tonumber(st.level)
		stats.claims = tonumber(st.claims) or 0
		stats.claimTotal = tonumber(st.claimTotal) or 0
		stats.bestClaim = tonumber(st.bestClaim) or 0
		stats.hops = tonumber(st.hops) or 0
		stats.explored = tonumber(st.explored) or 0
		stats.history = {}
		for _, h in ipairs(st.history or {}) do
			if type(h) == "table" and tonumber(h.t) and tonumber(h.g) then
				table.insert(stats.history, { t = tonumber(h.t), g = tonumber(h.g) })
			end
		end
	end

	local t = now_secs()
	local restoredTimers = 0
	for _, e in ipairs(saved.timers or {}) do
		if e.id and type(e.phase) == "number" and (t - (tonumber(e.seenAt) or 0)) < TIMER_TTL then
			timers[e.id] = {
				phase = e.phase % CYCLE,
				samples = tonumber(e.samples) or 1,
				seenAt = tonumber(e.seenAt) or t,
				playing = tonumber(e.playing),
				max = tonumber(e.max),
				gain = tonumber(e.gain),
			}
			restoredTimers += 1
		end
	end
	evict_timers()

	mark_visited(game.JobId)

	local age = os.time() - (tonumber(saved.savedAt) or 0)
	local restored = {}
	if age < CACHE_TTL then
		for _, s in ipairs(saved.servers or {}) do
			if s.id and s.id ~= game.JobId then
				table.insert(restored, {
					id = s.id,
					playing = tonumber(s.playing) or 0,
					max = tonumber(s.max) or 0,
				})
			end
		end
	end

	if #restored > 0 then
		server_cache = restored
		cache_fetched_at = tonumber(saved.savedAt) or os.time()
	end

	update_cache_label()
	return true, #restored, restoredTimers, math.max(0, age)
end

--==============================================================
--  TELEPORT
--==============================================================
local teleport_failed = false
local teleport_fail_reason = ""

TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage)
	if player == LocalPlayer then
		teleport_failed = true
		teleport_fail_reason = (errorMessage ~= "" and errorMessage) or tostring(result)
	end
end)

local function extract_job_id(txt)
	txt = tostring(txt or ""):gsub("%s+", "")
	local fromUrl = txt:match("gameInstanceId=([%w%-]+)")
	if fromUrl then
		return fromUrl
	end
	local guid = txt:match("%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x")
	return guid or txt
end

local busy = false
local last_hop_at = 0
local set_auto_status -- forward declaration (defined in the AUTO MODE section)

-- every DataModel rebuild leaks a little; this is the main defence against
-- the client being OOM-killed during long sessions
local function hop_gate_wait()
	if CFG.MIN_HOP_INTERVAL <= 0 then
		return true
	end
	local waitFor = CFG.MIN_HOP_INTERVAL - (tick() - last_hop_at)
	if waitFor <= 0 then
		return true
	end
	local deadline = tick() + waitFor
	while tick() < deadline do
		if auto_enabled == false and busy == false then
			-- manual joins should not be blocked for long
			break
		end
		set_auto_status(string.format("cool %.0fs", deadline - tick()))
		task.wait(0.25)
	end
	return true
end

local function set_busy(state, joinText, smartText, smallestText, hopText)
	busy = state
	btnJoin.Text = joinText or "Join Server"
	btnSmart.Text = smartText or "Hop to Ending Soonest"
	btnSmallest.Text = smallestText or "Smallest"
	btnHop.Text = hopText or "Random Hop"
end

local teleport_in_flight = false

local function attempt_join(jobId, timeoutSecs, isExplore)
	timeoutSecs = timeoutSecs or 20

	-- a superseded copy must never touch TeleportService
	if should_stop() then
		return false, "superseded"
	end

	-- one teleport at a time, no matter how many coroutines ask
	if teleport_in_flight then
		return false, "teleport already in flight"
	end
	teleport_in_flight = true

	teleport_failed, teleport_fail_reason = false, ""

	local mineNow = my_remaining()
	local targetE = timers[jobId]
	logf(
		"HOP#%d %s -> %s | mine %s | target %s | pool %d | cache %d",
		stats.hops + 1,
		isExplore and "explore" or "timed",
		jobId:sub(1, 8),
		mineNow and string.format("%.1fs", mineNow) or "?",
		(targetE and targetE.phase) and string.format("%.1fs", remaining_at(targetE.phase, now_secs())) or "new",
		timer_count(),
		#server_cache
	)

	last_hop_at = tick()
	mark_visited(game.JobId)
	stats.hops += 1
	if isExplore then
		stats.explored += 1
	end
	persist_save(true)

	local tpData = { jobjoiner = build_payload(TP_DATA_MAX, TP_TIMER_MAX, TP_HIST_MAX) }

	local ok, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer, nil, tpData)
	end)
	if not ok then
		teleport_failed = true
		teleport_fail_reason = tostring(err)
	end

	local timeout = tick() + timeoutSecs
	while tick() < timeout and not teleport_failed do
		task.wait(0.1)
	end

	if teleport_failed then
		teleport_in_flight = false
		logf("HOP FAILED: %s", teleport_fail_reason)
		stats.hops = math.max(0, stats.hops - 1)
		if isExplore then
			stats.explored = math.max(0, stats.explored - 1)
		end
		return false, teleport_fail_reason
	end

	logf("HOP ACCEPTED, transferring")
	return true
end

local function join_game_by_id(jobId)
	jobId = extract_job_id(jobId)

	if jobId == "" then
		library:Notify("Please enter a valid Job ID", "error")
		return
	end
	if jobId == game.JobId then
		library:Notify("You are already in this server", "warn")
		return
	end
	if busy then
		return
	end

	set_busy(true, "Connecting...")
	library:Notify("Joining server: " .. jobId:sub(1, 8) .. "...")

	local ok, reason = attempt_join(jobId)
	if ok then
		library:Notify("Teleport accepted, transferring...", "ok")
		task.wait(5)
	else
		library:Notify("Server join failed: " .. reason, "error", 5)
	end

	set_busy(false)
end

--==============================================================
--  SMART HOP (manual, timer-aware)
--==============================================================
local function smart_hop()
	if busy then
		return
	end

	prune_timers()
	local list = timer_candidates()
	if #list == 0 then
		library:Notify("No timed servers known yet — explore first", "warn", 5)
		return
	end

	set_busy(true, nil, "Picking...")

	local tried = 0
	for _, c in ipairs(list) do
		if tried >= MAX_ATTEMPTS then
			break
		end
		local e = timers[c.id]
		if e then
			local r = remaining_at(e.phase, now_secs())
			if r >= min_lead then
				tried += 1
				library:Notify(string.format("Target %s — %.1fs left (try %d)", c.id:sub(1, 8), r, tried))
				box.Text = c.id

				local ok, reason = attempt_join(c.id, 12)
				if ok then
					library:Notify("Teleport accepted, transferring...", "ok")
					task.wait(5)
					set_busy(false)
					return
				end

				library:Notify("Failed: " .. reason, "error")
				if reason:lower():find("flood") then
					library:Notify("Teleport rate limited — wait a bit", "warn", 6)
					set_busy(false)
					return
				end
				timers[c.id] = nil
				task.wait(0.5)
			end
		end
	end

	if tried == 0 then
		library:Notify(string.format("Nothing above %ds lead right now", min_lead), "warn", 5)
	else
		library:Notify("No reachable target found", "error", 5)
	end
	set_busy(false)
end

--==============================================================
--  CACHED HOP (smallest + random)
--==============================================================
local function cached_hop(picker, label)
	if busy then
		return
	end

	if not get_request_fn() then
		if picker == take_random then
			library:Notify("No HTTP function — using matchmaking fallback", "warn")
			set_busy(true, nil, nil, nil, "Hopping...")
			mark_visited(game.JobId)
			persist_save(true)
			pcall(function()
				TeleportService:Teleport(game.PlaceId, LocalPlayer)
			end)
			task.wait(5)
			set_busy(false)
		else
			library:Notify("Server list needs an executor HTTP function", "error", 5)
		end
		return
	end

	set_busy(
		true,
		nil,
		nil,
		(picker == take_smallest) and "Searching..." or nil,
		(picker == take_random) and "Hopping..." or nil
	)

	for attempt = 1, MAX_ATTEMPTS do
		if fail_streak >= MAX_FAILS then
			library:Notify(string.format("%d fails — refreshing cache", MAX_FAILS), "warn")
			fail_streak = 0
			invalidate_cache()
		end

		if #server_cache == 0 or not cache_is_valid() then
			local ok, err = fetch_cache()
			if not ok then
				library:Notify("Could not fetch servers: " .. tostring(err), "error", 5)
				set_busy(false)
				return
			end
		end

		local s = picker()
		if not s then
			library:Notify("Cache drained with no valid server", "error", 5)
			set_busy(false)
			return
		end

		library:Notify(string.format("%s — %d/%d players (try %d)", label, s.playing, s.max, attempt))
		box.Text = s.id

		local ok, reason = attempt_join(s.id, 12)
		if ok then
			fail_streak = 0
			library:Notify("Teleport accepted, transferring...", "ok")
			task.wait(5)
			set_busy(false)
			return
		end

		fail_streak += 1
		update_cache_label()
		library:Notify(string.format("Failed (%d/%d): %s", fail_streak, MAX_FAILS, reason), "error")

		if reason:lower():find("flood") then
			library:Notify("Teleport rate limited — wait a bit", "warn", 6)
			set_busy(false)
			return
		end

		task.wait(0.5)
	end

	library:Notify(string.format("Gave up after %d attempts", MAX_ATTEMPTS), "error", 5)
	set_busy(false)
end

--==============================================================
--  AUTO MODE
--==============================================================
local function render_auto_button()
	btnAuto:SetAttribute("locked", auto_enabled)
	exploreBox.TextEditable = not auto_enabled
	if auto_enabled then
		btnAuto.BackgroundColor3 = T.ok
		btnAuto.TextColor3 = Color3.new(0, 0, 0)
		btnAuto.Text = "AUTO: " .. auto_status
		statusDot.BackgroundColor3 = T.ok
	else
		btnAuto.BackgroundColor3 = T.panel
		btnAuto.TextColor3 = T.dim
		btnAuto.Text = "AUTO: OFF"
		statusDot.BackgroundColor3 = T.accent
	end
end

function set_auto_status(s)
	auto_status = s
	render_auto_button()
end

-- grab an unsampled server, refetching / widening as needed
local function pick_explore_target()
	local s = take_unsampled()
	if s then
		return s
	end

	if get_request_fn() then
		set_auto_status("fetching")
		if fetch_cache() then
			s = take_unsampled()
			if s then
				return s
			end
		end
		-- everything cached is already known: drop visited and look wider
		visited, visited_order = {}, {}
		mark_visited(game.JobId)
		if fetch_cache(true) then
			s = take_unsampled()
			if s then
				return s
			end
		end
	end
	return nil
end

local function cooldown(secs, why)
	library:Notify(string.format("Teleport rate limited — auto paused %ds", secs), "warn", 6)
	set_auto_status("cooldown")
	local t1 = tick()
	while auto_enabled and (tick() - t1) < secs do
		task.wait(0.3)
	end
end

local function auto_loop()
	-- let the hint report at least once so this server gets sampled
	local t0 = tick()
	while auto_enabled and not timers[game.JobId] and (tick() - t0) < 10 do
		set_auto_status("sampling")
		task.wait(0.2)
	end

	while auto_enabled do
		if should_stop() then
			logf("SUPERSEDED by a newer injection — auto stopping")
			auto_enabled = false
			break
		end

		if busy then
			task.wait(0.3)
			continue
		end

		-- optional runtime limit
		if CFG.AUTO_MAX_HOURS > 0 and auto_runtime() >= CFG.AUTO_MAX_HOURS * 3600 then
			library:Notify(string.format("Ran for %s — auto off (time limit)", dur(auto_runtime())), "warn", 10)
			auto_enabled = false
			persist_save(true)
			break
		end

		-- memory watchdog: idling lets the engine reclaim between teleports
		local over, growth = mem_over_budget()
		if over then
			if not mem_pressure_since then
				mem_pressure_since = os.time()
				logf("MEM PRESSURE +%.0fMB over baseline %.0fMB", growth, mem_baseline or 0)
				library:Notify(
					string.format("Memory +%dMB over baseline — pausing to settle", math.floor(growth)),
					"warn",
					6
				)
			end

			if (os.time() - mem_pressure_since) > CFG.MEM_GIVEUP_MIN * 60 then
				library:Notify(
					string.format(
						"Memory stayed +%dMB for %dmin — auto off, restart the client",
						math.floor(growth),
						CFG.MEM_GIVEUP_MIN
					),
					"error",
					12
				)
				auto_enabled = false
				persist_save(true)
				break
			end

			set_auto_status(string.format("mem +%dMB", math.floor(growth)))
			local t1 = tick()
			while auto_enabled and (tick() - t1) < CFG.MEM_PAUSE_SECS do
				task.wait(0.5)
			end
			continue
		elseif mem_pressure_since then
			logf("MEM RECOVERED after %ds", os.time() - mem_pressure_since)
			mem_pressure_since = nil
			library:Notify("Memory recovered — resuming", "ok")
		end

		prune_timers()

		-- BOOTSTRAP: grow the pool with random unsampled servers first
		if timer_count() < explore_target then
			if not timers[game.JobId] then
				set_auto_status("sampling")
				task.wait(0.25)
				continue
			end

			set_auto_status(string.format("explore %d/%d", timer_count(), explore_target))
			local s = pick_explore_target()
			if not s then
				explore_fails += 1
				if explore_fails >= CFG.MAX_EXPLORE_FAILS then
					library:Notify("Nothing new to explore — switching to timer mode", "warn", 5)
					explore_target = math.max(1, timer_count())
					exploreBox.Text = tostring(explore_target)
					explore_fails = 0
					persist_save(true)
				else
					-- back off instead of hammering the API every 0.3s
					set_auto_status("backoff")
					local t1 = tick()
					while auto_enabled and (tick() - t1) < 5 do
						task.wait(0.3)
					end
				end
			else
				explore_fails = 0
				hop_gate_wait()
				busy = true
				box.Text = s.id
				local ok, reason = attempt_join(s.id, 12, true)
				busy = false
				if ok then
					task.wait(5)
				elseif reason:lower():find("flood") then
					cooldown(15)
				end
			end
			task.wait(CFG.EXPLORE_COOLDOWN)
			continue
		end

		-- stay through the payout: wait for zero, then claim_offset more
		local mine = my_remaining()
		if mine then
			if claim_offset > 0 and mine > CYCLE - claim_offset then
				set_auto_status(string.format("payout %.1fs", claim_offset - (CYCLE - mine)))
				task.wait(0.15)
				continue
			end
			if mine <= (min_lead + hop_window) then
				set_auto_status(string.format("wait %.0fs", mine))
				task.wait(0.25)
				continue
			end
		end

		local targetId, targetR = best_in_window()

		if targetId then
			set_auto_status(string.format("hop %.0fs", targetR))
			hop_gate_wait()
			busy = true
			box.Text = targetId
			local ok, reason = attempt_join(targetId, 12)
			busy = false

			if ok then
				task.wait(5)
			else
				timers[targetId] = nil
				persist_save(true)
				if reason:lower():find("flood") then
					cooldown(15)
				end
			end
		else
			-- nothing worth hopping to: use the dead time to grow the pool
			set_auto_status("explore")
			local s = pick_explore_target()
			if not s then
				set_auto_status("idle")
				local t1 = tick()
				while auto_enabled and (tick() - t1) < 8 do
					task.wait(0.3)
				end
			else
				hop_gate_wait()
				busy = true
				box.Text = s.id
				local ok, reason = attempt_join(s.id, 12, true)
				busy = false
				if ok then
					task.wait(5)
				elseif reason:lower():find("flood") then
					cooldown(15)
				end
			end
		end

		task.wait(0.3)
	end

	set_auto_status("idle")
	render_auto_button()
end

local function toggle_auto(force)
	if not auto_enabled then
		local n = tonumber(exploreBox.Text)
		if n then
			explore_target = math.clamp(math.floor(n), 1, MAX_TIMERS)
		end
		exploreBox.Text = tostring(explore_target)
	end

	auto_enabled = (force ~= nil) and force or not auto_enabled

	if auto_enabled then
		auto_started_at = auto_started_at or os.time()
		logf("AUTO ON (pool target %d, lead %ds, window +%ds)", explore_target, min_lead, hop_window)
	else
		logf("AUTO OFF after %s, %d hops", dur(auto_runtime()), stats.hops)
		auto_started_at = nil
		mem_pressure_since = nil
	end

	persist_save(true)
	render_auto_button()

	if auto_enabled then
		local limit = (CFG.AUTO_MAX_HOURS > 0) and string.format(", limit %gh", CFG.AUTO_MAX_HOURS) or ""
		library:Notify(
			string.format("Auto ON — pool %d, lead %ds, window +%ds%s", explore_target, min_lead, hop_window, limit),
			"ok"
		)
		task.spawn(auto_loop)
	else
		library:Notify("Auto OFF", "warn")
	end
end

--==============================================================
--  SERVERS LIST (pooled rows — bounded instance count)
--==============================================================
local rowPool = {}

local function get_row(i)
	if rowPool[i] then
		return rowPool[i]
	end

	local row = new("TextButton", {
		LayoutOrder = i,
		Size = UDim2.new(1, -6, 0, 34),
		BackgroundColor3 = T.panel,
		AutoButtonColor = false,
		Text = "",
		Visible = false,
		Parent = scroll,
	})
	corner(6, row)

	local nameLbl = new("TextLabel", {
		Position = UDim2.new(0, 10, 0, 5),
		Size = UDim2.new(1, -80, 0, 12),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 10,
		TextColor3 = T.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = row,
	})

	local metaLbl = new("TextLabel", {
		Position = UDim2.new(0, 10, 0, 18),
		Size = UDim2.new(1, -80, 0, 11),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 9,
		TextColor3 = T.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = row,
	})

	local timeLbl = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.new(0, 60, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextColor3 = T.text,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "--",
		Parent = row,
	})

	row.MouseEnter:Connect(function()
		TweenService:Create(row, TweenInfo.new(0.1), { BackgroundColor3 = T.input }):Play()
	end)
	row.MouseLeave:Connect(function()
		TweenService:Create(row, TweenInfo.new(0.1), { BackgroundColor3 = T.panel }):Play()
	end)
	row.MouseButton1Click:Connect(function()
		local id = row:GetAttribute("jobId")
		if not id or id == "" then
			return
		end
		box.Text = id
		if id == game.JobId then
			library:Notify("You are already in this server", "warn")
		else
			task.spawn(join_game_by_id, id)
		end
	end)

	local entry = { frame = row, name = nameLbl, meta = metaLbl, time = timeLbl }
	rowPool[i] = entry
	return entry
end

local function render_servers()
	prune_timers()
	local t = now_secs()
	local list = timer_candidates()

	-- include our own server at the top of the list
	local mineE = timers[game.JobId]
	if mineE and mineE.phase then
		table.insert(list, 1, { id = game.JobId, remaining = remaining_at(mineE.phase, t) })
	end

	local usable = 0
	for _, c in ipairs(list) do
		if c.id ~= game.JobId and c.remaining >= min_lead and c.remaining <= min_lead + hop_window then
			usable += 1
		end
	end

	local shown = math.min(#list, MAX_ROWS)
	for i = 1, shown do
		local c = list[i]
		local e = timers[c.id]
		local row = get_row(i)
		row.frame.Visible = true
		row.frame:SetAttribute("jobId", c.id)

		local isCurrent = (c.id == game.JobId)
		row.name.Text = c.id:sub(1, 12) .. (isCurrent and "  (you)" or "")
		row.name.TextColor3 = isCurrent and T.accent or T.text

		row.time.Text = string.format("%.1fs", c.remaining)
		local inWindow = (c.remaining >= min_lead and c.remaining <= min_lead + hop_window)
		if isCurrent then
			row.time.TextColor3 = T.accent
		elseif inWindow then
			row.time.TextColor3 = T.ok
		elseif c.remaining >= min_lead then
			row.time.TextColor3 = T.warn
		else
			row.time.TextColor3 = T.err
		end

		local players = (e.playing and e.max) and string.format("%d/%d · ", e.playing, e.max) or ""
		local gain = e.gain and string.format(" · +$%s", comma(e.gain)) or ""
		row.meta.Text =
			string.format("%s%dx · %ds ago%s", players, e.samples or 0, math.floor(t - (e.seenAt or t)), gain)
	end

	for i = shown + 1, #rowPool do
		rowPool[i].frame.Visible = false
	end

	local count = #list
	tabServers.Text = string.format("Servers (%d)", count)
	if count == 0 then
		serversHeader.Text = "DISCOVERED — waiting for first reading"
	else
		serversHeader.Text = string.format(
			"%d known%s · %d in [%d–%ds]",
			count,
			(count > MAX_ROWS) and (" (top " .. MAX_ROWS .. ")") or "",
			usable,
			min_lead,
			min_lead + hop_window
		)
	end
end

--==============================================================
--  STATS RENDER (pooled bars)
--==============================================================
local barPool = {}

local function get_bar(i)
	if barPool[i] then
		return barPool[i]
	end
	local b = new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = T.accent,
		BorderSizePixel = 0,
		Visible = false,
		Parent = graphCanvas,
	})
	corner(1, b)
	barPool[i] = b
	return b
end

local function render_graph()
	local h = stats.history
	local n = #h
	if n < 2 then
		graphMax.Text = "not enough data yet"
		graphSpan.Text = ""
		for i = 1, #barPool do
			barPool[i].Visible = false
		end
		return
	end

	local startI = math.max(1, n - GRAPH_POINTS + 1)
	local pts = {}
	for i = startI, n do
		table.insert(pts, h[i])
	end

	local lo, hi = math.huge, -math.huge
	for _, p in ipairs(pts) do
		if p.g < lo then
			lo = p.g
		end
		if p.g > hi then
			hi = p.g
		end
	end
	local span = math.max(1, hi - lo)
	local count = #pts

	for i, p in ipairs(pts) do
		local bar = get_bar(i)
		local frac = (p.g - lo) / span
		local height = 0.06 + frac * 0.94
		bar.Visible = true
		bar.Position = UDim2.new((i - 1) / count, 1, 1, 0)
		bar.Size = UDim2.new(1 / count, -2, height, 0)
		bar.BackgroundColor3 = (i == count) and T.ok or T.accent
	end

	for i = count + 1, #barPool do
		barPool[i].Visible = false
	end

	graphMax.Text = "$" .. comma(hi)
	graphSpan.Text = dur(pts[#pts].t - pts[1].t) .. " span"
end

local function render_stats()
	local nowGold = stats.lastGold
	local startGold = stats.startGold
	local elapsed = os.time() - stats.sessionStart

	statLabels.started.Text = os.date("%H:%M:%S", stats.sessionStart)
	statLabels.elapsed.Text = dur(elapsed)
	statLabels.startGold.Text = startGold and ("$" .. comma(startGold)) or "--"
	statLabels.nowGold.Text = nowGold and ("$" .. comma(nowGold)) or "--"

	if startGold and nowGold then
		local d = nowGold - startGold
		statLabels.gained.Text = string.format("%s$%s", d >= 0 and "+" or "-", comma(math.abs(d)))
		statLabels.gained.TextColor3 = (d > 0) and T.ok or ((d < 0) and T.err or T.text)

		local perHour = (elapsed > 5) and (d / elapsed * 3600) or 0
		statLabels.rate.Text = "$" .. comma(perHour) .. "/h"
		statLabels.rate.TextColor3 = (perHour > 0) and T.ok or T.text
	else
		statLabels.gained.Text = "--"
		statLabels.rate.Text = "--"
	end

	statLabels.claims.Text = tostring(stats.claims)
	if stats.claims > 0 then
		statLabels.avgClaim.Text =
			string.format("$%s / $%s", comma(stats.claimTotal / stats.claims), comma(stats.bestClaim))
	else
		statLabels.avgClaim.Text = "--"
	end

	statLabels.hops.Text = string.format("%d / %d", stats.hops, stats.explored)
	statLabels.level.Text = stats.level and tostring(stats.level) or "--"

	render_graph()
end

--==============================================================
--  BINDINGS
--==============================================================
btnJoin.MouseButton1Click:Connect(function()
	task.spawn(join_game_by_id, box.Text)
end)

btnSmart.MouseButton1Click:Connect(function()
	task.spawn(smart_hop)
end)

btnAuto.MouseButton1Click:Connect(function()
	toggle_auto()
end)

btnSmallest.MouseButton1Click:Connect(function()
	task.spawn(cached_hop, take_smallest, "Smallest server")
end)

btnHop.MouseButton1Click:Connect(function()
	task.spawn(cached_hop, take_random, "Random server")
end)

exploreBox.FocusLost:Connect(function()
	local n = tonumber(exploreBox.Text)
	if n then
		explore_target = math.clamp(math.floor(n), 1, MAX_TIMERS)
	end
	exploreBox.Text = tostring(explore_target)
	persist_save(true)
	update_cache_label()
end)

btnResetStats.MouseButton1Click:Connect(function()
	stats.sessionStart = os.time()
	stats.startGold = stats.lastGold
	stats.claims = 0
	stats.claimTotal = 0
	stats.bestClaim = 0
	stats.hops = 0
	stats.explored = 0
	stats.history = {}
	if stats.lastGold then
		push_history(stats.lastGold, true)
	end
	persist_save(true)
	library:Notify("Session stats reset", "ok")
end)

cacheLabel.MouseButton1Click:Connect(function()
	if busy or auto_enabled then
		return
	end
	task.spawn(function()
		set_busy(true)
		cacheLabel.Text = "cache: refreshing..."
		local ok, err = fetch_cache()
		if ok then
			library:Notify(string.format("Cache loaded: %d servers", #server_cache), "ok")
		else
			library:Notify("Cache refresh failed: " .. tostring(err), "error", 5)
		end
		update_cache_label()
		set_busy(false)
	end)
end)

box.FocusLost:Connect(function(enter)
	if enter then
		task.spawn(join_game_by_id, box.Text)
	end
end)

--// live refresh loop
task.spawn(function()
	local statTick = 0
	while gui.Parent and not should_stop() do
		update_cache_label()

		local jid = game.JobId ~= "" and game.JobId:sub(1, 18) or "studio"
		local mine = my_remaining()
		local money = stats.lastGold and ("  $" .. comma(stats.lastGold)) or ""
		if mine then
			current.Text = string.format("current: %s\ntimer: %.1fs%s", jid, mine, money)
		else
			current.Text = "current: " .. jid .. money
		end

		if pages.Servers.Visible then
			render_servers()
		end

		statTick += 1
		if pages.Stats.Visible and statTick >= 3 then
			statTick = 0
			render_stats()
		end

		task.wait(0.2)
	end
end)

--==============================================================
--  BOOT
--==============================================================
do
	-- only the current instance may re-queue, otherwise copies double each hop
	local qot = (syn and syn.queue_on_teleport) or queue_on_teleport
	if qot and SCRIPT_URL and not should_stop() then
		pcall(qot, ('loadstring(game:HttpGet("%s"))()'):format(SCRIPT_URL))
	end

	local ok, servers, tcount, age = restore_cache()
	if ok and (servers > 0 or tcount > 0) then
		library:Notify(
			string.format("Restored: %d servers, %d timers (%ds, %s)", servers, tcount, age, persist_backend),
			"ok"
		)
	else
		library:Notify("UI loaded — RightShift toggles visibility", "ok")
	end

	render_auto_button()
	render_servers()
	render_stats()

	logf(
		"=== BOOT === restored %s servers / %s timers (%s) | hops so far %d",
		tostring(servers or 0),
		tostring(tcount or 0),
		persist_backend,
		stats.hops
	)

	-- shrink the per-join allocation: fewer textures, no shadows, low quality
	if CFG.LOW_GRAPHICS then
		pcall(function()
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		end)
		pcall(function()
			local ugs = UserSettings():GetService("UserGameSettings")
			ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
		end)
		pcall(function()
			local Lighting = game:GetService("Lighting")
			Lighting.GlobalShadows = false
			Lighting.FogEnd = 512
			for _, fx in ipairs(Lighting:GetChildren()) do
				if fx:IsA("PostEffect") then
					fx.Enabled = false
				end
			end
		end)
		pcall(function()
			local terrain = workspace:FindFirstChildOfClass("Terrain")
			if terrain then
				terrain.Decoration = false
			end
		end)
	end

	if CFG.DISABLE_3D then
		pcall(function()
			game:GetService("RunService"):Set3dRenderingEnabled(false)
		end)
	end

	write_next_target(true)

	-- baseline a few seconds in, once the DataModel has settled
	task.spawn(function()
		task.wait(8)
		mem_baseline = mem_mb()
		logf("MEM baseline %.0fMB", mem_baseline)
	end)

	-- periodic heartbeat so a crash leaves a fresh memory reading behind
	task.spawn(function()
		while gui.Parent do
			task.wait(60)
			write_next_target(true)
			if auto_enabled then
				logf(
					"HEARTBEAT runtime %s | hops %d | pool %d | gold %s",
					dur(auto_runtime()),
					stats.hops,
					timer_count(),
					stats.lastGold and comma(stats.lastGold) or "?"
				)
			end
		end
	end)

	if auto_enabled and not should_stop() then
		auto_started_at = auto_started_at or os.time()
		library:Notify("Auto resumed after teleport", "ok")
		task.spawn(auto_loop)
	end

	-- a superseded copy tears itself down instead of lingering
	task.spawn(function()
		while not should_stop() do
			task.wait(0.5)
			if not gui.Parent then
				return
			end
		end
		logf("SUPERSEDED — shutting this copy down")
		auto_enabled = false
		pcall(function()
			gui:Destroy()
		end)
	end)
end
