require("util")
require("config")

local json = require("json")
local deflate = require "zlib-deflate"
local base64 = require "base64"
require("datastring")
------------------------------------------------------------
--[[Method that handle creation and deletion of entities]]--
------------------------------------------------------------
function OnBuiltEntity(event)
	local entity = event.created_entity
	if not (entity and entity.valid) then return end
	if entity.name == "entity-ghost" then return end
	AddEntity(entity)
end

function AddAllEntitiesOfNames(names)
	local filters = {}
	for i = 1, #names do
		local name = names[i]
		filters[#filters + 1] = {name = name}
	end
	for k, surface in pairs(game.surfaces) do
		AddEntities(surface.find_entities_filtered(filters))
	end
end

function AddEntities(entities)
	for k, entity in pairs(entities) do
		AddEntity(entity)
	end
end

function AddEntity(entity)
	if entity.name == TX_COMBINATOR_NAME then
		global.txControls[entity.unit_number] = entity.get_or_create_control_behavior()
	elseif entity.name == RX_COMBINATOR_NAME then
		global.rxControls[entity.unit_number] = entity.get_or_create_control_behavior()
		entity.operable=false
  elseif entity.name == ID_COMBINATOR_NAME then
		local control = entity.get_or_create_control_behavior()
    control.parameters = { parameters = {
      {index = 1, count = global.worldID or -1, signal = {type = "virtual", name = "signal-localid"}}
    }}

		entity.operable=false
	end
end

function OnKilledEntity(event)
	local entity = event.entity
	if entity.type ~= "entity-ghost" then
		--remove the entities from the tables as they are dead
		if entity.name == TX_COMBINATOR_NAME then
			global.txControls[entity.unit_number] = nil
		elseif entity.name == RX_COMBINATOR_NAME then
			global.rxControls[entity.unit_number] = nil
		end
	end
end


-----------------------------
--[[Thing creation events]]--
-----------------------------
script.on_event(defines.events.on_built_entity, function(event)
	OnBuiltEntity(event)
end)

script.on_event(defines.events.on_robot_built_entity, function(event)
	OnBuiltEntity(event)
end)


----------------------------
--[[Thing killing events]]--
----------------------------
script.on_event(defines.events.on_entity_died, function(event)
	OnKilledEntity(event)
end)

script.on_event(defines.events.on_robot_pre_mined, function(event)
	OnKilledEntity(event)
end)

script.on_event(defines.events.on_pre_player_mined_item, function(event)
	OnKilledEntity(event)
end)


------------------------------
--[[Thing resetting events]]--
------------------------------
script.on_init(function()
	Reset()
end)

script.on_configuration_changed(function(data)
	if data.mod_changes and data.mod_changes["routablecombinators"] then
		Reset()
	end
end)

function Reset()
	-- Maps for signalid <> Signal
	global.id_to_signal_map={}
	global.signal_to_id_map={virtual={},fluid={},item={}}
	for _,v in pairs(game.virtual_signal_prototypes) do
		global.id_to_signal_map[#global.id_to_signal_map+1]={id=#global.id_to_signal_map+1, name=v.name, type="virtual"}
		global.signal_to_id_map.virtual[v.name]=#global.id_to_signal_map
	end
	for _,f in pairs(game.fluid_prototypes) do
		global.id_to_signal_map[#global.id_to_signal_map+1]={id=#global.id_to_signal_map+1, name=f.name, type="fluid"}
		global.signal_to_id_map.fluid[f.name]=#global.id_to_signal_map
	end
	for _,i in pairs(game.item_prototypes) do
		global.id_to_signal_map[#global.id_to_signal_map+1]={id=#global.id_to_signal_map+1, name=i.name, type="item"}
		global.signal_to_id_map.item[i.name]=#global.id_to_signal_map
	end
	global.rxControls = {}
	global.rxBuffer = {}
	global.txControls = {}
	global.txSignals = {}
  global.oldTXSignals = nil

	AddAllEntitiesOfNames(
	{
		RX_COMBINATOR_NAME,
		TX_COMBINATOR_NAME,
    ID_COMBINATOR_NAME,
	})
end

script.on_event(defines.events.on_tick, function(event)
	-- TX Combinators must run every tick to catch single pulses
	HandleTXCombinators()

	-- RX Combinators are set and then cleared on sequential ticks to create pulses
	UpdateRXCombinators()
end)

---------------------------------
--[[Update combinator methods]]--
---------------------------------
function AddFrameToRXBuffer(frame)
	--game.print("RXb"..game.tick..":"..serpent.block(frame))

	-- if buffer is full, drop frame
	if #global.rxBuffer >= MAX_RX_BUFFER_SIZE then return 0 end

	table.insert(global.rxBuffer,frame)

	return MAX_RX_BUFFER_SIZE - #global.rxBuffer
end

function HandleTXCombinators()
	-- Check all TX Combinators, and if condition satisfied, add frame to transmit buffer

	--[[
	txsignals = {
		dstid = int or nil
		srcid = int or nil
		data = {
			[signalid]=value,
			[signalid]=value,
			...
		}
	}
	--]]
	local hassignals = false
	local txsignals = {
		srcid=global.worldID,
		data={}
	}
	for i,txControl in pairs(global.txControls) do
		if txControl.valid then
			-- frame = {{count=42,signal={name="signal-grey",type="virtual"}},{...},...}
			local frame = txControl.signals_last_tick
			if frame then
				for _,signal in pairs(frame) do
					local signalName = signal.signal.name
					if signalName == "signal-srcid"  or  signalName == "signal-srctick" then
						-- skip these two, to enforce correct values.
					elseif signalName == "signal-dstid" then
						-- dstid has a special field to go in (this is mostly to make unicast easier on the js side)
						--game.print("TX"..game.tick..":".."dstid"..signal.count)
						txsignals.dstid = (txsignals.dstid or 0) + signal.count
					else
						local sigid = global.signal_to_id_map[signal.signal.type][signalName]
						txsignals.data[sigid] = (txsignals.data[sigid] or 0) + signal.count
						hassignals = true
					end
				end
			end
		end
	end

	if hassignals then

		--Don't send the exact same signals in a row
		-- have to clear tick from old frame and compare before adding to new or it'll always differ
		local sigtick = global.signal_to_id_map["virtual"]["signal-srctick"]
		if global.oldTXSignals and AreTablesSame(global.oldTXSignals, txsignals) then
			global.oldTXSignals = txsignals
			return
		else
			global.oldTXSignals = txsignals



			txsignals.data[sigtick] = game.tick

			--game.print("TX"..game.tick..":"..serpent.block(txsignals))
			local outstr = WriteFrame(txsignals)
      local size = WriteVarInt(#outstr)
      outstr = size .. outstr


      -- If the buffer is full, discard the oldest frame to prevent this table growing too large
      if #global.txSignals >= MAX_TX_BUFFER_SIZE then
        table.remove(global.txSignals,1)
      end
			global.txSignals[#global.txSignals + 1] = outstr

			-- Loopback for testing
			--AddFrameToRXBuffer(outstr)
		end
	end
end

function AreTablesSame(tableA, tableB)
	if tableA == nil and tableB ~= nil then
		return false
	elseif tableA ~= nil and tableB == nil then
		return false
	elseif tableA == nil and tableB == nil then
		return true
	end

	if TableWithKeysLength(tableA) ~= TableWithKeysLength(tableB) then
		return false
	end

	for keyA, valueA in pairs(tableA) do
		local valueB = tableB[keyA]
		if type(valueA) == "table" and type(valueB) == "table" then
			if not AreTablesSame(valueA, valueB) then
				return false
			end
		elseif type(valueA) ~= type(valueB) then
			return false
		elseif valueA ~= valueB then
			return false
		end
	end

	return true
end

function TableWithKeysLength(tableA)
	local count = 0
	for k, v in pairs(tableA) do
		count = count + 1
	end
	return count
end

function UpdateRXCombinators()
	-- if the RX buffer is not empty, get a frame from it and output on all RX Combinators
	if #global.rxBuffer > 0 then
		local frame = ReadFrame(table.remove(global.rxBuffer))
		--log("RX:"..serpent.block(frame))

		for i,rxControl in pairs(global.rxControls) do
			if rxControl.valid then
				rxControl.parameters = {parameters = frame }
				rxControl.enabled = true
			end
		end
  else
    -- no frames to send right now, blank all...
    for i,rxControl in pairs(global.rxControls) do
  		if rxControl.valid then
			rxControl.parameters = {parameters = {}}
  			rxControl.enabled = false
  		end
  	end
	end
end

---------------------
--[[Remote things]]--
---------------------
commands.add_command("RoutingGetID","",function(cmd)
  if not global.worldID or global.worldID == 0 then
    -- if no ID, pick one at random...
    global.worldID = math.random(1,2147483647)
  end
  if cmd.player_index and cmd.player_index > 0 then
    game.players[cmd.player_index].print(global.worldID)
  elseif rcon then
    rcon.print(global.worldID)
  end
end)

commands.add_command("RoutingSetID","",function(cmd)
  global.worldID = tonumber(cmd.parameter)

  if global.worldID > 0x7fffffff then
    global.worldID = global.worldID - 0x100000000
  end

  AddAllEntitiesOfNames{ID_COMBINATOR_NAME}

end)

commands.add_command("RoutingRX","",function(cmd)
  -- frame in cmd.parameter
  --log("RX: ".. serpent.line(cmd.parameter))
  AddFrameToRXBuffer(cmd.parameter)
end)

commands.add_command("RoutingTXBuff","",function(cmd)
  if cmd.player_index and cmd.player_index > 0 then
    game.players[cmd.player_index].print("TX Buffer has ".. #global.txSignals .. " frames")
  else
    -- put as many as fit in 4000 bytes...
    if #global.txSignals > 0 then

      local outstr = {}
      local outsize = 0
      local s = table.remove(global.txSignals,1)
      outstr[#outstr+1] = s
      outsize = #s
      while outsize < 4000 and #global.txSignals > 0 do
        s = table.remove(global.txSignals,1)
        outstr[#outstr+1] = s
        outsize = outsize + #s
        first = global.txSignals[1]
      end

      -- concat them all and print all in one go, one loooong series of non-zero bytes...
      rcon.print(table.concat(outstr))
    end
  end
end)

local sigmapdata = nil

commands.add_command("RoutingGetMap","",function(cmd)
  if not sigmapdata then
    -- return maps for use by external tools
		-- id_to_signal is sparse int indexes (js will use stringy numbers), signal_to_id is map["type"]["name"] -> id
    local data = json:encode(global.id_to_signal_map)
    data = deflate.gzip(data)
    data = base64.enc(data)

    --split data to 4000 byte chunks and stash in sigmapdata.
    sigmapdata = {}
    while #data > 4000 do
      sigmapdata[#sigmapdata +1] = data:sub(1,4000)
      data = data:sub(4001)
    end

    sigmapdata[#sigmapdata +1] = data
  end

  -- return the requested segment...
  rcon.print(sigmapdata[tonumber(cmd.parameter) or 1])

end)

commands.add_command("RoutingReset","", Reset)


remote.add_interface("routablecombinators",
{
	runcode=function(codeToRun) loadstring(codeToRun)() end,
	reset = Reset,
})
