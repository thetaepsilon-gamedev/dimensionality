local lockdir_open = ...
assert(type(lockdir_open) == "function")

local errp = function(path)
	return "protocol violation in file " .. path .. ": " 
end



-- open an instance name stored in a text file and validate it was written correctly.
local contents_match_regex = "^([^\n]*)(\n?)(.*)$"
local open_instance_name_file = function(name)
	-- the standalone non-jit lua interpreter's io.open does support a 3rd errno return value,
	-- however luajit doesn't support this so we have to fall back to string match hacks...
	local f, msg = lockdir_open(name, "rb")

	if msg then
		if msg:find("No such file or directory") then
			return false
		else
			-- hard I/O error such as permission issue,
			-- probably configuration or otherwise needs admin attention,
			-- so stop the presses.
			error(msg)
		end
	end

	-- this is probably an I/O error if this fails,
	-- there's *definitely* nothing we can do about that.
	local str = assert(f:read("*a"))

	local pre, nl, extra = str:match(contents_match_regex)

	-- should only be one line.
	-- if this is to the contrary,
	-- someone has written this file that doesn't understand the protocol.
	-- in this case, all bets and assumptions are off, so stop the presses.
	if (#extra > 0) then
		error(errp(name_path) .. "spurious extra lines.")
	end

	if (#nl > 0) then
		-- if the newline is present but the name isn't,
		-- someone is mucking us around again.
		if (#pre == 0) then
			error(errp(name_path) .. "empty line.")
		else
			-- otherwise it's fine - we expect the newline here.
			return pre
		end
	else
		-- if the newline is not present (line empty or not),
		-- we take it as a non-atomic write being observed,
		-- and consider it a transient error.
		return nil, "newline character not present in " .. path .. ", is the file half written?"
	end
end





-- now we get to the actual constructor.
--[[
README - caveats about the files provider:
1) this can potentially get quite cluttered indeed with a lot of players.
2) multiple servers under *different* users or roles from an OS point of view are probably a no-go.
	this is because files made by one account may not be removable by another on all OSes.
	you will likely run into hard error crashes in that case.
]]
local files_provider = function(current_instance_name, log)
	local ILockProvider = {}
	ILockProvider.check = function(playername)
		local r, msg = open_instance_name_file(playername)
		if r == false then return false end
		if not r then
			log(msg)
		end
		return r
	end
	ILockProvider.put = function(playername, owner)
		local f = assert(lockdir_open(playername, "w+b"))
		f:write(owner)
		f:write("\n")
		f:close()
	end

	return ILockProvider
end



player_world_lock_register_backend("files", files_provider)



