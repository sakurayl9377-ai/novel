import { run } from "./db.js";

export function recordAdminAudit(request, reply) {
  const user = request.user;
  if (!user || user.role !== "admin") return;
  const method = String(request.method || "GET").toUpperCase();
  if (method === "GET" && Number(reply.statusCode || 0) < 400) return;
  const url = String(request.raw?.url || request.url || "");
  if (!url.includes("/admin/")) return;
  try {
    run(
      `INSERT INTO admin_audit_logs
       (admin_user_id, method, path, status_code, ip, user_agent, request_id)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        user.id,
        method,
        url.slice(0, 500),
        Number(reply.statusCode || 0),
        String(request.ip || "").slice(0, 80),
        String(request.headers?.["user-agent"] || "").slice(0, 300),
        String(request.id || "").slice(0, 100),
      ],
    );
  } catch (error) {
    request.log?.warn?.({ error }, "failed to record admin audit log");
  }
}
