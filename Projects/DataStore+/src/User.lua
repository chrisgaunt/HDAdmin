-- LOCAL
local dataStoreService = game:GetService("DataStoreService")
local httpService = game:GetService("HttpService")
local players = game:GetService("Players")
local runService = game:GetService("RunService")
local teleportService = game:GetService("TeleportService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HDAdmin = replicatedStorage:WaitForChild("HDAdmin")
local Signal = require(HDAdmin:WaitForChild("Signal"))
local Maid = require(HDAdmin:WaitForChild("Maid"))
local TableModifiers = require(script.Parent.TableModifiers)
local User = {}
User.__index = User



-- CONSTRUCTOR
function User.new(dataStoreName, key)
	local self = {}
	setmetatable(self, User)
	
	-- Maid
	local maid = Maid.new()
	self._maid = maid
	
	-- Main
	self.temp = {}
	self.perm = {}
	self.backup = {}
	maid:give(TableModifiers.apply(self.temp))
	maid:give(TableModifiers.apply(self.perm))
	maid:give(TableModifiers.apply(self.backup))
	
	-- Config
	local currentTick = tick()
	self.onlySaveDataWhenChanged = true
	self.teleportPlayerAwayOnFail = false
	self.autoSave = true
	self.autoSaveInterval = 60
	self.maxRetries = 3
	self.cooldown = 8
	
	-- Setup information
	self.dataStoreName = dataStoreName
	self.dataStore = dataStoreName and key and dataStoreService:GetDataStore(dataStoreName)
	self.key = key
	self.sessionId = httpService:GenerateGUID(false)
	self.isNewUser = nil
	self.isLoaded = false
	self.loaded = maid:give(Signal.new())
	self.player = nil
	self.errorMessageBase = "DataStore+ | Failed to %s DataKey '".. tostring(key).."' ("..dataStoreName.."): "
	self.startData = {}
	
	-- AutoSave
	self._nextAutoSaveTick = currentTick
	if self.autoSave then
		self:initSaveLoop()
	end
	
	--BindToClose
	if not runService:IsStudio() then
		game:BindToClose(function()
		    self:saveAsync()
		end)
	end
	
	return self
end



-- METHODS
function User:loadAsync()
	local callType = "load"
	self.isLoaded = false
	
	-- Retrieve previous perm data 
	local permData = self:_protectedCall(callType, function(finalAttempt)
		return self.dataStore:GetAsync(self.key)
	end)
	
	-- Setup perm; if nothing found, apply start data
	if not permData then
		permData = self.startData
		self.isNewUser = true
	else
		self.isNewUser = false
	end
	for k,v in pairs(permData) do
		self.perm[k] = v
	end
	
	-- Find and trigger any backup data
	local backupData = permData._backupData
	if backupData then
		for name, content in pairs(backupData) do
			if type(content) == "table" then
				if #content > 0 then
					for i,v in pairs(content) do
						self.backup:insert(name, v)
					end
				else
					for k,v in pairs(content) do
						self.backup:pair(name, k, v)
					end
				end
			else
				local oldValue = permData[name]
				local oldValueNum = tonumber(oldValue)
				local newValueNum = tonumber(content)
				self.backup[name] = oldValue
				if oldValueNum and newValueNum then
					self.backup:increment(name, newValueNum-oldValueNum)
				else
					self.backup:set(name, content)
				end
			end
		end
		self.perm._backupData = nil
	end
	
	-- Complete
	self.isLoaded = true
	self.loaded:Fire()
	return self.perm
end

function User:saveAsync()
	local callType = "save"
	
	-- Return if nothing needs saving
	if self.perm._tableUpdated == false and self.backup._tableUpdated == false and self.onlySaveDataWhenChanged then
		return false
	end
	
	-- Cooldown to prevent two calls being made within 7 seconds
	self:_applyCooldown(callType)
	
	-- Save data
	local backupAction = false
	local success = self:_protectedCall(callType, function(finalAttempt)
		return self.dataStore:UpdateAsync(self.key, function(previousData)
			local previousData = previousData or self.perm
			if previousData._dataId == self.perm._dataId then
				-- DataIds match, generate new unique DataId
				self.perm._dataId = httpService:GenerateGUID()
				self.perm._tableUpdated = false
			elseif finalAttempt then
				-- DataIds do not match, all retries failed, force add backup data to previousData and proceed to backup action 
				warn(string.format("%sDataIds do not match, all retries failed. Saved backup data and and proceeding to backup action.", self.errorMessageBase:format(callType)))
				previousData._backupData = self.backup
				backupAction = true
				return previousData
			else
				-- DataIds do not match, abort save and retry
				warn(string.format("%sDataIds do not match, retrying save...", self.errorMessageBase:format(callType)))
				return nil
			end
			-- Success, return data to be saved
			return self.perm
		end)
	end)
	
	-- Clear backup data
	if success then
		self.backup:clear()
	end
	
	-- All retries failed, resort to backup action
	if backupAction then
		-- Teleport away (not recommended)
		if self.teleportPlayerAwayOnFail then
			local player = self.player
			if player then
				teleportService:Teleport(game.PlaceId, player)
				return "FinalAttempt: teleported away"
			end
		end
		-- Keep player in server and reload data so dataIDs match
		self:loadAsync()
		return "FinalAttempt: reloaded data"
	end
	
	-- Return
	return success
end

function User:removeAsync()
	local callType = "remove"
	
	-- Cooldown
	self:_applyCooldown(callType)
	
	-- Remove key
	self:_protectedCall(callType, function()
		self.dataStore:RemoveAsync(self.key)
	end)
end

function User:_applyCooldown(callType)
	local currentTick = tick()
	local requestName = "_nextRequest"..callType
	local nextRequest = self[requestName] or currentTick
	if currentTick < nextRequest then
		wait(nextRequest - currentTick)
	end
	self[requestName] = nextRequest + self.cooldown
end

function User:_protectedCall(callType, func)
	for i = 1, self.maxRetries do
		local finalAttempt = i == self.maxRetries
		local success, value = pcall(func, finalAttempt)
		if success and (value or callType == "load") then
			return value
		end
		wait(1)
	end
end



-- UTILITY METHODS
function User:setStartData(startData)
	if type(startData) ~= "table" then
		startData = {startData}
	end
	self.startData = startData
end

function User:initSaveLoop(autoSaveInterval)
	local loopId = self.sessionId
	self.autoSaveInterval = tonumber(autoSaveInterval) or self.autoSaveInterval
	if self.saveLoopInitialized then
		return false
	end
	self.saveLoopInitialized = true
	coroutine.wrap(function()
		while self.autoSave and loopId == self.sessionId do
			local currentTick = tick()
			if currentTick >= self._nextAutoSaveTick then
				self._nextAutoSaveTick = currentTick + self.autoSaveInterval
				self:saveAsync()
			end
			RunService.Heartbeat:Wait()
		end
		self.saveLoopInitialized = nil
	end)()
end

function User:waitUntilLoaded()
	local loaded = self.isLoaded or self.loaded:Wait()
end

function User:destroy()
	self.sessionId = nil
	self._maid:clean()
end



return User