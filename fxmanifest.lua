fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

author 'Sovereign'
name 'sovereign_banking'
description 'Sovereign Bank — central financial authority for the Sovereign suite'
version '0.6.0'
lua54 'yes'

shared_scripts {
  'config/config.lua',
  'config/locations.lua',
  'shared/constants.lua',
  'shared/util.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/logging.lua',
  'bridge/vorp.lua',
  'server/db.lua',
  'server/engine/ledger.lua',
  'server/engine/money.lua',
  'server/modules/accounts.lua',
  'server/modules/branches.lua',
  'server/modules/society.lua',
  'server/modules/billing.lua',
  'server/modules/savings.lua',
  'server/modules/loans.lua',
  'server/modules/sdb.lua',
  'server/modules/gold.lua',
  'server/modules/heist.lua',
  'server/modules/business.lua',
  'server/modules/collections.lua',
  'server/modules/seizure.lua',
  'server/admin.lua',
  'server/api/callbacks.lua',
  'server/api/exports.lua',
  'server/api/events.lua',
  'server/api/compat.lua',
  'server/scheduler.lua',
  'server/main.lua',
  'server/test.lua', -- dev-only: console command `banking_test` (tech spec §14)
}

client_scripts {
  'bridge/vorp.lua',
  'client/nui.lua',
  'client/main.lua',
  'client/teller.lua',
  'client/admin.lua',
}

ui_page 'web/index.html'

files {
  'web/index.html',
  'web/style.css',
  'web/app.js',
}

dependencies {
  'vorp_core',
  'oxmysql',
}
