import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ClipboardCheck, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "@/lib/supabase";
import { dateInTimeZone, formatDateTime, formatTime, todayInTimeZone, zonedDateTime, type AppLanguage } from "@/lib/format";
import {
  TASK_CATEGORIES, TASK_PRIORITIES, compareTasks, describeTaskError, isOverdue, taskStatusVariant, useStaff,
  type Task, type TaskCategory, type TaskPriority, type TaskStatus,
} from "@/lib/procedures";
import { cn } from "@/lib/utils";
import { useAuth } from "@/auth/AuthProvider";
import { useOrg } from "@/auth/OrgProvider";
import { PageHeader } from "@/components/PageHeader";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input, NativeSelect, Textarea } from "@/components/ui/input";
import { FormField } from "@/components/ui/form-field";
import { Dialog, DialogFooter } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/states/EmptyState";
import { ErrorState } from "@/components/states/ErrorState";
import { useRooms } from "./RoomsPage";

const TABS = ["open", "mine", "closed"] as const;
type Tab = (typeof TABS)[number];

/** Задачи сотрудников: уборка, ремонт, поручения. Права и переходы проверяет set_task_status() на сервере. */
export function TasksPage() {
  const { t, i18n } = useTranslation();
  const lang = (i18n.language === "kk" ? "kk" : "ru") as AppLanguage;
  const { user } = useAuth();
  const { org, can, writable, hasFeature } = useOrg();
  const qc = useQueryClient();
  const [params, setParams] = useSearchParams();
  const tab = (TABS as readonly string[]).includes(params.get("tab") ?? "") ? (params.get("tab") as Tab) : "open";
  const [editing, setEditing] = useState<Task | "new" | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const enabled = hasFeature("tasks");
  const manager = can("tasks.write");
  const active = writable && enabled;
  const staff = useStaff(org.id, "tasks.read");
  const rooms = useRooms(org.id);

  const tasks = useQuery({
    queryKey: ["tasks", org.id, tab, user?.id],
    queryFn: async () => {
      let q = supabase.from("tasks").select("*").eq("tenant_id", org.id);
      if (tab === "closed") q = q.in("status", ["done", "cancelled"]).order("completed_at", { ascending: false, nullsFirst: false });
      else q = q.in("status", ["open", "in_progress"]);
      if (tab === "mine") q = q.eq("assignee_id", user!.id);
      const { data, error } = await q.limit(300);
      if (error) throw error;
      const list = data as Task[];
      return tab === "closed" ? list : list.sort(compareTasks);
    },
  });

  const setStatus = async (task: Task, status: TaskStatus) => {
    setBusy(task.id);
    const { error } = await supabase.rpc("set_task_status", { p_task_id: task.id, p_status: status });
    setBusy(null);
    if (error) return toast.error(describeTaskError(error, t));
    toast.success(t(`tasks.statusChanged.${status}`));
    for (const key of ["tasks", "rooms", "today-summary"]) void qc.invalidateQueries({ queryKey: [key, org.id] });
  };

  const staffName = (id: string | null) => staff.data?.find((s) => s.user_id === id)?.full_name;
  const roomNumber = (id: string | null) => rooms.data?.find((r) => r.id === id)?.number;
  const title = (task: Task) => task.source === "room_cleaning" && roomNumber(task.room_id)
    ? t("tasks.autoCleaning", { room: roomNumber(task.room_id) }) : task.title;
  const today = todayInTimeZone(org.timezone);
  const due = (iso: string) => dateInTimeZone(iso, org.timezone) === today
    ? `${t("tasks.todayAt")} ${formatTime(iso, lang, org.timezone)}` : formatDateTime(iso, lang, org.timezone);

  return (
    <>
      <PageHeader
        title={t("tasks.title")}
        description={t("tasks.subtitle")}
        actions={manager && active && <Button onClick={() => setEditing("new")}><Plus /> {t("tasks.new")}</Button>}
      />

      {!enabled && (
        <Card className="mb-4 border-warning/40 bg-warning/5">
          <CardContent className="py-3 text-sm">{t("tasks.planNote")}</CardContent>
        </Card>
      )}

      <div className="-mx-4 mb-4 overflow-x-auto px-4 sm:mx-0 sm:px-0">
        <div role="tablist" className="inline-flex gap-1 rounded-lg bg-muted p-1">
          {TABS.map((key) => (
            <button key={key} role="tab" aria-selected={tab === key}
              className={cn("whitespace-nowrap rounded-md px-3 py-1.5 text-sm", tab === key ? "bg-card font-medium shadow-sm" : "text-muted-foreground hover:text-foreground")}
              onClick={() => setParams({ tab: key }, { replace: true })}>
              {t(`tasks.tabs.${key}`)}
            </button>
          ))}
        </div>
      </div>

      {tasks.isLoading ? (
        <div className="grid gap-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16" />)}</div>
      ) : tasks.error ? (
        <ErrorState error={tasks.error} onRetry={() => tasks.refetch()} />
      ) : tasks.data!.length === 0 ? (
        <EmptyState icon={<ClipboardCheck className="h-5 w-5" />} title={t(`tasks.empty.${tab}`)} />
      ) : (
        <Card>
          <CardContent className="pt-2">
            <ul className="divide-y">
              {tasks.data!.map((task) => {
                const mineOrCommon = !task.assignee_id || task.assignee_id === user?.id;
                const canAct = active && (manager || mineOrCommon);
                const late = isOverdue(task);
                const isOpen = task.status === "open" || task.status === "in_progress";
                return (
                  <li key={task.id} className="py-3">
                    <div className="flex flex-wrap items-start gap-x-3 gap-y-1">
                      <span className={cn("mt-1.5 h-2 w-2 shrink-0 rounded-full",
                        task.priority === "high" ? "bg-destructive" : task.priority === "normal" ? "bg-primary" : "bg-muted-foreground/40")}
                        title={t(`tasks.priority.${task.priority}`)} aria-label={t(`tasks.priority.${task.priority}`)} />
                      <div className="min-w-0 flex-1">
                        <p className={cn("text-sm font-medium", task.status === "cancelled" && "line-through text-muted-foreground")}>{title(task)}</p>
                        {task.description && <p className="whitespace-pre-line text-sm text-muted-foreground">{task.description}</p>}
                        <p className="mt-0.5 text-xs text-muted-foreground">
                          {t(`tasks.category.${task.category}`)}
                          {task.room_id && roomNumber(task.room_id) && ` · ${t("tasks.room", { number: roomNumber(task.room_id) })}`}
                          {" · "}{task.assignee_id ? staffName(task.assignee_id) ?? "—" : t("tasks.common")}
                          {task.due_at && (
                            <span className={cn(late && "font-medium text-destructive")}> · {t("tasks.due")}: {due(task.due_at)}</span>
                          )}
                          {task.completed_at && !isOpen && ` · ${formatDateTime(task.completed_at, lang, org.timezone)}`}
                        </p>
                      </div>
                      <Badge variant={taskStatusVariant[task.status]}>{t(`tasks.status.${task.status}`)}</Badge>
                    </div>
                    {canAct && (
                      <div className="mt-2 flex flex-wrap gap-1.5 pl-5">
                        {task.status === "open" && (
                          <Button size="sm" variant="outline" className="h-7" disabled={busy === task.id} onClick={() => setStatus(task, "in_progress")}>
                            {t("tasks.actions.start")}
                          </Button>
                        )}
                        {isOpen && (
                          <Button size="sm" className="h-7" disabled={busy === task.id} onClick={() => setStatus(task, "done")}>{t("tasks.actions.done")}</Button>
                        )}
                        {task.status === "in_progress" && (
                          <Button size="sm" variant="ghost" className="h-7" disabled={busy === task.id} onClick={() => setStatus(task, "open")}>{t("tasks.actions.pause")}</Button>
                        )}
                        {manager && isOpen && (
                          <>
                            <Button size="sm" variant="ghost" className="h-7" onClick={() => setEditing(task)}><Pencil /> {t("common.edit")}</Button>
                            <Button size="sm" variant="ghost" className="h-7 text-destructive" disabled={busy === task.id} onClick={() => setStatus(task, "cancelled")}>
                              {t("tasks.actions.cancel")}
                            </Button>
                          </>
                        )}
                        {manager && !isOpen && (
                          <Button size="sm" variant="ghost" className="h-7" disabled={busy === task.id} onClick={() => setStatus(task, "open")}>{t("tasks.actions.reopen")}</Button>
                        )}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          </CardContent>
        </Card>
      )}

      {editing && (
        <TaskDialog value={editing === "new" ? null : editing} staff={staff.data ?? []}
          rooms={rooms.data ?? []} onClose={() => setEditing(null)} />
      )}
    </>
  );
}

function TaskDialog({ value, staff, rooms, onClose }: {
  value: Task | null;
  staff: { user_id: string; full_name: string }[];
  rooms: { id: string; number: string }[];
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const { org } = useOrg();
  const qc = useQueryClient();
  const tz = org.timezone;
  const [title, setTitle] = useState(value?.title ?? "");
  const [description, setDescription] = useState(value?.description ?? "");
  const [category, setCategory] = useState<TaskCategory>(value?.category ?? "other");
  const [priority, setPriority] = useState<TaskPriority>(value?.priority ?? "normal");
  const [assignee, setAssignee] = useState(value?.assignee_id ?? "");
  const [room, setRoom] = useState(value?.room_id ?? "");
  const [dueDate, setDueDate] = useState(value?.due_at ? dateInTimeZone(value.due_at, tz) : "");
  const [dueTime, setDueTime] = useState(value?.due_at ? formatTime(value.due_at, "ru", tz) : "");
  const [busy, setBusy] = useState(false);

  const save = async () => {
    if (!title.trim()) return toast.error(t("tasks.errors.title"));
    const dueAt = dueDate ? zonedDateTime(dueDate, dueTime || "18:00", tz) : null;
    const args = {
      p_title: title.trim(), p_description: description.trim() || null, p_category: category, p_priority: priority,
      p_assignee_id: assignee || null, p_room_id: room || null, p_due_at: dueAt,
    };
    setBusy(true);
    const { error } = value
      ? await supabase.rpc("update_task", { p_task_id: value.id, ...args })
      : await supabase.rpc("create_task", { p_tenant: org.id, ...args });
    setBusy(false);
    if (error) return toast.error(describeTaskError(error, t));
    toast.success(t(value ? "common.saved" : "tasks.created"));
    void qc.invalidateQueries({ queryKey: ["tasks", org.id] });
    onClose();
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()} title={value ? t("tasks.editTitle") : t("tasks.new")}>
      <div className="grid gap-4">
        <FormField id="task-title" label={t("tasks.fields.title")}>
          <Input id="task-title" value={title} maxLength={200} placeholder={t("tasks.titlePlaceholder")} onChange={(e) => setTitle(e.target.value)} autoFocus />
        </FormField>
        <FormField id="task-desc" label={t("tasks.fields.description")}>
          <Textarea id="task-desc" rows={2} maxLength={2000} value={description} onChange={(e) => setDescription(e.target.value)} />
        </FormField>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="task-cat" label={t("tasks.fields.category")}>
            <NativeSelect id="task-cat" value={category} onChange={(e) => setCategory(e.target.value as TaskCategory)}>
              {TASK_CATEGORIES.map((c) => <option key={c} value={c}>{t(`tasks.category.${c}`)}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="task-prio" label={t("tasks.fields.priority")}>
            <NativeSelect id="task-prio" value={priority} onChange={(e) => setPriority(e.target.value as TaskPriority)}>
              {TASK_PRIORITIES.map((p) => <option key={p} value={p}>{t(`tasks.priority.${p}`)}</option>)}
            </NativeSelect>
          </FormField>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="task-assignee" label={t("tasks.fields.assignee")}>
            <NativeSelect id="task-assignee" value={assignee} onChange={(e) => setAssignee(e.target.value)}>
              <option value="">{t("tasks.common")}</option>
              {staff.map((s) => <option key={s.user_id} value={s.user_id}>{s.full_name}</option>)}
            </NativeSelect>
          </FormField>
          <FormField id="task-room" label={t("tasks.fields.room")}>
            <NativeSelect id="task-room" value={room} onChange={(e) => setRoom(e.target.value)}>
              <option value="">—</option>
              {rooms.map((r) => <option key={r.id} value={r.id}>{r.number}</option>)}
            </NativeSelect>
          </FormField>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <FormField id="task-due" label={t("tasks.fields.dueDate")}>
            <Input id="task-due" type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
          </FormField>
          <FormField id="task-due-time" label={t("tasks.fields.dueTime")}>
            <Input id="task-due-time" type="time" step={300} value={dueTime} disabled={!dueDate} onChange={(e) => setDueTime(e.target.value)} />
          </FormField>
        </div>
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={onClose}>{t("common.cancel")}</Button>
        <Button disabled={busy} onClick={save}>{busy ? t("common.saving") : t("common.save")}</Button>
      </DialogFooter>
    </Dialog>
  );
}
