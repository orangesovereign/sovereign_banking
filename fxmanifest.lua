fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

author 'Sovereign'
description 'Sovereign Bank — central financial authority for the Sovereign suite'
version '0.2.0'
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
  'server/api/callbacks.lua',
  'server/api/exports.lua',
  'server/api/events.lua',
  'server/main.lua',
}

client_scripts {
  'bridge/vorp.lua',
  'client/nui.lua',
  'client/main.lua',
  'client/teller.lua',
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
