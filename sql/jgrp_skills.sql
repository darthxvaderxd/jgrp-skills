CREATE TABLE IF NOT EXISTS `player_skills` (
    `citizenid` VARCHAR(50) NOT NULL,
    `skill` VARCHAR(50) NOT NULL,
    `level` INT NOT NULL DEFAULT 0,
    `xp` INT NOT NULL DEFAULT 0,
    -- Unix seconds of the last XP gain, for Config.Decay. NULL is read as
    -- "now" at runtime, never as the epoch -- see ensureSchema().
    `last_xp` INT NULL,
    PRIMARY KEY (`citizenid`, `skill`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
