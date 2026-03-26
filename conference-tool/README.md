# Conference Tool

This directory contains deployment-side assets for the conference tool.

The Authentik-related pieces live in `authentik-blueprints/`:

- `10-groups.yaml` creates the baseline `conference-user` and `conference-admin` groups.
- `20-groups-claim.yaml` creates a reusable OIDC scope mapping that emits only
  `conference-*` groups in the `groups` claim.

Concrete committees and committee memberships are intentionally not declared
here. Those stay dynamic inside the conference tool itself.
