import {
  cancelNotification,
  createNotificationDraft,
  legacyCreateBroadcast,
  notificationDetail,
  notificationOperationsWorkbench,
  previewNotification,
  sendNotification,
  updateNotificationDraft,
} from "./notification-ops-service.js";
import {
  appAnnouncementWorkbench,
  disableAppAnnouncement,
  publishAppAnnouncement,
  republishAppAnnouncement,
} from "./app-announcement-ops-service.js";

export async function adminNotificationRoutes(app) {
  app.get(
    "/admin/app-announcements",
    { preHandler: app.adminRequired },
    async (request) => appAnnouncementWorkbench(request.query || {}),
  );

  app.post(
    "/admin/app-announcements/publish",
    { preHandler: app.adminRequired },
    async (request) => publishAppAnnouncement(
      request.user.id,
      request.body || {},
    ),
  );

  app.post(
    "/admin/app-announcements/disable",
    { preHandler: app.adminRequired },
    async (request) => disableAppAnnouncement(
      request.user.id,
      request.body || {},
    ),
  );

  app.post(
    "/admin/app-announcements/:id/republish",
    { preHandler: app.adminRequired },
    async (request) => republishAppAnnouncement(
      request.user.id,
      request.params.id,
      request.body || {},
    ),
  );

  app.get(
    "/admin/notifications",
    { preHandler: app.adminRequired },
    async (request) => notificationOperationsWorkbench(request.query || {}),
  );

  app.get(
    "/admin/notifications/:id",
    { preHandler: app.adminRequired },
    async (request) => notificationDetail(request.params.id),
  );

  app.post(
    "/admin/notifications/preview",
    { preHandler: app.adminRequired },
    async (request) => previewNotification(request.body || {}),
  );

  app.post(
    "/admin/notifications",
    { preHandler: app.adminRequired },
    async (request) => createNotificationDraft(request.user.id, request.body || {}),
  );

  app.patch(
    "/admin/notifications/:id",
    { preHandler: app.adminRequired },
    async (request) => updateNotificationDraft(
      request.user.id,
      request.params.id,
      request.body || {},
    ),
  );

  app.post(
    "/admin/notifications/:id/send",
    { preHandler: app.adminRequired },
    async (request) => sendNotification(
      request.user.id,
      request.params.id,
      request.body || {},
    ),
  );

  app.post(
    "/admin/notifications/:id/cancel",
    { preHandler: app.adminRequired },
    async (request) => cancelNotification(
      request.user.id,
      request.params.id,
      request.body || {},
    ),
  );

  // Kept as a compatibility adapter for the legacy admin page during cutover.
  app.post(
    "/admin/notifications/broadcast",
    { preHandler: app.adminRequired },
    async (request) => legacyCreateBroadcast(request.user.id, request.body || {}),
  );
}
