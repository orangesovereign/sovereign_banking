--[[
  server/logging.lua — leveled console logging (tech spec §12).
  Discord webhook mirroring lands in Phase 4; Log.discord is a stub until then.
]]

Log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local COLORS = { debug = '^6', info = '^2', warn = '^3', error = '^1' }

local function write(level, fmt, ...)
  local threshold = LEVELS[Config.LogLevel or 'info'] or 2
  if LEVELS[level] < threshold then return end
  local ok, msg = pcall(string.format, fmt, ...)
  print(('%s[sov_bank:%s]^7 %s'):format(COLORS[level], level, ok and msg or tostring(fmt)))
end

function Log.debug(fmt, ...) write('debug', fmt, ...) end
function Log.info(fmt, ...)  write('info', fmt, ...) end
function Log.warn(fmt, ...)  write('warn', fmt, ...) end
function Log.error(fmt, ...) write('error', fmt, ...) end

--- Phase 4: batch and push to Config.Discord.webhooks[category].
function Log.discord(category, payload) -- luacheck: ignore
end
