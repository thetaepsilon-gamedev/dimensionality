-- a mod that looks for player locks in the world dir or some other locking provider.
-- in the dir case, player locks exist in a subdirectory
-- (unimaginatively called player_locks)
-- and are plain text files naming a server instance.
-- when players connect, if a lock file is present,
-- it is opened and read to see if the named instance matches the current one
-- (the "current" instance name is set in a file in the world dir);
-- if it does not match, the player is assumed "locked" by another server instance,
-- and they are promptly disconnected.

-- TODO:
-- optionally, in the event of disconnect,
-- there can be a conf file (in the form of minetest.conf)
-- which maps the above server instance names into more friendly descriptions.
-- this can be used to e.g. indicate the server they should be connecting to by hostname/IP etc.



local mn = "player_world_lock"
local wp = minetest.get_worldpath()

local mne = mn .. ": "
local warn = function(...)
	return minetest.log("warning", ...)
end



--[[
interface ILockProvider:
check(string playername): gets the instance name that "owns" this player.
	if the owner is not the current instance, players get disconnected.
	returns:
		string owner - on success, report the owning instance.
		false - if *no instance* owns the player currently.
			behaviour in this case depends on world configuration.
		nil - if an error occurs. implementation is expected to log warnings.
			in this event the player is still disconnected.
			using nil is preferred to exceptions,
			to allow transient errors to not bring the server down.
			configuration errors should where possible be raised at construct time.

put(string playername, string owner) - sets the owner to the named instance.
	this is used to transport a player to another dimension;
	afterwards they will typically be promptly disconnected and told to hop servers.
	this function may return false to indicate transient failures,
	however in general it is only called by this mod when the current instance already owns the player,
	so it should not fail for other reasons;
	any hard faults should be thrown errors.

note that player names are always restricted to the URL-safe base64 set,
namely (0-9a-zA-Z_-) to ensure they can safely be used in URLs
(e.g. a HTTP API like /check/$playername) and file names (see below provider).
]]
local safe_regex = "^[0-9a-zA-Z_%-]*$"	-- see above comment
local safe_regex_display = "0-9, a-z, A-Z, _ and -"
local is_safe_identifier = function(s)
	return s:match(safe_regex) ~= nil
end

-- no providers here - for various reasons,
-- they need to be in other mods (potentially trusted ones).
local known_providers = {
}
local lpre = "[player_world_lock] "
local n = "player_world_lock_register_backend(): "
local msg_dup = n .. "duplicate lock provider registration for "
local msg_name = n .. "argument exception: name was not a string, got "
local msg_constructor = n .. "argument exception: constructor was not a function, got "
local desc = function(v)
	return "(type " .. type(v) .. ") " .. tostring(v)
end
-- /global/ --
player_world_lock_register_backend = function(name, constructor)
	if type(name) ~= "string" then
		error(msg_name .. desc(name))
	end
	if known_providers[name] then
		error(msg_dup .. name)
	end
	if type(constructor) ~= "function" then
		error(msg_constructor  .. desc(constructor))
	end

	known_providers[name] = constructor
end




-- main logic.
-- first load settings from world dir.
local path = wp.."/player_world_lock.json"
local settings_file = assert(io.open(path))
local settings_json = assert(settings_file:read("*a"))
local settings = minetest.parse_json(settings_json)
local t = type(settings)
if t ~= "table" then
	error(path .. " contained invalid JSON or failed to parse. expected table, got " .. t)
end

local assert_key = function(k, t)
	local v = settings[k]
	local ta = type(v)
	if ta ~= t then
		error(
			"setting key " .. k .. " from " .. path ..
			" expected to be " .. t .. ", got " .. ta)
	end
	return v
end

local current_instance_name = assert_key("instance_name", "string")
assert(
	is_safe_identifier(current_instance_name),
	"current instance name in config file was not safe. " .. 
	"use URL-encoding base64 chars only, e.g. the characters " ..
	safe_regex_display)

local provider_name = assert_key("lock_provider", "string")

-- this setting controls whether to allow claiming the lock when nobody else does.
-- WARNING! as at least the files backend can't arbitrate theoretical race conditions,
-- *this should only be set on one server in the dimension group!*
-- that server should be the "overworld" dimension or otherwise where new players should start.
-- note that if *no* server has this set, players cannot join anywhere until the lock is manually set.
-- setting defaults to false if not specified; when false, unclaimed players cannot join.
local is_lock_master = settings.is_lock_master
local t = type(is_lock_master)
if (t ~= "nil") and (t ~= "boolean") then
	error("setting key is_lock_master from " .. path ..
		" expected to be optional boolean, got " .. t)
end
if (t == "nil") then is_lock_master = false end





-- configuration complete.
-- now, as lock provider mods run *after* this mod for dependency reasons,
-- we must run this in on_mods_loaded.
local ILockProvider
minetest.register_on_mods_loaded(function()
	local constructor = known_providers[provider_name]
	if not constructor then
		error("unknown lock_provider value from " .. path .. ": " .. provider_name)
	end

	local wpre = "[player_world_lock][lock_provider:"..provider_name.."] "
	local log = function(msg)
		minetest.log("warning", wpre .. tostring(msg))
	end
	ILockProvider = constructor(current_instance_name, log)
	minetest.log("action", "[player_world_lock] provider configured: " .. provider_name)
end)




-- TODO: load friendly names file?
local friendly_names = nil

local get_friendly_name = function(instance_name)
	local friendly
	if friendly_names ~= nil then
		friendly = friendly_names[instance_name]
	end
	return friendly or instance_name
end




-- now we're all set up; install the intercept to kick out locked players.
local transient =
	"There was a temporary problem checking your player's world lock. Please try again later."
local funny_name =
	"Sorry, but your username is not currently supported for world locks. " ..
	"Please ensure your name belongs to the safe character set, e.g. " .. safe_regex_display

local locked_out = function(actual_owner)
	local description = get_friendly_name(actual_owner)
	return "You have not connected to the correct dimensional server. " ..
		"Please connect to this server instead: " .. description
end

local handle_unclaimed = function(name)
	if not is_lock_master then
		-- TODO - this should probably be more descriptive.
		return "You have not connected to the starting server in this group yet!"
	else
		ILockProvider.put(name, current_instance_name)
	end
end






minetest.register_on_prejoinplayer(function(name, ip)
	if not is_safe_identifier(name) then
		return funny_name
	end

	local owner = ILockProvider.check(name)
	--print(owner)
	--print(current_instance_name)
	if owner == nil then
		minetest.log("warning",
			lpre .. "transient failure in lock provider \"" ..
			provider_name .. "\" handling player " .. name)
		return transient
	elseif owner == false then
		-- behaviour here depends on is_lock_master setting.
		minetest.log("info", lpre .. "handling unclaimed player " .. name)
		return handle_unclaimed(name)
	elseif type(owner) == "string" then
		if owner ~= current_instance_name then
			return locked_out(owner)
		end
	else
		-- returned something else!? probably a bug
		error("ILockProvider.check() contract error.")
	end
end)







-- expose the ability to transfer player ownership to another instance and then kick them.
local n = "player_world_lock_transfer_and_kick(): argument exception: "
local transfer_and_kick_player_inner = function(player_handle, new_owner)
	local name = player_handle:get_player_name()
	ILockProvider.put(name, new_owner)
	local desc = get_friendly_name(new_owner)
	minetest.kick_player(
		name,
		"You are being transferred to another server. " ..
		"Please connect to: " .. desc)
end

-- /global/ --
player_world_lock_transfer_and_kick = function(player_handle, new_owner)
	-- be careful here - this has to be a *real* player,
	-- not something merely posing as one.
	for _, ref in ipairs(minetest.get_connected_players()) do
		if ref == player_handle then
			-- we must also verify the provided owner.
			local t = type(new_owner)
			if t ~= "string" then
				error(n .. "new_owner expected to be a string, got " .. t)
			end
			if not is_safe_identifier(new_owner) then
				error(n .. "new_owner contained unsafe characters: " .. new_owner)
			end
			return transfer_and_kick_player_inner(ref, new_owner)
		end
	end
	error(n .. "object " .. tostring(player_handle) .. " was not a real player!")
end





