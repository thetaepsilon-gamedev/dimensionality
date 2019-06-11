--[[
player_world_lock backend plugin that uses files in a shared directory on the same host.
WARNING: this requires an insecure environment.
The code below has been written as straightforwardly as possible to aid inspection.
]]

-- before doing anything privileged, check we have a directory to use for locks.
-- this one is read from minetest.conf to allow easy common sharing on singleplayer setups.
local key = "player_world_lock.backend.files.lockdir"
local lockdir = minetest.settings:get(key)
if (lockdir == nil) or (lockdir == "") then
	error(key .. " was blank or not set.")
end





-- PRIVILEGED SECTION START --
-- Get insecure env table...
local env = assert(
	minetest.request_insecure_environment(),
	"Insecure environment disabled by mod security. "..
	"This mod requires unsandboxed io.open to access files in a shared location outside the world dir.")

-- Retrieve just the function we need,
-- then throw away the rest of the environment so the rest of the code becomes POLA
-- (principle of least authority - can't abuse other powers we don't have!)
local super_open = env.io.open
env = nil

-- Next, we further restrict ourselves (POLA again further applied)
-- so we can only read/write something in the configured directory.
-- The below function only accepts paths in the base64 set 0-9a-zA-Z_-
-- (like the main player_world_lock mod does):
-- on all sane operating systems this cannot possibly result in a subdirectory.
-- However, there's only so much MT lets us check;
-- if an external program makes a symlink in the lock directory to somewhere outside,
-- we have *no way* of detecting it, so be warned.
-- (we here have no means of creating them either so this should not normally happen...)

local safe_regex = "^[0-9a-zA-Z_%-]*$"	-- yes, I know they're not real regexes. fight meh.
local n = "lockdir_open(): "
local msg_unsafe_name = n .. "passed name contained a character outside the base64 safe set."
local msg_mode = n .. "open mode must be explicit."

-- A scope trick to let us hold onto the super_open function *within this function only*.
-- The player files are named playername.txt, and their contents is the current owner.
-- This function ensures we can only open files inside the lock directory for this purpose.
local mk_lockdir_open = function(inner_open)
	return function(name, mode)
		-- ensure name is safe - this should be the case most of the time,
		-- however if there is a bug elsewhere we must apply defense in depth.
		assert(name:match(safe_regex) ~= nil, msg_unsafe_name)

		-- don't accept a default mode here.
		-- we must be clear what we're doing outside the sandbox.
		assert(mode, msg_mode)

		local filename = lockdir .. "/" .. name .. ".txt"
		return inner_open(filename, mode)
	end
end

-- Create the restricted open function here,
-- then again throw away the unrestricted super_open from above;
-- we should have no need to open files besides inside the lock dir outside the sandbox.
local lockdir_open = mk_lockdir_open(super_open)
super_open = nil
mk_lockdir_open = nil	-- don't need this either now
-- PRIVILEGED SECTION END --





-- now we have successfully "dropped privileges" so we only have the powers we need,
-- we may run the non-security-critical parts of the mod.
local path = minetest.get_modpath(minetest.get_current_modname()) .. "/unprivileged.lua"
-- loadfile dance done here to allow passing in arguments to the compiled chunk...
local f = assert(loadfile(path))
return f(lockdir_open)



