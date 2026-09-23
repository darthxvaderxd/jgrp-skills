fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'jgrp-skills'
description 'Skill / XP framework for qb-core'
author 'jgrp'
version '1.0.0'

shared_script 'config.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

client_script 'client/main.lua'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

dependencies {
    'qb-core',
    'oxmysql',
}
