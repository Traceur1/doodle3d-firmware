local M = {}

local logLevel, logVerbose, logStream

M.LEVEL = {"debug", "info", "warn", "error", "fatal"}

--M.LEVEL already has idx=>name entries, now create name=>idx entries
for i,v in ipairs(M.LEVEL) do
	M.LEVEL[v] = i
end

function M:init(level, verbose, stream)
	logLevel = level or M.LEVEL.warn
	logVerbose = verbose or false
	logStream = stream or io.stdout
end

local function log(level, msg, verbose)
	if level >= logLevel then
		local now = os.date("%m-%d %H:%M:%S")
		local i = debug.getinfo(3) --the stack frame just above the logger call
		local v = verbose
		if v == nil then v = logVerbose end
		local name = i.name or "(nil)"
		local vVal = "nil"
		local m = (type(msg) == "string") and msg or M:dump(msg)
		if v then logStream:write(now .. " (" .. M.LEVEL[level] .. ")  \t" .. m .. "  [" .. name .. "@" .. i.short_src .. ":" .. i.linedefined .. "]\n")
		else logStream:write(now .. " (" .. M.LEVEL[level] .. ")  \t" .. m .. "\n") end
	end
end

function M:dump(o)
	if type(o) == 'table' then
		local s = '{ '
		for k,v in pairs(o) do
			if type(k) ~= 'number' then k = '"'..k..'"' end
			s = s .. '['..k..'] = ' .. M:dump(v) .. ','
		end
		return s .. '} '
	else
		return tostring(o)
	end
end

function M:debug(msg, verbose) log(M.LEVEL.debug, msg, verbose); return true end
function M:info(msg, verbose) log(M.LEVEL.info, msg, verbose); return true end
function M:warn(msg, verbose) log(M.LEVEL.warn, msg, verbose); return true end
function M:error(msg, verbose) log(M.LEVEL.error, msg, verbose); return false end
function M:fatal(msg, verbose) log(M.LEVEL.fatal, msg, verbose); return false end

return M
