import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useTranslation } from "react-i18next";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Copy, Users } from "lucide-react";
import { toast } from "sonner";
import { z } from "zod";
import { supabase } from "@/lib/supabase";
import { emailSchema } from "@/lib/schemas";
import { describeError } from "@/lib/errors";
import type { MemberStatus, Role } from "@/lib/types";
import { useAuth } from "@/auth/AuthProvider";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { ConfirmDialog } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

interface MemberRow {
  id: string;
  user_id: string;
  status: MemberStatus;
  role: Role;
  profile: { full_name: string | null } | null;
}

const inviteSchema = z.object({ email: emailSchema, roleId: z.string().uuid("validation.required") });

/** Сотрудники: список, приглашение, смена роли, приостановка. Все проверки прав выполняет сервер. */
export function StaffPage() {
  const { t, i18n } = useTranslation();
  const { user } = useAuth();
  const { org, can, writable } = useOrg();
  const queryClient = useQueryClient();
  const canManage = can("members.manage") && writable;
  const [inviteLink, setInviteLink] = useState<string | null>(null);
  const [toSuspend, setToSuspend] = useState<MemberRow | null>(null);
  const roleName = (r: Pick<Role, "name_ru" | "name_kk">) => (i18n.language === "kk" ? r.name_kk : r.name_ru);

  const members = useQuery({
    queryKey: ["members", org.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("organization_members")
        .select("id, user_id, status, role:roles(id, code, name_ru, name_kk, is_system)")
        .eq("tenant_id", org.id)
        .order("created_at");
      if (error) throw error;
      const rows = (data ?? []) as unknown as Omit<MemberRow, "profile">[];
      const { data: profiles, error: pErr } = await supabase
        .from("user_profiles")
        .select("id, full_name")
        .in("id", rows.map((r) => r.user_id));
      if (pErr) throw pErr;
      const byId = new Map((profiles ?? []).map((p) => [p.id as string, p as { full_name: string | null }]));
      return rows.map((r) => ({ ...r, profile: byId.get(r.user_id) ?? null })) as MemberRow[];
    },
  });

  const roles = useQuery({
    queryKey: ["roles", org.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("roles").select("id, code, name_ru, name_kk, is_system").order("is_system", { ascending: false });
      if (error) throw error;
      return data as Role[];
    },
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["members", org.id] });

  const changeRole = useMutation({
    mutationFn: async ({ memberId, roleId }: { memberId: string; roleId: string }) => {
      const { error } = await supabase.rpc("assign_member_role", { p_member_id: memberId, p_role_id: roleId });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(t("staff.roleChanged")); void invalidate(); },
    onError: (e) => { toast.error(e && (e as { code?: string }).code === "42501" ? t("staff.notAllowedRole") : describeError(e, t)); void invalidate(); },
  });

  const setStatus = useMutation({
    mutationFn: async ({ memberId, status }: { memberId: string; status: MemberStatus }) => {
      const { error } = await supabase.rpc("set_member_status", { p_member_id: memberId, p_status: status });
      if (error) throw error;
    },
    onSuccess: () => { toast.success(t("common.saved")); void invalidate(); },
    onError: (e) => toast.error(describeError(e, t)),
  });

  const form = useForm<z.infer<typeof inviteSchema>>({ resolver: zodResolver(inviteSchema), defaultValues: { email: "", roleId: "" } });
  const onInvite = form.handleSubmit(async ({ email, roleId }) => {
    setInviteLink(null);
    const { data, error } = await supabase.rpc("invite_member", { p_tenant: org.id, p_email: email, p_role_id: roleId });
    if (error) {
      if (error.code === "42501") toast.error(t("staff.notAllowedRole"));
      else if (error.code === "54000") toast.error(t("staff.staffLimit"));
      else toast.error(describeError(error, t));
      return;
    }
    setInviteLink(`${window.location.origin}/invite/${data as string}`);
    form.reset({ email: "", roleId });
  });

  const assignableRoles = (roles.data ?? []).filter((r) => r.code !== "owner" || members.data?.some((m) => m.user_id === user?.id && m.role.code === "owner"));

  return (
    <>
      <PageHeader title={t("staff.title")} />
      <div className="grid gap-4">
        {canManage && (
          <Card>
            <CardHeader>
              <CardTitle>{t("staff.inviteTitle")}</CardTitle>
              <CardDescription>{t("staff.inviteEmailNote")}</CardDescription>
            </CardHeader>
            <CardContent>
              <form onSubmit={onInvite} className="grid gap-3 sm:grid-cols-[1fr_220px_auto] sm:items-end" noValidate>
                <FormField id="invite-email" label={t("staff.inviteEmail")}
                  error={form.formState.errors.email?.message ? t(form.formState.errors.email.message) : undefined}>
                  <Input id="invite-email" type="email" {...form.register("email")} />
                </FormField>
                <FormField id="invite-role" label={t("staff.inviteRole")}
                  error={form.formState.errors.roleId?.message ? t(form.formState.errors.roleId.message) : undefined}>
                  <NativeSelect id="invite-role" {...form.register("roleId")}>
                    <option value="" />
                    {assignableRoles.map((r) => <option key={r.id} value={r.id}>{roleName(r)}</option>)}
                  </NativeSelect>
                </FormField>
                <Button type="submit" disabled={form.formState.isSubmitting}>{t("staff.inviteSubmit")}</Button>
              </form>
              {inviteLink && (
                <div className="mt-4 rounded-md border border-primary/30 bg-accent p-3 text-sm">
                  <p>{t("staff.inviteCreated")}</p>
                  <div className="mt-2 flex gap-2">
                    <Input readOnly value={inviteLink} onFocus={(e) => e.currentTarget.select()} />
                    <Button type="button" variant="outline" size="icon" aria-label={t("common.copy")}
                      onClick={async () => { await navigator.clipboard.writeText(inviteLink); toast.success(t("common.copied")); }}>
                      <Copy />
                    </Button>
                  </div>
                </div>
              )}
            </CardContent>
          </Card>
        )}

        <Card>
          <CardHeader><CardTitle>{t("staff.membersTitle")}</CardTitle></CardHeader>
          <CardContent>
            {members.isLoading ? (
              <div className="grid gap-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-10" />)}</div>
            ) : members.error ? (
              <ErrorState error={members.error} onRetry={() => members.refetch()} />
            ) : (members.data?.length ?? 0) <= 1 && canManage ? (
              <>
                <MembersTable />
                <div className="mt-4"><EmptyState icon={<Users className="h-5 w-5" />} title={t("staff.empty")} /></div>
              </>
            ) : (
              <MembersTable />
            )}
          </CardContent>
        </Card>
      </div>

      <ConfirmDialog
        open={toSuspend !== null}
        onOpenChange={(open) => !open && setToSuspend(null)}
        title={t("staff.suspendConfirmTitle")}
        description={t("staff.suspendConfirmText")}
        confirmLabel={t("staff.suspend")}
        cancelLabel={t("common.cancel")}
        destructive
        onConfirm={() => {
          if (toSuspend) setStatus.mutate({ memberId: toSuspend.id, status: "suspended" });
          setToSuspend(null);
        }}
      />
    </>
  );

  function MembersTable() {
    return (
      <div className="-mx-5 overflow-x-auto">
        <table className="w-full min-w-[560px] text-sm">
          <thead>
            <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
              <th className="px-5 py-2 font-medium">{t("staff.colName")}</th>
              <th className="px-5 py-2 font-medium">{t("staff.colRole")}</th>
              <th className="px-5 py-2 font-medium">{t("staff.colStatus")}</th>
              {canManage && <th className="px-5 py-2 text-right font-medium">{t("staff.colActions")}</th>}
            </tr>
          </thead>
          <tbody className="divide-y">
            {members.data?.map((m) => {
              const isMe = m.user_id === user?.id;
              return (
                <tr key={m.id}>
                  <td className="px-5 py-2.5">
                    {m.profile?.full_name || t("staff.noName")}
                    {isMe && <span className="ml-1 text-xs text-muted-foreground">({t("staff.you")})</span>}
                  </td>
                  <td className="px-5 py-2.5">
                    {canManage && !isMe ? (
                      <NativeSelect
                        className="h-8 w-48"
                        value={m.role.id}
                        aria-label={t("staff.colRole")}
                        onChange={(e) => changeRole.mutate({ memberId: m.id, roleId: e.target.value })}
                      >
                        {!assignableRoles.some((r) => r.id === m.role.id) && <option value={m.role.id}>{roleName(m.role)}</option>}
                        {assignableRoles.map((r) => <option key={r.id} value={r.id}>{roleName(r)}</option>)}
                      </NativeSelect>
                    ) : (
                      roleName(m.role)
                    )}
                  </td>
                  <td className="px-5 py-2.5">
                    <Badge variant={m.status === "active" ? "success" : "warning"}>{t(`staff.status.${m.status}`)}</Badge>
                  </td>
                  {canManage && (
                    <td className="px-5 py-2.5 text-right">
                      {!isMe && (m.status === "active" ? (
                        <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setToSuspend(m)}>{t("staff.suspend")}</Button>
                      ) : (
                        <Button size="sm" variant="ghost" onClick={() => setStatus.mutate({ memberId: m.id, status: "active" })}>{t("staff.resume")}</Button>
                      ))}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    );
  }
}
