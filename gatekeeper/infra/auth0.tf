# Copies each app's tenant_id metadata into the tokens it issues.
# Source lives in auth0/actions/ — read from file, not inlined, so there's one copy.
resource "auth0_action" "add_tenant_id" {
  name    = "add-tenant-id"
  code    = file("${path.module}/../auth0/actions/add-tenant-id.js")
  runtime = "node22"

  # The Deploy button: without it the Action is a draft that never runs.
  deploy = true

  supported_triggers {
    id      = "credentials-exchange" # Machine to Machine; post-login never fires for client_credentials
    version = "v2"
  }
}

# Attaches the Action to the flow — the drag-and-drop step in the dashboard.
# Deployed but unattached means it never runs.
resource "auth0_trigger_action" "add_tenant_id" {
  trigger   = "credentials-exchange"
  action_id = auth0_action.add_tenant_id.id
}
