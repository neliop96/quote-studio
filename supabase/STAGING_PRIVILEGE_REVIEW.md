# Privilege review: proposals only

No hardening below has been applied. This file separates proposed changes from
the verified schema reconstruction. No production configuration changes are
authorized by creating the baseline.

## Preserved behavior

- Baseline object ACLs match captured production metadata, including broad anon
  and authenticated SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN
  grants on most original tables. quote_settings excludes anon;
  quotation_email_log grants only service_role among client/service roles.
- The email-log identity sequence grants SELECT/UPDATE/USAGE to anon,
  authenticated, and service_role, as audited.
- Audited postgres public default ACLs are recreated so the existing migrations
  inherit the same grants as production. Per-function ACLs are explicitly restored
  for baseline routines. Later files revoke PUBLIC but may retain anon grants
  inherited from defaults; their bodies perform authentication/authorization.
- RLS is enabled, not forced. postgres-owned SECURITY DEFINER routines use an
  empty search_path. service_role has BYPASSRLS as a Supabase platform prerequisite.
- profiles.role remains nonblank text with default employee. is_admin recognizes
  only admin. Profile management remains admin-only, not self-service.
- quote_settings SELECT is limited to admin/employee. Customer INSERT/UPDATE is
  allowed to any authenticated caller by existing policies.
- No new grants to PUBLIC are added for baseline tables/functions/sequences.
  Public schema USAGE matches the audited schema permissions.
- The last existing migration intentionally restricts inventory workflow access.
  That previously authorized patch is the only workflow hardening in this chain.

## Proposed follow-up requiring review and approval

1. Replace broad table ACLs with the exact operations each client needs. Revoke
   TRUNCATE (not protected by RLS), TRIGGER, REFERENCES, and MAINTAIN from client
   roles unless a verified requirement exists. Inspect effective inherited grants.
2. Make future function grants deny-by-default, accounting for global PUBLIC
   EXECUTE defaults as well as schema-specific defaults. Revoke anon EXECUTE on
   authenticated RPCs and explicitly grant each reviewed signature.
3. Limit email-log sequence privileges to the integration that writes logs.
4. Review admin profile role changes and deletion separately. Do not imply a
   privilege-escalation path for ordinary employees: captured policies permit
   profile writes only to admins. Future owner/role management is out of scope.
5. Decide whether quote_settings readers should include the expanded inventory
   roles. Preserve admin/employee behavior until a role design is approved.
6. Review authenticated customer writes and quote update ownership rules against
   intended business behavior; do not change them silently.
7. Verify later-table ACLs after the full chain. Existing incremental migrations
   grant selected operations without first revoking every inherited privilege.

Staging is suitable only for isolated synthetic validation until these known ACL
risks are accepted or separately hardened. Do not advertise this reconstruction
as a hardened production deployment.
