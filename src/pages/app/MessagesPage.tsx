import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { Link, useSearchParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertCircle, ArrowLeft, Check, CheckCheck, Clock, MessageCircle, Plus, Send } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { describeError } from "@/lib/errors";
import { formatDateTime, formatKzPhone, whatsappLink, type AppLanguage } from "@/lib/format";
import { optionalGuestPhone } from "@/lib/schemas";
import {
  TEMPLATE_LANG_PATTERN, TEMPLATE_NAME_PATTERN, describeWhatsappError, invokeWhatsapp,
  type Message, type MessageStatus, type MessageThread, type WhatsappSettings,
} from "@/lib/whatsapp";
import { cn } from "@/lib/utils";
import { useOrg } from "@/auth/OrgProvider";
import { useOpenLeadByPhone } from "./LeadsPage";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";

/** Переписка с гостями в WhatsApp (официальный Cloud API). Отправку проверяют база и Edge Function «whatsapp». */
export function MessagesPage() {
  const { t } = useTranslation();
  const { org, can, writable, hasFeature } = useOrg();
  const [params, setParams] = useSearchParams();
  const phone = params.get("phone");
  const bookingId = params.get("booking");
  const [newChat, setNewChat] = useState(false);

  const settings = useQuery({
    queryKey: ["whatsapp-settings", org.id],
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("whatsapp_settings", { p_tenant: org.id });
      if (error) throw error;
      return data as WhatsappSettings;
    },
  });
  const threads = useQuery({
    queryKey: ["message-threads", org.id],
    refetchInterval: 15_000,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("message_threads", { p_tenant: org.id });
      if (error) throw error;
      return data as MessageThread[];
    },
  });

  const s = settings.data;
  const connected = Boolean(s?.connected && s.has_token && s.is_enabled);
  const canSend = connected && writable && hasFeature("integrations") && can("messages.send");
  const open = (p: string | null) => setParams(p ? { phone: p } : {}, { replace: false });
  const current = threads.data?.find((x) => x.phone === phone);

  const banner = !hasFeature("integrations") ? t("whatsapp.planNote")
    : s && !connected ? t(s.connected ? "messages.paused" : "messages.notConnected") : null;

  return (
    <>
      <PageHeader title={t("messages.title")} description={t("messages.subtitle")}
        actions={canSend && <Button onClick={() => setNewChat(true)}><Plus /> {t("messages.newChat")}</Button>} />

      {banner && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="flex flex-wrap items-center gap-x-3 gap-y-1 py-3 text-sm">
            <span>{banner}</span>
            {can("settings.manage") && hasFeature("integrations") && (
              <Link className="text-primary hover:underline" to={`/app/${org.slug}/settings`}>{t("messages.toSettings")}</Link>
            )}
          </CardContent>
        </Card>
      )}

      {threads.error ? (
        describeWhatsappError(threads.error, t)
          ? <EmptyState icon={<AlertCircle className="h-5 w-5" />} title={t("common.errorTitle")} text={describeWhatsappError(threads.error, t)!} />
          : <ErrorState error={threads.error} onRetry={() => threads.refetch()} />
      ) : (
        <div className="grid min-h-[60dvh] gap-4 md:grid-cols-[minmax(0,20rem)_minmax(0,1fr)]">
          <div className={cn("min-w-0", phone && "hidden md:block")}>
            <ThreadList threads={threads.data} loading={threads.isLoading} active={phone} onOpen={open} />
          </div>
          <div className={cn("min-w-0", !phone && "hidden md:block")}>
            {phone ? (
              <Conversation key={phone} phone={phone} thread={current} canSend={canSend} bookingId={bookingId} onBack={() => open(null)} />
            ) : (
              <div className="hidden h-full items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground md:flex">
                {t("messages.pick")}
              </div>
            )}
          </div>
        </div>
      )}
      {newChat && <NewChatDialog onClose={() => setNewChat(false)} onOpen={(p) => { setNewChat(false); open(p); }} />}
    </>
  );
}

function contactTitle(th: Pick<MessageThread, "guest_name" | "contact_name" | "phone"> | undefined, phone: string) {
  return th?.guest_name ?? th?.contact_name ?? formatKzPhone(phone);
}

function ThreadList(props: { threads?: MessageThread[]; loading: boolean; active: string | null; onOpen: (p: string) => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org } = useOrg();
  if (props.loading) return <div className="grid gap-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16" />)}</div>;
  if (!props.threads?.length) {
    return <EmptyState icon={<MessageCircle className="h-5 w-5" />} title={t("messages.emptyTitle")} text={t("messages.emptyText")} />;
  }
  return (
    <ul className="divide-y overflow-hidden rounded-lg border bg-card">
      {props.threads.map((th) => (
        <li key={th.phone}>
          <button className={cn("flex w-full min-w-0 items-start gap-3 px-3 py-2.5 text-left hover:bg-muted/50", props.active === th.phone && "bg-accent")}
            onClick={() => props.onOpen(th.phone)}>
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2">
                <span className="truncate font-medium">{contactTitle(th, th.phone)}</span>
                {Number(th.unread) > 0 && <Badge className="shrink-0">{Number(th.unread)}</Badge>}
              </div>
              <p className="truncate text-sm text-muted-foreground">
                {th.last_direction === "out" && `${t("messages.you")}: `}
                {th.last_kind === "template" ? t("messages.templateShort", { name: th.last_body }) : th.last_body ?? t("messages.otherKind")}
              </p>
            </div>
            <span className="shrink-0 text-xs text-muted-foreground">{formatDateTime(th.last_at, lang, org.timezone)}</span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function StatusIcon({ status }: { status: MessageStatus }) {
  const { t } = useTranslation();
  const label = t(`messages.status.${status}`);
  const cls = "h-3.5 w-3.5";
  const icon = status === "queued" || status === "sending" ? <Clock className={cls} />
    : status === "sent" ? <Check className={cls} />
    : status === "delivered" ? <CheckCheck className={cls} />
    : status === "read" ? <CheckCheck className={cn(cls, "text-primary")} />
    : status === "failed" ? <AlertCircle className={cn(cls, "text-destructive")} /> : null;
  return <span title={label} aria-label={label} className="inline-flex">{icon}</span>;
}

function Conversation(props: { phone: string; thread?: MessageThread; canSend: boolean; bookingId: string | null; onBack: () => void }) {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { org, can } = useOrg();
  const qc = useQueryClient();
  const bottom = useRef<HTMLDivElement>(null);
  const { phone, thread } = props;
  const lead = useOpenLeadByPhone(org.id, phone, can("leads.read"));

  const messages = useQuery({
    queryKey: ["messages", org.id, phone],
    refetchInterval: 10_000,
    queryFn: async () => {
      const { data, error } = await supabase.from("messages")
        .select("id, direction, phone, kind, body, template_name, template_lang, status, error, created_at")
        .eq("phone", phone).order("created_at", { ascending: false }).limit(200);
      if (error) throw error;
      return (data as Message[]).reverse();
    },
  });

  const unread = Number(thread?.unread ?? 0);
  useEffect(() => {
    if (unread === 0) return;
    void supabase.rpc("mark_thread_seen", { p_tenant: org.id, p_phone: phone })
      .then(() => qc.invalidateQueries({ queryKey: ["message-threads", org.id] }));
  }, [unread, phone, org.id, qc]);

  const count = messages.data?.length ?? 0;
  useEffect(() => bottom.current?.scrollIntoView({ block: "end" }), [count]);

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ["messages", org.id, phone] });
    void qc.invalidateQueries({ queryKey: ["message-threads", org.id] });
  };

  return (
    <div className="flex h-full min-h-[60dvh] min-w-0 flex-col rounded-lg border bg-card">
      <div className="flex items-center gap-2 border-b px-3 py-2">
        <Button size="icon" variant="ghost" className="h-8 w-8 md:hidden" aria-label={t("common.back")} onClick={props.onBack}><ArrowLeft /></Button>
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium">{contactTitle(thread, phone)}</p>
          <p className="text-xs text-muted-foreground">{formatKzPhone(phone)}</p>
        </div>
        {lead.data && (
          <Link className="shrink-0 text-xs text-primary hover:underline" to={`/app/${org.slug}/leads?lead=${lead.data.id}`}>
            {t("leads.linkShort", { number: lead.data.number })}
          </Link>
        )}
        <a className="shrink-0 text-xs text-primary hover:underline" href={whatsappLink(phone)} target="_blank" rel="noopener noreferrer">wa.me</a>
      </div>

      <div className="flex-1 space-y-2 overflow-y-auto p-3">
        {messages.isLoading && <Skeleton className="h-16" />}
        {messages.error && <p className="text-sm text-destructive">{describeError(messages.error, t)}</p>}
        {messages.data?.length === 0 && <p className="py-8 text-center text-sm text-muted-foreground">{t("messages.noMessages")}</p>}
        {messages.data?.map((m) => (
          <div key={m.id} className={cn("flex", m.direction === "out" ? "justify-end" : "justify-start")}>
            <div className={cn("max-w-[85%] rounded-lg px-3 py-2 text-sm", m.direction === "out" ? "bg-primary/10" : "bg-muted")}>
              {m.kind === "template" ? (
                <p className="italic">{t("messages.templateShort", { name: m.template_name })} · {m.template_lang}</p>
              ) : (
                <p className="whitespace-pre-wrap break-words">{m.body ?? t("messages.otherKind")}</p>
              )}
              <div className="mt-1 flex items-center justify-end gap-1 text-[11px] text-muted-foreground">
                {formatDateTime(m.created_at, lang, org.timezone)}
                {m.direction === "out" && <StatusIcon status={m.status} />}
              </div>
              {m.status === "failed" && m.error && (
                <p className="mt-1 break-words text-xs text-destructive">{describeWhatsappError({ message: m.error }, t) ?? m.error}</p>
              )}
            </div>
          </div>
        ))}
        <div ref={bottom} />
      </div>

      {props.canSend ? (
        <Composer phone={phone} windowOpen={Boolean(thread?.window_open)} bookingId={props.bookingId} onSent={refresh} />
      ) : (
        <p className="border-t px-3 py-2 text-xs text-muted-foreground">{t("messages.readOnly")}</p>
      )}
    </div>
  );
}

function Composer(props: { phone: string; windowOpen: boolean; bookingId: string | null; onSent: () => void }) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const [text, setText] = useState("");
  const [tpl, setTpl] = useState("");
  const [tplLang, setTplLang] = useState("ru");
  const [busy, setBusy] = useState(false);

  const send = async (body: Record<string, unknown>) => {
    setBusy(true);
    try {
      const res = await invokeWhatsapp<{ status: "sent" | "failed"; error: string | null }>({
        action: "send", tenant: org.id, phone: props.phone, booking_id: props.bookingId, ...body,
      });
      if (res.status === "failed") toast.error(describeWhatsappError({ message: res.error ?? "" }, t) ?? t("messages.errors.failed", { error: res.error }));
      else {
        setText("");
        setTpl("");
      }
    } catch (error) {
      toast.error(describeWhatsappError(error, t) ?? describeError(error, t));
    } finally {
      setBusy(false);
      props.onSent();
    }
  };

  if (props.windowOpen) {
    return (
      <form className="flex items-end gap-2 border-t p-3" onSubmit={(e) => { e.preventDefault(); if (text.trim()) void send({ text: text.trim() }); }}>
        <Textarea rows={2} maxLength={4096} className="min-h-[44px] flex-1" placeholder={t("messages.placeholder")} value={text}
          aria-label={t("messages.placeholder")}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} />
        <Button type="submit" size="icon" disabled={busy || !text.trim()} aria-label={t("messages.send")}><Send /></Button>
      </form>
    );
  }

  const valid = TEMPLATE_NAME_PATTERN.test(tpl.trim()) && TEMPLATE_LANG_PATTERN.test(tplLang.trim());
  return (
    <form className="grid gap-2 border-t p-3" onSubmit={(e) => { e.preventDefault(); if (valid) void send({ template_name: tpl.trim(), template_lang: tplLang.trim() }); }}>
      <p className="text-xs text-muted-foreground">{t("messages.windowClosed")}</p>
      <div className="flex flex-wrap items-end gap-2">
        <Input className="min-w-0 basis-full sm:basis-0 sm:flex-1" placeholder={t("messages.templateName")} aria-label={t("messages.templateName")} value={tpl}
          onChange={(e) => setTpl(e.target.value.toLowerCase())} />
        <Input className="w-24 shrink-0" aria-label={t("messages.templateLang")} value={tplLang} onChange={(e) => setTplLang(e.target.value)} />
        <Button type="submit" disabled={busy || !valid}><Send /> {t("messages.sendTemplate")}</Button>
      </div>
      <a className="text-xs text-primary hover:underline" href={whatsappLink(props.phone)} target="_blank" rel="noopener noreferrer">{t("messages.openWaMe")}</a>
    </form>
  );
}

function NewChatDialog({ onClose, onOpen }: { onClose: () => void; onOpen: (phone: string) => void }) {
  const { t } = useTranslation();
  const [value, setValue] = useState("");
  const parsed = useMemo(() => optionalGuestPhone.safeParse(value), [value]);
  const phone = parsed.success ? parsed.data : null;
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={t("messages.newChat")} description={t("messages.newChatHint")}>
      <form onSubmit={(e) => { e.preventDefault(); if (phone) onOpen(phone); }}>
        <FormField id="new_chat_phone" label={t("guests.fields.phone")} error={value && !phone ? t("validation.phone") : undefined}>
          <Input id="new_chat_phone" type="tel" inputMode="tel" placeholder="+7 7XX XXX XX XX" autoFocus value={value} onChange={(e) => setValue(e.target.value)} />
        </FormField>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
          <Button type="submit" disabled={!phone}>{t("messages.openChat")}</Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
