-- Future Community: Protokoll gelöschter Accounts
-- Vor dem Deployen der aktualisierten swift-task Edge Function ausführen.
-- Absichtlich KEINE Fremdschlüssel auf auth.users oder profiles:
-- Audit-Einträge müssen Kontolöschungen überleben.

CREATE TABLE IF NOT EXISTS public.account_deletion_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deleted_user_id uuid NOT NULL,
  deleted_username text,
  deleted_display_name text,
  deleted_by uuid NOT NULL,
  deleted_by_username text,
  deleted_by_display_name text,
  was_self_deletion boolean NOT NULL DEFAULT false,
  deleted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS account_deletion_audit_deleted_at_idx
  ON public.account_deletion_audit (deleted_at DESC);

ALTER TABLE public.account_deletion_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS account_deletion_audit_admin_read
  ON public.account_deletion_audit;

CREATE POLICY account_deletion_audit_admin_read
  ON public.account_deletion_audit
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
        AND (COALESCE(p.is_admin, false) = true
             OR COALESCE(p.is_admin_chef, false) = true)
    )
  );

REVOKE ALL ON public.account_deletion_audit FROM anon, authenticated;
GRANT SELECT ON public.account_deletion_audit TO authenticated;
