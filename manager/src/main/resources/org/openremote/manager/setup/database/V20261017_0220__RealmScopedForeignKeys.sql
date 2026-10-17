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

-- DASHBOARD, ALARM and NOTIFICATION are realm scoped but had neither a REALM foreign key nor any
-- cleanup in ManagerKeycloakIdentityProvider.deleteRealm, so deleting a realm left their rows
-- behind. Because every realm-scoped query filters on the realm NAME, re-creating a realm with the
-- same name surfaced the previous tenant's rows to the new one: alarms and notifications in full,
-- and dashboards whose access is PUBLIC or SHARED.
--
-- deleteRealm now deletes these three alongside the tables it already handled. These constraints
-- are the backstop for a realm removed out of band, e.g. straight from the Keycloak admin console.
--
-- ON DELETE CASCADE matches the existing REALM foreign keys on USER_ASSET_LINK and
-- ALARM_ASSET_LINK. ASSET deliberately keeps RESTRICT instead: deleteRealm refuses to remove a
-- realm that still holds assets, and assets must never disappear implicitly.
--
-- Added NOT VALID on purpose. Existing rows are left untouched, so an upgrade cannot delete data
-- that is already there, while any new realm deletion is cascaded correctly. The referential
-- action is installed on PUBLIC.REALM and fires regardless of validation state, so the leak is
-- closed for every realm deleted from now on.
--
-- Rows orphaned BEFORE this migration are not removed here and stay reachable if their realm name
-- is reused. Clean them up deliberately, then validate the constraints:
--
--   DELETE FROM <schema>.DASHBOARD    d WHERE d.REALM IS NOT NULL
--     AND NOT EXISTS (SELECT 1 FROM PUBLIC.REALM r WHERE r.NAME = d.REALM);
--   DELETE FROM <schema>.ALARM        a WHERE a.REALM IS NOT NULL
--     AND NOT EXISTS (SELECT 1 FROM PUBLIC.REALM r WHERE r.NAME = a.REALM);
--   DELETE FROM <schema>.NOTIFICATION n WHERE n.REALM IS NOT NULL
--     AND NOT EXISTS (SELECT 1 FROM PUBLIC.REALM r WHERE r.NAME = n.REALM);
--   ALTER TABLE <schema>.DASHBOARD    VALIDATE CONSTRAINT DASHBOARD_REALM_FKEY;
--   ALTER TABLE <schema>.ALARM        VALIDATE CONSTRAINT ALARM_REALM_FKEY;
--   ALTER TABLE <schema>.NOTIFICATION VALIDATE CONSTRAINT NOTIFICATION_REALM_FKEY;
--
-- Count them first with:
--
--   SELECT 'dashboard' AS t, count(*) FROM <schema>.DASHBOARD d
--     WHERE d.REALM IS NOT NULL AND NOT EXISTS (SELECT 1 FROM PUBLIC.REALM r WHERE r.NAME = d.REALM)
--   UNION ALL SELECT 'alarm', count(*) FROM <schema>.ALARM a
--     WHERE a.REALM IS NOT NULL AND NOT EXISTS (SELECT 1 FROM PUBLIC.REALM r WHERE r.NAME = a.REALM)
--   UNION ALL SELECT 'notification', count(*) FROM <schema>.NOTIFICATION n
--     WHERE n.REALM IS NOT NULL AND NOT EXISTS (SELECT 1 FROM PUBLIC.REALM r WHERE r.NAME = n.REALM);

ALTER TABLE ${schemaName}.DASHBOARD
    DROP CONSTRAINT IF EXISTS DASHBOARD_REALM_FKEY;
ALTER TABLE ${schemaName}.DASHBOARD
    ADD CONSTRAINT DASHBOARD_REALM_FKEY FOREIGN KEY (REALM)
        REFERENCES PUBLIC.REALM (NAME) ON DELETE CASCADE NOT VALID;

ALTER TABLE ${schemaName}.ALARM
    DROP CONSTRAINT IF EXISTS ALARM_REALM_FKEY;
ALTER TABLE ${schemaName}.ALARM
    ADD CONSTRAINT ALARM_REALM_FKEY FOREIGN KEY (REALM)
        REFERENCES PUBLIC.REALM (NAME) ON DELETE CASCADE NOT VALID;

ALTER TABLE ${schemaName}.NOTIFICATION
    DROP CONSTRAINT IF EXISTS NOTIFICATION_REALM_FKEY;
ALTER TABLE ${schemaName}.NOTIFICATION
    ADD CONSTRAINT NOTIFICATION_REALM_FKEY FOREIGN KEY (REALM)
        REFERENCES PUBLIC.REALM (NAME) ON DELETE CASCADE NOT VALID;

-- GATEWAY_CONNECTION.LOCAL_REALM is a local realm and deleteRealm already clears it; the backstop
-- is added for the same out-of-band case. GATEWAY_CONNECTION.REALM names a realm on the CENTRAL
-- manager, which does not exist in this database, so it must never get a foreign key.
ALTER TABLE ${schemaName}.GATEWAY_CONNECTION
    DROP CONSTRAINT IF EXISTS GATEWAY_CONNECTION_LOCAL_REALM_FKEY;
ALTER TABLE ${schemaName}.GATEWAY_CONNECTION
    ADD CONSTRAINT GATEWAY_CONNECTION_LOCAL_REALM_FKEY FOREIGN KEY (LOCAL_REALM)
        REFERENCES PUBLIC.REALM (NAME) ON DELETE CASCADE NOT VALID;
