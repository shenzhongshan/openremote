/*
 * Copyright 2026, OpenRemote Inc.
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
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
package org.openremote.test.notification

import org.openremote.container.persistence.PersistenceService
import org.openremote.manager.notification.NotificationService
import org.openremote.manager.setup.SetupService
import org.openremote.model.notification.EmailNotificationMessage
import org.openremote.model.notification.Notification
import org.openremote.model.notification.SentNotification
import org.openremote.setup.integration.KeycloakTestSetup
import org.openremote.test.ManagerContainerTrait
import spock.lang.Specification

import java.time.Instant
import java.time.temporal.ChronoUnit

import static org.openremote.manager.notification.NotificationService.OR_NOTIFICATION_MAX_AGE_DAYS

class NotificationPurgeTest extends Specification implements ManagerContainerTrait {

  def "Notifications sent before the retention cutoff are purged"() {

    given: "the container is started with a 30-day notification retention period"
    def config = defaultConfig()
    config.put(OR_NOTIFICATION_MAX_AGE_DAYS, "30")
    def container = startContainer(config, defaultServices())
    def keycloakTestSetup = container.getService(SetupService.class).getTaskOfType(KeycloakTestSetup.class)
    def notificationService = container.getService(NotificationService.class)
    def persistenceService = container.getService(PersistenceService.class)
    def realm = keycloakTestSetup.realmMaster.name

    and: "the clock is stopped so the cutoff cannot move mid-test"
    stopPseudoClock()

    and: "the cutoff is derived the same way the purge derives it"
    // Expressing the fixtures relative to the cutoff rather than in whole days keeps the boundary
    // cases exact regardless of the time of day the test happens to run at
    def cutoff = Instant.ofEpochMilli(getClockTimeOf(container))
            .truncatedTo(ChronoUnit.DAYS)
            .minus(30, ChronoUnit.DAYS)

    and: "notifications exist on both sides of the cutoff, and exactly on it"
    def wellBeforeId = insertNotification(persistenceService, realm, cutoff.minus(335, ChronoUnit.DAYS), "a year old")
    def justBeforeId = insertNotification(persistenceService, realm, cutoff.minusSeconds(1), "one second before the cutoff")
    def onCutoffId = insertNotification(persistenceService, realm, cutoff, "exactly on the cutoff")
    def justAfterId = insertNotification(persistenceService, realm, cutoff.plusSeconds(1), "one second after the cutoff")
    def recentId = insertNotification(persistenceService, realm, Instant.ofEpochMilli(getClockTimeOf(container)), "sent just now")

    expect: "all of them to be stored"
    [wellBeforeId, justBeforeId, onCutoffId, justAfterId, recentId].every { exists(persistenceService, it) }

    when: "the purge runs"
    notificationService.purgeNotifications()

    then: "notifications sent before the cutoff are gone"
    !exists(persistenceService, wellBeforeId)
    !exists(persistenceService, justBeforeId)

    and: "a notification sent exactly on the cutoff is kept, because the purge compares strictly"
    exists(persistenceService, onCutoffId)

    and: "notifications sent after the cutoff are kept"
    exists(persistenceService, justAfterId)
    exists(persistenceService, recentId)

    when: "the purge runs again with nothing left to remove"
    notificationService.purgeNotifications()

    then: "the surviving notifications are untouched"
    exists(persistenceService, onCutoffId)
    exists(persistenceService, justAfterId)
    exists(persistenceService, recentId)

    cleanup: "the notifications created by this test are removed"
    if (persistenceService != null) {
      [onCutoffId, justAfterId, recentId].findAll { it != null }.each { delete(persistenceService, it) }
    }
  }

  def "Notification purging is disabled unless a retention period is configured"() {

    given: "the container is started without a notification retention period"
    def container = startContainer(defaultConfig(), defaultServices())
    def keycloakTestSetup = container.getService(SetupService.class).getTaskOfType(KeycloakTestSetup.class)
    def notificationService = container.getService(NotificationService.class)
    def persistenceService = container.getService(PersistenceService.class)
    def realm = keycloakTestSetup.realmMaster.name

    and: "the clock is stopped"
    stopPseudoClock()

    expect: "retention to be off"
    notificationService.maxAgeDays <= 0

    when: "a very old notification exists"
    def oldId = insertNotification(persistenceService, realm,
            Instant.ofEpochMilli(getClockTimeOf(container)).minus(3650, ChronoUnit.DAYS), "ten years old")

    then: "it is stored"
    exists(persistenceService, oldId)

    when: "the purge is invoked anyway"
    // A negative retention would otherwise put the cutoff in the future and delete everything,
    // so the purge has to no-op rather than trust its caller
    notificationService.purgeNotifications()

    then: "nothing is deleted"
    exists(persistenceService, oldId)

    cleanup: "the notification created by this test is removed"
    if (persistenceService != null && oldId != null) {
      delete(persistenceService, oldId)
    }
  }

  private static Long insertNotification(PersistenceService persistenceService, String realm, Instant sentOn, String name) {
    return persistenceService.doReturningTransaction { em ->
      def notification = new SentNotification()
              .setName(name)
              .setType(EmailNotificationMessage.TYPE)
              .setTarget(Notification.TargetType.REALM)
              .setTargetId(realm)
              .setSource(Notification.Source.INTERNAL)
              .setRealm(realm)
              .setMessage(new EmailNotificationMessage().setSubject(name))
              .setSentOn(sentOn)
      em.persist(notification)
      return notification.id
    }
  }

  private static boolean exists(PersistenceService persistenceService, Long id) {
    return persistenceService.doReturningTransaction { em ->
      em.find(SentNotification.class, id) != null
    }
  }

  private static void delete(PersistenceService persistenceService, Long id) {
    persistenceService.doTransaction { em ->
      em.createQuery("delete from SentNotification n where n.id = :id")
              .setParameter("id", id)
              .executeUpdate()
    }
  }
}
