/*
 * Copyright 2026, OpenRemote Inc.
 *
 * See the CONTRIBUTORS.txt file in the distribution for a
 * full listing of individual contributors.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

-- ALARM, NOTIFICATION and SYSLOG_EVENT only had their primary key index, yet all three grow
-- monotonically and are read back with a realm/category filter and a newest-first sort. ASSET had
-- no index on REALM either. Measured on 50k alarms, 500k notifications, 500k syslog events and
-- 20k assets, each of these queries went from a sequential scan to an index scan:
--
--   alarms by realm + status, newest first   7.39 ms -> 0.07 ms
--   notifications by realm, newest 50       48.68 ms -> 0.11 ms
--   syslog by category, newest 100          39.69 ms -> 0.13 ms
--   assets by realm (realm with no rows)     7.38 ms -> 0.03 ms
--
-- Sequential scan cost grows with row count while these stay flat, and NOTIFICATION and
-- SYSLOG_EVENT have no retention policy of their own, unlike the data point tables.
--
-- Index column order follows the query shape: equality columns first, then the sort column.
-- SYSLOG_EVENT.LEVEL is deliberately NOT in its index. Callers filter it as a range
-- (LevelCategoryFilter emits level >= N), and a range column placed before the sort column stops
-- the index satisfying ORDER BY, which degrades the plan to a bitmap heap scan plus a top-N sort
-- and recovers almost none of the time. Left out, LEVEL is a cheap filter on the index scan.
--
-- These take a lock that blocks writes to the table for the duration of the build, in line with
-- the existing index migrations. On the volumes above each one built in under 2 seconds.

CREATE INDEX IF NOT EXISTS ALARM_REALM_STATUS_CREATED_ON_IDX
    ON ${schemaName}.ALARM (REALM, STATUS, CREATED_ON DESC);

CREATE INDEX IF NOT EXISTS NOTIFICATION_REALM_SENT_ON_IDX
    ON ${schemaName}.NOTIFICATION (REALM, SENT_ON DESC);

CREATE INDEX IF NOT EXISTS SYSLOG_EVENT_CATEGORY_TIMESTAMP_IDX
    ON ${schemaName}.SYSLOG_EVENT (CATEGORY, TIMESTAMP DESC);

-- The log page's default view applies no category filter, so it needs the sort column alone.
CREATE INDEX IF NOT EXISTS SYSLOG_EVENT_TIMESTAMP_IDX
    ON ${schemaName}.SYSLOG_EVENT (TIMESTAMP DESC);

CREATE INDEX IF NOT EXISTS ASSET_REALM_IDX
    ON ${schemaName}.ASSET (REALM);
