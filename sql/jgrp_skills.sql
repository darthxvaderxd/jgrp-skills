CREATE TABLE IF NOT EXISTS `player_skills` (
    `citizenid` VARCHAR(50) NOT NULL,
    `skill` VARCHAR(50) NOT NULL,
    `level` INT NOT NULL DEFAULT 0,
    `xp` INT NOT NULL DEFAULT 0,
    PRIMARY KEY (`citizenid`, `skill`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
