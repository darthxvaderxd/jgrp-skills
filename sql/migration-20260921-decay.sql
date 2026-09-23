-- jgrp-skills: skill decay (2026-09-21)
--
-- Adds `player_skills`.`last_xp` -- unix seconds of the last XP gain for that
-- character and skill -- and stamps every existing row with the moment you run
-- this.
--
-- **You do not have to run this.** `ensureSchema()` in server/main.lua does
-- exactly the same thing on resource start, guarded the same way. This file is
-- here because SQL on this server goes in through the panel by convention, and
-- because running it yourself means you choose the moment everybody's decay
-- clock starts rather than it being whenever the resource next restarts.
--
-- **THE BACKFILL IS THE POINT.** Every row predates the column. Left NULL and
-- read as "never", every character would look like they had not touched a
-- skill since 1970 and would decay to the floor the first time they logged in.
-- Stamping them with now starts everyone fresh, which is the only fair reading
-- of "we did not used to track this". The runtime is belt and braces on top:
-- a NULL is read as now, never as the epoch.
--
-- Safe to run twice: the column add is guarded on information_schema, because
-- `ADD COLUMN IF NOT EXISTS` is MariaDB-only and throws on MySQL 8.
--
-- Nothing here deletes or rewrites XP. The only UPDATE touches `last_xp`, and
-- only where it is NULL.

-- --------------------------------------------------------------------------
-- 1. the column, only if it is not already there
-- --------------------------------------------------------------------------
SET @col := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'player_skills'
      AND COLUMN_NAME  = 'last_xp'
);

SET @sql := IF(@col = 0,
    'ALTER TABLE `player_skills` ADD COLUMN `last_xp` INT NULL',
    'SELECT "jgrp-skills: last_xp already present, nothing to add" AS note'
);

PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- --------------------------------------------------------------------------
-- 2. start everybody's clock now
-- --------------------------------------------------------------------------
UPDATE `player_skills`
   SET `last_xp` = UNIX_TIMESTAMP()
 WHERE `last_xp` IS NULL;

-- --------------------------------------------------------------------------
-- 3. what you should see
-- --------------------------------------------------------------------------
SELECT COUNT(*)                                   AS rows_total,
       SUM(`last_xp` IS NULL)                     AS rows_still_null,
       FROM_UNIXTIME(MIN(`last_xp`))              AS earliest_clock,
       FROM_UNIXTIME(MAX(`last_xp`))              AS latest_clock
  FROM `player_skills`;

-- rows_still_null must be 0. If it is not, the UPDATE did not run and turning
-- Config.Decay.Enabled on would decay those characters to the floor.
