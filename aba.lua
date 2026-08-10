--==============================================================
--  JOB ID JOINER — LocalScript (timer-aware + auto explore)
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
local TP_DATA_MAX = 25 -- servers carried in teleportData
local TP_TIMER_MAX = 40 -- timers carried in teleportData

--// timer tracking
local HINT_NAME = "Message" -- workspace child holding the countdown
local CYCLE = 30 -- countdown length in seconds
local TIMER_OFFSET = 1 -- display rounds down; add this to each reading
local TIMER_TTL = 3600 -- forget a phase after this many seconds
local EVENT_EPSILON = 1.5 -- "the timer just fired" threshold

--// sliders
local MIN_LEAD_MIN, MIN_LEAD_MAX = 1, 20
local WINDOW_MIN, WINDOW_MAX = 2, 25
local min_lead = 6 -- need at least this much time to land
local hop_window = 8 -- ...and no more than lead+window, else explore

--// persistence
local PERSIST_FILE = "jobjoiner_cache.json"
local PERSIST_KEY = "JobJoinerCache"
local SCRIPT_URL = "https://raw.githubusercontent.com/matheusrodrigues-s/aba/refs/heads/main/aba.lua"

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
local EXPANDED = UDim2.new(0, 320, 0, 440)
local COLLAPSED = UDim2.new(0, 320, 0, 38)

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
		Padding = UDim.new(0, 6),
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
	b:SetAttribute("base", true)
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

local btnAuto = makeButton(pageJoin, 4, "AUTO: OFF")

local btnRow = new("Frame", {
	LayoutOrder = 5,
	Size = UDim2.new(1, 0, 0, 30),
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

--// generic slider
local function makeSlider(parent, order, labelFmt, minV, maxV, getV, setV)
	local block = new("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 32),
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
		Position = UDim2.new(0, 0, 0, 20),
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
		setV(math.floor(minV + a * (maxV - minV) + 0.5))
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

local sliderLead = makeSlider(pageJoin, 6, "MIN LEAD: %ds", MIN_LEAD_MIN, MIN_LEAD_MAX, function()
	return min_lead
end, function(v)
	min_lead = v
end)

local sliderWindow = makeSlider(pageJoin, 7, "HOP WINDOW: +%ds", WINDOW_MIN, WINDOW_MAX, function()
	return hop_window
end, function(v)
	hop_window = v
end)

--// cache status
local cacheLabel = new("TextButton", {
	LayoutOrder = 8,
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
	LayoutOrder = 9,
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
--  DRAG + SLIDER INPUT
--==============================================================
local dragging, dragStart, startPos
titleBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging, dragStart, startPos = true, input.Position, main.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
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
	TweenService:Create(main, TweenInfo.new(0.15), { Size = UDim2.new(0, 320, 0, 0) }):Play()
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
local timers = {} -- jobId -> {phase, samples, seenAt, playing, max}
local cache_fetched_at = 0
local fail_streak = 0
local persist_backend = "memory"
local auto_enabled = false
local auto_status = "idle"

local function has_files()
	return (writefile and readfile and isfile) and true or false
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
local function build_payload(serverLimit, timerLimit)
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
		})
	end
	table.sort(tlist, function(a, b)
		return (a.samples or 0) > (b.samples or 0)
	end)
	if timerLimit then
		while #tlist > timerLimit do
			table.remove(tlist)
		end
	end

	return {
		placeId = game.PlaceId,
		savedAt = os.time(),
		servers = servers,
		visited = visited_order,
		timers = tlist,
		auto = auto_enabled,
		lead = min_lead,
		window = hop_window,
	}
end

local last_save = 0
local function persist_save(force)
	if not force and (tick() - last_save) < 2 then
		return
	end
	last_save = tick()

	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(build_payload())
	end)
	if not ok then
		return
	end

	if has_files() then
		pcall(writefile, PERSIST_FILE, encoded)
	end
	pcall(function()
		TeleportService:SetTeleportSetting(PERSIST_KEY, encoded)
	end)
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

	persist_save()
end

local function prune_timers()
	local t = now_secs()
	for id, e in pairs(timers) do
		if (t - (e.seenAt or 0)) > TIMER_TTL then
			timers[id] = nil
		end
	end
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

-- all candidates above the lead floor, soonest first
local function timer_candidates()
	local t = now_secs()
	local list = {}
	for id, e in pairs(timers) do
		if id ~= game.JobId and e.phase then
			table.insert(list, { id = id, remaining = remaining_at(e.phase, t) })
		end
	end
	table.sort(list, function(a, b)
		return a.remaining < b.remaining
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
		print(("[%s] %s"):format(os.date("%H:%M:%S"), hint.Text))
	end

	handle()
	hint:GetPropertyChangedSignal("Text"):Connect(handle)
	library:Notify("Timer source hooked", "ok")
end

task.spawn(watch_hint)

--==============================================================
--  SERVER CACHE
--==============================================================
local function update_cache_label()
	local age = (cache_fetched_at > 0) and math.max(0, os.time() - cache_fetched_at) or 0
	cacheLabel.Text = string.format(
		"cache %d · pool %d · %ds · %s · %s",
		#server_cache,
		timer_count(),
		age,
		persist_backend,
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

-- an entry we have never sampled a timer for
local function take_unsampled()
	for i, s in ipairs(server_cache) do
		if s.id ~= game.JobId and not timers[s.id] then
			table.remove(server_cache, i)
			persist_save()
			update_cache_label()
			return s
		end
	end
	return nil
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
	auto_enabled = saved.auto == true
	sliderLead.render()
	sliderWindow.render()

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
			}
			restoredTimers += 1
		end
	end

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

local function set_busy(state, joinText, smartText, smallestText, hopText)
	busy = state
	btnJoin.Text = joinText or "Join Server"
	btnSmart.Text = smartText or "Hop to Ending Soonest"
	btnSmallest.Text = smallestText or "Smallest"
	btnHop.Text = hopText or "Random Hop"
end

local function attempt_join(jobId, timeoutSecs)
	timeoutSecs = timeoutSecs or 20
	teleport_failed, teleport_fail_reason = false, ""

	mark_visited(game.JobId)
	persist_save(true)

	local tpData = { jobjoiner = build_payload(TP_DATA_MAX, TP_TIMER_MAX) }

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
		warn(string.format("[TELEPORT FAILED] Could not join server: %s", teleport_fail_reason))
		return false, teleport_fail_reason
	end

	print("[TELEPORT] Join appears successful, waiting for transition...")
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

local function set_auto_status(s)
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
		local ok = fetch_cache()
		if ok then
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

local function auto_loop()
	-- let the hint report at least once so this server gets sampled
	local t0 = tick()
	while auto_enabled and not live_remaining and (tick() - t0) < 8 do
		set_auto_status("sampling")
		task.wait(0.2)
	end

	while auto_enabled do
		if busy then
			task.wait(0.3)
		end

		prune_timers()

		-- if our own timer is about to fire, stay for the event
		local mine = my_remaining()
		if mine and mine <= (min_lead + hop_window) and mine > EVENT_EPSILON then
			set_auto_status(string.format("wait %.0fs", mine))
			task.wait(0.25)
			continue
		end

		local targetId, targetR = best_in_window()

		if targetId then
			set_auto_status(string.format("hop %.0fs", targetR))
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
					library:Notify("Teleport rate limited — auto paused 15s", "warn", 6)
					set_auto_status("cooldown")
					local t1 = tick()
					while auto_enabled and (tick() - t1) < 15 do
						task.wait(0.3)
					end
				end
			end
		else
			-- nothing worth hopping to: use the dead time to grow the pool
			set_auto_status("explore")
			local s = pick_explore_target()
			if not s then
				library:Notify("No new servers to explore — auto idling", "warn", 5)
				set_auto_status("idle")
				local t1 = tick()
				while auto_enabled and (tick() - t1) < 10 do
					task.wait(0.3)
				end
			else
				busy = true
				box.Text = s.id
				local ok, reason = attempt_join(s.id, 12)
				busy = false
				if ok then
					task.wait(5)
				elseif reason:lower():find("flood") then
					library:Notify("Teleport rate limited — auto paused 15s", "warn", 6)
					set_auto_status("cooldown")
					local t1 = tick()
					while auto_enabled and (tick() - t1) < 15 do
						task.wait(0.3)
					end
				end
			end
		end

		task.wait(0.3)
	end

	set_auto_status("idle")
	render_auto_button()
end

local function toggle_auto(force)
	auto_enabled = (force ~= nil) and force or not auto_enabled
	persist_save(true)
	render_auto_button()

	if auto_enabled then
		library:Notify(string.format("Auto ON — lead %ds, window +%ds", min_lead, hop_window), "ok")
		task.spawn(auto_loop)
	else
		library:Notify("Auto OFF", "warn")
	end
end

--==============================================================
--  SERVERS LIST RENDER
--==============================================================
local rows = {}

local function make_row(id)
	local row = new("TextButton", {
		Size = UDim2.new(1, -6, 0, 34),
		BackgroundColor3 = T.panel,
		AutoButtonColor = false,
		Text = "",
		Parent = scroll,
	})
	corner(6, row)

	local isCurrent = (id == game.JobId)

	local nameLbl = new("TextLabel", {
		Position = UDim2.new(0, 10, 0, 5),
		Size = UDim2.new(1, -80, 0, 12),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		TextSize = 10,
		TextColor3 = isCurrent and T.accent or T.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = id:sub(1, 12) .. (isCurrent and "  (you)" or ""),
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
		box.Text = id
		if id == game.JobId then
			library:Notify("You are already in this server", "warn")
		else
			task.spawn(join_game_by_id, id)
		end
	end)

	return { frame = row, name = nameLbl, meta = metaLbl, time = timeLbl }
end

local function render_servers()
	prune_timers()
	local t = now_secs()
	local seen, count, usable = {}, 0, 0

	for id, e in pairs(timers) do
		seen[id] = true
		count += 1
		local r = remaining_at(e.phase, t)

		local row = rows[id]
		if not row then
			row = make_row(id)
			rows[id] = row
		end

		row.time.Text = string.format("%.1fs", r)
		local inWindow = (r >= min_lead and r <= min_lead + hop_window)
		if inWindow then
			usable += 1
		end

		if id == game.JobId then
			row.time.TextColor3 = T.accent
		elseif inWindow then
			row.time.TextColor3 = T.ok
		elseif r >= min_lead then
			row.time.TextColor3 = T.warn
		else
			row.time.TextColor3 = T.err
		end

		local players = (e.playing and e.max) and string.format("%d/%d · ", e.playing, e.max) or ""
		row.meta.Text = string.format(
			"%s%d sample%s · seen %ds ago",
			players,
			e.samples or 0,
			(e.samples == 1) and "" or "s",
			math.floor(t - (e.seenAt or t))
		)

		row.frame.LayoutOrder = math.floor(r * 100)
	end

	for id, row in pairs(rows) do
		if not seen[id] then
			row.frame:Destroy()
			rows[id] = nil
		end
	end

	tabServers.Text = string.format("Servers (%d)", count)
	if count == 0 then
		serversHeader.Text = "DISCOVERED — waiting for first reading"
	else
		serversHeader.Text =
			string.format("%d known · %d in window [%d–%ds]", count, usable, min_lead, min_lead + hop_window)
	end
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
	while gui.Parent do
		update_cache_label()

		local jid = game.JobId ~= "" and game.JobId:sub(1, 18) or "studio"
		local mine = my_remaining()
		if mine then
			current.Text = string.format("current: %s\ntimer: %.1fs", jid, mine)
		else
			current.Text = "current: " .. jid
		end

		if pages.Servers.Visible then
			render_servers()
		end
		task.wait(0.2)
	end
end)

--==============================================================
--  BOOT
--==============================================================
do
	local qot = (syn and syn.queue_on_teleport) or queue_on_teleport
	if qot and SCRIPT_URL then
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

	if auto_enabled then
		library:Notify("Auto resumed after teleport", "ok")
		task.spawn(auto_loop)
	end
end
