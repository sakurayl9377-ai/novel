import {
  discardGrowthRulesDraft,
  growthRulesWorkbench,
  publishGrowthRulesDraft,
  restoreGrowthRulesRevision,
  saveGrowthRulesDraft,
} from "./growth-rule-service.js";

export async function adminGrowthRuleRoutes(app) {
  app.get(
    "/admin/growth/rules/workbench",
    { preHandler: app.adminRequired },
    async () => growthRulesWorkbench(),
  );

  app.put(
    "/admin/growth/rules/draft",
    { preHandler: app.adminRequired },
    async (request) => saveGrowthRulesDraft(request.user.id, request.body || {}),
  );

  app.post(
    "/admin/growth/rules/draft/publish",
    { preHandler: app.adminRequired },
    async (request) =>
      publishGrowthRulesDraft(request.user.id, request.body || {}),
  );

  app.post(
    "/admin/growth/rules/draft/discard",
    { preHandler: app.adminRequired },
    async (request) =>
      discardGrowthRulesDraft(request.user.id, request.body || {}),
  );

  app.post(
    "/admin/growth/rules/revisions/:revision/restore-draft",
    { preHandler: app.adminRequired },
    async (request) =>
      restoreGrowthRulesRevision(
        request.user.id,
        request.params.revision,
        request.body || {},
      ),
  );
}
