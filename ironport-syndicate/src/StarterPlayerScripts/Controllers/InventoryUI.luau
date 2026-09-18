--!strict
-- Inventory panel: what you're carrying, what it weighs, and what's in your
-- vehicle when you're standing next to it.
--
-- Built in code rather than as a stored GUI so it stays in source control and
-- reviewable — there are no .rbxm assets in this repo by design.
--
-- Styling follows the GDD's noir palette: near-black panels, brass accents,
-- warm highlight only on the thing that matters (the weight bar as it fills).
-- Everything is read-only here; every mutation goes through a remote and is
-- re-validated server-side.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local InventoryConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local inventoryRemotes = remotes:WaitForChild("InventoryRemotes")
local cargoRemotes = remotes:WaitForChild("CargoRemotes")
local inventoryStateRemote = inventoryRemotes:WaitForChild("InventoryStateRemote") :: RemoteEvent
local dropItemRemote = inventoryRemotes:WaitForChild("DropItemRemote") :: RemoteFunction
local cargoStateRemote = cargoRemotes:WaitForChild("VehicleCargoStateRemote") :: RemoteEvent
local storeInVehicleRemote = cargoRemotes:WaitForChild("StoreInVehicleRemote") :: RemoteFunction
local takeFromVehicleRemote = cargoRemotes:WaitForChild("TakeFromVehicleRemote") :: RemoteFunction

local TOGGLE_ACTION = "IronportToggleInventory"

local INK = Color3.fromRGB(18, 17, 15)
local PANEL = Color3.fromRGB(28, 26, 22)
local ROW = Color3.fromRGB(38, 35, 30)
local LINE = Color3.fromRGB(62, 56, 45)
local TEXT = Color3.fromRGB(236, 229, 214)
local TEXT_DIM = Color3.fromRGB(150, 141, 126)
local BRASS = Color3.fromRGB(198, 150, 74)
local DANGER = Color3.fromRGB(176, 78, 66)

local InventoryUI = {}

local items: { [string]: number } = {}
local carriedWeight = 0
local capacity = InventoryConfig.BaseCarryWeight
local cargoContents: { [string]: number } = {}
local cargoWeight = 0
local cargoCapacity = InventoryConfig.VehicleCargoCapacity
local vehicleInReach = false

local function addRounded(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addStroke(parent: Instance, color: Color3)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 1
	stroke.Parent = parent
end

--[[ Structure ]]

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "InventoryUI"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "Root"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.fromScale(0.5, 0.5)
root.Size = UDim2.fromOffset(720, 460)
root.BackgroundColor3 = INK
root.BorderSizePixel = 0
root.Parent = screenGui
addRounded(root, 6)
addStroke(root, LINE)

-- Phone width: stack to a single column and fill more of the screen.
local sizeConstraint = Instance.new("UISizeConstraint")
sizeConstraint.MaxSize = Vector2.new(720, 460)
sizeConstraint.Parent = root

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 56)
header.BackgroundTransparency = 1
header.Parent = root

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -140, 1, 0)
title.Position = UDim2.fromOffset(20, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.TextColor3 = TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "CARRIED"
title.Parent = header

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0.5)
closeButton.Position = UDim2.new(1, -16, 0.5, 0)
closeButton.Size = UDim2.fromOffset(32, 32)
closeButton.BackgroundColor3 = ROW
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 16
closeButton.TextColor3 = TEXT_DIM
closeButton.Text = "X"
closeButton.AutoButtonColor = true
closeButton.Parent = header
addRounded(closeButton, 4)

--[[ Weight bar ]]

local weightRow = Instance.new("Frame")
weightRow.Name = "WeightRow"
weightRow.Position = UDim2.fromOffset(20, 52)
weightRow.Size = UDim2.new(1, -40, 0, 42)
weightRow.BackgroundTransparency = 1
weightRow.Parent = root

local weightLabel = Instance.new("TextLabel")
weightLabel.Size = UDim2.new(1, 0, 0, 16)
weightLabel.BackgroundTransparency = 1
weightLabel.Font = Enum.Font.Code
weightLabel.TextSize = 13
weightLabel.TextColor3 = TEXT_DIM
weightLabel.TextXAlignment = Enum.TextXAlignment.Left
weightLabel.Text = "0 / 250 LB"
weightLabel.Parent = weightRow

local barBack = Instance.new("Frame")
barBack.Position = UDim2.fromOffset(0, 22)
barBack.Size = UDim2.new(1, 0, 0, 8)
barBack.BackgroundColor3 = ROW
barBack.BorderSizePixel = 0
barBack.Parent = weightRow
addRounded(barBack, 4)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = BRASS
barFill.BorderSizePixel = 0
barFill.Parent = barBack
addRounded(barFill, 4)

--[[ Columns ]]

local columns = Instance.new("Frame")
columns.Name = "Columns"
columns.Position = UDim2.fromOffset(20, 108)
columns.Size = UDim2.new(1, -40, 1, -128)
columns.BackgroundTransparency = 1
columns.Parent = root

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 12)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = columns

local function buildColumn(name: string, order: number, heading: string): (Frame, ScrollingFrame, TextLabel)
	local column = Instance.new("Frame")
	column.Name = name
	column.LayoutOrder = order
	column.Size = UDim2.new(0.5, -6, 1, 0)
	column.BackgroundColor3 = PANEL
	column.BorderSizePixel = 0
	column.Parent = columns
	addRounded(column, 5)
	addStroke(column, LINE)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -24, 0, 30)
	label.Position = UDim2.fromOffset(12, 6)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextColor3 = BRASS
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = heading
	label.Parent = column

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(8, 38)
	scroll.Size = UDim2.new(1, -16, 1, -46)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = LINE
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = column

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 4)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = scroll

	return column, scroll, label
end

local _, carriedScroll = buildColumn("Carried", 1, "ON PERSON")
local cargoColumn, cargoScroll, cargoHeading = buildColumn("Cargo", 2, "VEHICLE")

--[[ Rows ]]

local function buildRow(
	parent: ScrollingFrame,
	itemId: string,
	count: number,
	actionText: string,
	actionColor: Color3,
	onAction: () -> ()
)
	local definition = InventoryConfig.Items[itemId]
	if not definition then
		return
	end

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundColor3 = ROW
	row.BorderSizePixel = 0
	row.Parent = parent
	addRounded(row, 4)

	local name = Instance.new("TextLabel")
	name.Position = UDim2.fromOffset(10, 6)
	name.Size = UDim2.new(1, -90, 0, 18)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.Gotham
	name.TextSize = 13
	name.TextColor3 = TEXT
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = if count > 1 then ("%s  x%d"):format(definition.DisplayName, count) else definition.DisplayName
	name.Parent = row

	local weight = Instance.new("TextLabel")
	weight.Position = UDim2.fromOffset(10, 23)
	weight.Size = UDim2.new(1, -90, 0, 14)
	weight.BackgroundTransparency = 1
	weight.Font = Enum.Font.Code
	weight.TextSize = 11
	weight.TextColor3 = TEXT_DIM
	weight.TextXAlignment = Enum.TextXAlignment.Left
	weight.Text = ("%d LB  ·  %s"):format(definition.Weight * count, definition.Category)
	weight.Parent = row

	local action = Instance.new("TextButton")
	action.AnchorPoint = Vector2.new(1, 0.5)
	action.Position = UDim2.new(1, -8, 0.5, 0)
	action.Size = UDim2.fromOffset(64, 26)
	action.BackgroundColor3 = INK
	action.BorderSizePixel = 0
	action.Font = Enum.Font.GothamMedium
	action.TextSize = 11
	action.TextColor3 = actionColor
	action.Text = actionText
	action.Parent = row
	addRounded(action, 4)
	addStroke(action, LINE)

	action.Activated:Connect(onAction)
end

local function isEmpty(map: { [string]: number }): boolean
	for _ in map do
		return false
	end
	return true
end

local function buildEmptyNotice(parent: ScrollingFrame, text: string)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 40)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.TextSize = 12
	label.TextColor3 = TEXT_DIM
	label.TextWrapped = true
	label.Text = text
	label.Parent = parent
end

--[[ Rendering ]]

local function clear(scroll: ScrollingFrame)
	for _, child in scroll:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function render()
	weightLabel.Text = ("%d / %d LB"):format(carriedWeight, capacity)

	local ratio = if capacity > 0 then math.clamp(carriedWeight / capacity, 0, 1) else 0
	TweenService:Create(barFill, TweenInfo.new(0.2), { Size = UDim2.fromScale(ratio, 1) }):Play()
	barFill.BackgroundColor3 = if ratio >= 1 then DANGER else BRASS

	clear(carriedScroll)
	if isEmpty(items) then
		buildEmptyNotice(carriedScroll, "Carrying nothing.")
	else
		for itemId, count in items do
			buildRow(carriedScroll, itemId, count, if vehicleInReach then "STOW" else "DROP", TEXT_DIM, function()
				if vehicleInReach then
					storeInVehicleRemote:InvokeServer(itemId, 1)
				else
					dropItemRemote:InvokeServer(itemId, 1)
				end
			end)
		end
	end

	cargoColumn.Visible = true
	if not vehicleInReach then
		cargoHeading.Text = "VEHICLE  ·  NOT IN REACH"
		clear(cargoScroll)
		buildEmptyNotice(cargoScroll, "Stand next to your vehicle to load or unload it.")
		return
	end

	cargoHeading.Text = ("VEHICLE  ·  %d / %d LB"):format(cargoWeight, cargoCapacity)
	clear(cargoScroll)
	if isEmpty(cargoContents) then
		buildEmptyNotice(cargoScroll, "Vehicle is empty.")
		return
	end
	for itemId, count in cargoContents do
		buildRow(cargoScroll, itemId, count, "TAKE", BRASS, function()
			takeFromVehicleRemote:InvokeServer(itemId, 1)
		end)
	end
end

--[[ Wiring ]]

inventoryStateRemote.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" or typeof(data.Items) ~= "table" then
		return
	end
	items = data.Items
	carriedWeight = data.CarriedWeight or 0
	capacity = data.Capacity or InventoryConfig.BaseCarryWeight
	if screenGui.Enabled then
		render()
	end
end)

cargoStateRemote.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then
		return
	end
	local wasInReach = vehicleInReach
	vehicleInReach = data.HasVehicle == true
	cargoContents = if typeof(data.Contents) == "table" then data.Contents else {}
	cargoWeight = data.Weight or 0
	cargoCapacity = data.Capacity or InventoryConfig.VehicleCargoCapacity
	if screenGui.Enabled and (wasInReach ~= vehicleInReach or vehicleInReach) then
		render()
	end
end)

function InventoryUI.setOpen(open: boolean)
	screenGui.Enabled = open
	if open then
		render()
	end
end

function InventoryUI.toggle()
	InventoryUI.setOpen(not screenGui.Enabled)
end

closeButton.Activated:Connect(function()
	InventoryUI.setOpen(false)
end)

-- Bound through ContextActionService so this also gets a touch button on mobile
-- and a gamepad binding, rather than being keyboard-only.
ContextActionService:BindAction(TOGGLE_ACTION, function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		InventoryUI.toggle()
	end
	return Enum.ContextActionResult.Pass
end, true, Enum.KeyCode.Tab, Enum.KeyCode.ButtonY)
ContextActionService:SetTitle(TOGGLE_ACTION, "Bag")

return InventoryUI
