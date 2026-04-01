# Reporting Tool Admin OIDC Upstream Handoff

## Status

Completed upstream and retained here as implementation history.

The current `reporting-tool/app` submodule now supports
`ADMIN_OIDC_ALLOWED_GROUPS`, so this infra repo can authorize Witness admin
access directly through the Authentik group `reporting-tool-admin-access`.

## Purpose

This document is the handoff brief for the upstream `reporting-tool/app`
repository, which is a git submodule in this repo and must be treated as
read-only here.

The infra repo will provision Authentik as the OIDC provider for Witness admin
login and will restrict the Authentik application to a dedicated group:

- `reporting-tool-admin-access`

However, the current app code only authorizes admin OIDC logins by:

- `ADMIN_OIDC_ALLOWED_EMAILS`
- `ADMIN_OIDC_ALLOWED_SUBJECTS`

It does not currently authorize by group claim.

That means this infra repo can enforce group membership inside Authentik, but
the upstream app still needs a small feature to understand Authentik's `groups`
claim directly.

## Repo Boundary

Do not implement the following changes in `vps-devops/reporting-tool/app`.
Those files are fetched with a deploy-key-backed submodule checkout and are
read-only in this repo.

Instead, make the code changes in the upstream `reporting-tool/app` repository
itself, then update the submodule commit in this repo later.

## Requested Upstream Changes

Implement group-based admin OIDC authorization for the `/admin` console.

### Functional goal

Allow the app to authorize an admin OIDC login when the authenticated identity
contains an allowed Authentik group, specifically:

- `reporting-tool-admin-access`

### App behavior requirements

1. Add support for a new environment variable:
   - `ADMIN_OIDC_ALLOWED_GROUPS`
2. Treat OIDC config as valid if at least one of these is configured:
   - `ADMIN_OIDC_ALLOWED_EMAILS`
   - `ADMIN_OIDC_ALLOWED_SUBJECTS`
   - `ADMIN_OIDC_ALLOWED_GROUPS`
3. Read `groups` from the OIDC identity:
   - from the ID token payload and/or
   - from the userinfo endpoint response
4. Accept `groups` as either:
   - a string
   - an array of strings
5. Authorize admin access if any configured allowed group matches any group in
   the identity.
6. Keep existing password admin mode unchanged.
7. Keep existing email and subject allow-list behavior unchanged.
8. Keep the existing verified-email requirement for email-based authorization.

## Suggested File Targets

These are the likely files to update in the upstream app repo:

- `src/lib/server/admin-auth.ts`
- `src/lib/server/admin-auth.test.ts`
- `.env.example`
- `README.md`
- `docs/deployment.md`
- `docker-compose.yml`
- `playwright.config.ts`
- `tests/oidc-provider.js`
- `tests/admin-oidc.e2e.ts`

## Acceptance Criteria

The upstream change is complete when all of the following are true:

1. The app accepts `ADMIN_OIDC_ALLOWED_GROUPS`.
2. OIDC config validation succeeds when only `ADMIN_OIDC_ALLOWED_GROUPS` is set.
3. An OIDC identity with group `reporting-tool-admin-access` can access
   `/admin`.
4. An OIDC identity without that group is denied.
5. Existing email-based admin OIDC login still works.
6. Existing subject-based admin OIDC login still works.
7. Password-mode admin login still works.
8. The app docs clearly describe group-based admin authorization.

## Test Expectations

At minimum, the upstream agent should run focused checks covering:

- unit tests for admin auth config and authorization
- the admin OIDC Playwright flow

The test suite should prove:

- allowed group -> login succeeds
- missing group -> login denied
- legacy email/subject allow-list paths still behave as before

## Important Coordination Note

This infra repo now:

- create the Authentik group `reporting-tool-admin-access`
- create an Authentik OIDC application/provider for Witness admin login
- restrict the Authentik application to that group
- continue passing the app its existing email/subject allow-list env vars

The temporary email/subject bridge is no longer needed after the upstream app
change landed.
