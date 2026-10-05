/**
 * Machine to Machine trigger (credentials-exchange).
 *
 * Copies the calling application's tenant_id metadata into the access token as a
 * namespaced custom claim. It only copies — the value is set per app in Auth0, so
 * one Action serves every tenant.
 *
 * The source of truth is gatekeeper/auth0/actions/; the copy that runs is the one
 * deployed in Auth0, which must also be attached to the trigger.
 */

// Auth0 silently drops custom claims that aren't namespaced. Never fetched — just a label.
const CLAIM = "https://gatekeeper/tenant_id";

// This trigger fires for EVERY M2M token in the tenant, including Management API
// tokens for Terraform's own app. Denying those locks Terraform out of Auth0, so
// scope the whole Action to our API and leave every other audience untouched.
const API = "https://gatekeeper/api";

exports.onExecuteCredentialsExchange = async (event, api) => {
  if (event.resource_server?.identifier !== API) {
    return;
  }

  const tenantId = event.client.metadata?.tenant_id;

  // Refuse at the source: an app with no tenant_id has no business getting a token.
  // The authorizer checks the claim again anyway — it must not assume this ran.
  if (typeof tenantId !== "string" || tenantId.trim() === "") {
    api.access.deny(
      "invalid_request",
      `application ${event.client.name} has no tenant_id metadata`,
    );
    return;
  }

  api.accessToken.setCustomClaim(CLAIM, tenantId.trim());
};
