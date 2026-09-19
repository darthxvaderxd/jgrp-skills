fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'jgrp-skills'
description 'Skill / XP framework for qb-core'
author 'jgrp'
version '1.0.0'

shared_script 'config.lua'

-- oxmysql's library has to be imported here, not just declared a dependency:
-- without it the MySQL global is nil and every query errors.
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

client_script 'client/main.lua'

dependencies {
    'qb-core',
    'oxmysql',
}
