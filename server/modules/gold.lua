--[[
  server/modules/gold.lua — the assayer's counter (design §5.6).

  Buy/sell gold ↔ dollars at a configured rate with a spread: the bank sells
  gold at rate×(1+spread) and buys it at rate×(1−spread). Exchange is
  wallet↔wallet (physical coin across the counter, period-appropriate) as a
  two-phase pair of wallet ops with compensation.

  Amounts are gold minor units (gold × 100), price is money-minor per 1.00
  gold. Physical gold-bar item redemption is a later addition (needs the
  stores/economy item contract — tech spec §16.2).
]]

Gold = {}

local Err = Constants.Err

--- Current quotes in money-minor per 1.00 gold: what the player pays to buy,
--- what the player receives selling.
function Gold.quote()
  local rate = tonumber(Config.Gold and Config.Gold.pricePerGold) or 2000
  local spread = tonumber(Config.Fees.goldExchangeSpread) or 0.05
  return {
    buy = math.floor(rate * (1 + spread) + 0.5),
    sell = math.floor(rate * (1 - spread) + 0.5),
  }
end

local function moneyFor(goldMinor, pricePerGold)
  return math.floor(goldMinor * pricePerGold / 100 + 0.5)
end

--- Exchange at the counter. direction: 'buy' (dollars→gold) or 'sell'
--- (gold→dollars). goldMinor is the gold amount in minor units.
--- Returns (true, {gold, money, direction}) or (false, errCode).
function Gold.exchange(charid, direction, goldMinor, meta)
  meta = meta or {}
  if not (Config.Gold and Config.Gold.enabled) then return false, Err.CURRENCY_DISABLED end
  if not Config.Currencies.gold then return false, Err.CURRENCY_DISABLED end
  charid = tostring(charid)
  goldMinor = tonumber(goldMinor)
  if not Util.isValidAmount(goldMinor) then return false, Err.BAD_AMOUNT end

  local q = Gold.quote()
  local source = meta.source or 'sov_bank'

  if direction == 'buy' then
    local cost = moneyFor(goldMinor, q.buy)
    if cost <= 0 then return false, Err.BAD_AMOUNT end
    local memo = ('Bought %.2f gold'):format(goldMinor / 100)
    local ok, res = Money.walletDebit(charid, Constants.Currency.MONEY, cost,
      { category = Constants.Category.GOLD_EXCHANGE, memo = memo, source = source, silent = true })
    if not ok then return false, res end
    local ok2, res2 = Money.walletCredit(charid, Constants.Currency.GOLD, goldMinor,
      { category = Constants.Category.GOLD_EXCHANGE, memo = memo, source = source, silent = true })
    if not ok2 then
      Money.walletCredit(charid, Constants.Currency.MONEY, cost, {
        category = Constants.Category.COMPENSATION, source = 'sov_bank',
        memo = ('reversal: %s'):format(memo), silent = true,
      })
      return false, res2
    end
    return true, { direction = 'buy', gold = goldMinor, money = cost }
  end

  if direction == 'sell' then
    local proceeds = moneyFor(goldMinor, q.sell)
    if proceeds <= 0 then return false, Err.BAD_AMOUNT end
    local memo = ('Sold %.2f gold'):format(goldMinor / 100)
    local ok, res = Money.walletDebit(charid, Constants.Currency.GOLD, goldMinor,
      { category = Constants.Category.GOLD_EXCHANGE, memo = memo, source = source, silent = true })
    if not ok then return false, res end
    local ok2, res2 = Money.walletCredit(charid, Constants.Currency.MONEY, proceeds,
      { category = Constants.Category.GOLD_EXCHANGE, memo = memo, source = source, silent = true })
    if not ok2 then
      Money.walletCredit(charid, Constants.Currency.GOLD, goldMinor, {
        category = Constants.Category.COMPENSATION, source = 'sov_bank',
        memo = ('reversal: %s'):format(memo), silent = true,
      })
      return false, res2
    end
    return true, { direction = 'sell', gold = goldMinor, money = proceeds }
  end

  return false, Err.BAD_KIND
end
