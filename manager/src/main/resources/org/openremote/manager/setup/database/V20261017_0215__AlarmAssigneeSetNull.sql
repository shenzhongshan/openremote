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

-- ALARM.ASSIGNEE_ID referenced USER_ENTITY with ON DELETE CASCADE, so deleting a user deleted the
-- alarms assigned to them, and the ALARM_ASSET_LINK rows cascading off those alarms with them.
-- Nothing in the delete path (UserResourceImpl -> ManagerKeycloakIdentityProvider.deleteUser)
-- clears the assignee first, so offboarding a user silently discarded their assigned alarm history.
-- ASSIGNEE_ID is nullable, so unassigning on user delete keeps the alarm and drops only the
-- assignment.

ALTER TABLE ${schemaName}.ALARM
    DROP CONSTRAINT IF EXISTS ALARM_ASSIGNEE_ID_FKEY;

ALTER TABLE ${schemaName}.ALARM
    ADD CONSTRAINT ALARM_ASSIGNEE_ID_FKEY FOREIGN KEY (ASSIGNEE_ID)
        REFERENCES PUBLIC.USER_ENTITY (ID) ON DELETE SET NULL;
