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

-- NotificationService's daily purge (OR_NOTIFICATION_MAX_AGE_DAYS) filters on SENT_ON alone.
-- NOTIFICATION_REALM_SENT_ON_IDX cannot serve it because REALM leads that index, so without this
-- one the purge scans the whole table every night. In steady state it deletes only the day that
-- fell out of the retention window, a small fraction of the rows, which is exactly the case an
-- index on the filtered column serves well.

CREATE INDEX IF NOT EXISTS NOTIFICATION_SENT_ON_IDX
    ON ${schemaName}.NOTIFICATION (SENT_ON);
