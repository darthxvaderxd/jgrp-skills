fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'jgrp-skills'
description 'Skill / XP framework for qb-core'
author 'jgrp'
version '1.0.0'

shared_script 'config.lua'

server_script 'server/main.lua'

client_script 'client/main.lua'

dependencies {
    'qb-core',
    'oxmysql',
}
