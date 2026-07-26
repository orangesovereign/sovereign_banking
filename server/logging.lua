--[[
  server/logging.lua — leveled console logging + Discord audit mirroring
  (tech spec §12).

  Discord posts are BATCHED: entries queue per category and flush on a timer
  as a single embed-list request, so a payroll run or a busy teller can't
  trip Discord's rate limiter. A failed webhook never affects the money
  operation that produced it — logging is strictly downstream of the ledger.
]]

Log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local COLORS = { debug = '^6', info = '^2', warn = '^3', error = '^1' }

local function write(level, fmt, ...)
  local threshold = LEVELS[Config.LogLevel or 'info'] or 2
  if LEVELS[level] < threshold then return end
  local ok, msg = pcall(string.format, fmt, ...)
  print(('%s[sovereign_banking:%s]^7 %s'):format(COLORS[level], level, ok and msg or tostring(fmt)))
end

function Log.debug(fmt, ...) write('debug', fmt, ...) end
function Log.info(fmt, ...)  write('info', fmt, ...) end
function Log.warn(fmt, ...)  write('warn', fmt, ...) end
function Log.error(fmt, ...) write('error', fmt, ...) end

-- ============================================================================
-- Discord
-- ============================================================================

local queues = {}          -- category -> { embed, ... }
local COLOR = {
  tx = 3447003, loans = 15105570, admin = 10181046, heist = 15158332,
}

--- Queue an audit entry. fields = { {name=, value=, inline=}, ... }.
--- Never throws and never blocks the caller.
function Log.discord(category, title, description, fields)
  if not (Config.Discord and Config.Discord.enabled) then return end
  local hook = (Config.Discord.webhooks or {})[category]
  if not hook or hook == '' then return end

  local q = queues[category]
  if not q then
    q = {}
    queues[category] = q
  end
  if #q >= 50 then return end -- backpressure: drop rather than balloon

  q[#q + 1] = {
    title = tostring(title),
    description = description and tostring(description) or nil,
    color = COLOR[category] or 8421504,
    fields = fields,
    footer = { text = ('Sovereign Bank · %s'):format(os.date('%Y-%m-%d %H:%M:%S')) },
  }
end

local function flush(category)
  local q = queues[category]
  if not q or #q == 0 then return end
  local hook = (Config.Discord.webhooks or {})[category]
  if not hook or hook == '' then
    queues[category] = nil
    return
  end

  -- Discord accepts at most 10 embeds per message.
  local batch = {}
  for _ = 1, math.min(10, #q) do
    batch[#batch + 1] = table.remove(q, 1)
  end

  pcall(function()
    PerformHttpRequest(hook, function(status)
      if status ~= 200 and status ~= 204 then
        Log.warn('discord webhook (%s) returned %s', category, tostring(status))
      end
    end, 'POST', json.encode({ username = 'Sovereign Bank', embeds = batch }),
      { ['Content-Type'] = 'application/json' })
  end)
end

CreateThread(function()
  while true do
    Wait(math.max(2, tonumber(Config.Discord and Config.Discord.flushSeconds) or 10) * 1000)
    if Config.Discord and Config.Discord.enabled then
      for category in pairs(queues) do
        pcall(flush, category)
      end
    end
  end
end)
