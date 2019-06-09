local contents_match_regex = "^([^\n]*)(\n?)(.*)$"

local n = ...
assert(n, "no filename specified")

local f = assert(io.open(n, "rb"))

local s = f:read("*a")
assert(s, "file error reading")
local pre, nl, extra = s:match(contents_match_regex)
print(#pre, pre)
print(#nl)
print(#extra, extra)

