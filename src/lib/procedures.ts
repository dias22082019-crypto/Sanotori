import type { TFunction } from "i18next";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "./supabase";
import { describeError } from "./errors";

export type ProcedureStatus = "scheduled" | "done" | "no_show" | "cancelled";
export type TaskStatus = "open" | "in_progress" | "done" | "cancelled";
export type TaskPriority = "low" | "normal" | "high";
export type TaskCategory = "cleaning" | "maintenance" | "reception" | "medical" | "other";

export const TASK_CATEGORIES: TaskCategory[] = ["cleaning", "maintenance", "reception", "medical", "other"];
export const TASK_PRIORITIES: TaskPriority[] = ["high", "normal", "low"];

type Variant = "default" | "success" | "warning" | "destructive" | "secondary" | "outline";

export const procedureStatusVariant: Record<ProcedureStatus, Variant> = {
  scheduled: "default",
  done: "success",
  no_show: "destructive",
  cancelled: "secondary",
};

export const taskStatusVariant: Record<TaskStatus, Variant> = {
  open: "warning",
  in_progress: "default",
  done: "success",
  cancelled: "secondary",
};

export interface ProcedureType {
  id: string;
  name: string;
  duration_min: number;
  price: string | number;
  description: string | null;
  is_active: boolean;
}

export interface TreatmentRoom {
  id: string;
  name: string;
  is_active: boolean;
}

export interface Appointment {
  id: string;
  guest_id: string;
  booking_id: string | null;
  procedure_type_id: string;
  treatment_room_id: string | null;
  specialist_id: string | null;
  starts_at: string;
  ends_at: string;
  status: ProcedureStatus;
  price: string | number;
  included: boolean;
  note: string | null;
  cancel_reason: string | null;
  guest: { full_name: string } | null;
}

export const APPOINTMENT_SELECT =
  "id, guest_id, booking_id, procedure_type_id, treatment_room_id, specialist_id, starts_at, ends_at, status, price, included, note, cancel_reason, guest:guests(full_name)";

export interface Task {
  id: string;
  title: string;
  description: string | null;
  category: TaskCategory;
  priority: TaskPriority;
  status: TaskStatus;
  source: "manual" | "room_cleaning";
  assignee_id: string | null;
  room_id: string | null;
  due_at: string | null;
  created_by: string | null;
  completed_at: string | null;
  created_at: string;
}

export interface StaffMember {
  user_id: string;
  full_name: string;
}

export function useProcedureTypes(tenantId: string) {
  return useQuery({
    queryKey: ["procedure-types", tenantId],
    queryFn: async () => {
      const { data, error } = await supabase.from("procedure_types").select("*").eq("tenant_id", tenantId).order("name");
      if (error) throw error;
      return data as ProcedureType[];
    },
  });
}

export function useTreatmentRooms(tenantId: string, enabled = true) {
  return useQuery({
    queryKey: ["treatment-rooms", tenantId],
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase.from("treatment_rooms").select("*").eq("tenant_id", tenantId).order("name");
      if (error) throw error;
      return data as TreatmentRoom[];
    },
  });
}

/** Сотрудники с правом: специалисты процедур (procedures.status) или исполнители задач (tasks.read) */
export function useStaff(tenantId: string, permission: "procedures.status" | "tasks.read") {
  return useQuery({
    queryKey: ["staff-directory", tenantId, permission],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("staff_directory", { p_tenant: tenantId, p_permission: permission });
      if (error) throw error;
      return data as StaffMember[];
    },
  });
}

/** Задача просрочена: срок прошёл, а она не закрыта */
export function isOverdue(task: Pick<Task, "due_at" | "status">, now = Date.now()): boolean {
  return Boolean(task.due_at) && Date.parse(task.due_at!) < now && (task.status === "open" || task.status === "in_progress");
}

/** Порядок задач: сначала незакрытые, затем по важности и сроку */
export function compareTasks(a: Task, b: Task): number {
  const open = (t: Task) => (t.status === "open" || t.status === "in_progress" ? 0 : 1);
  const prio = { high: 0, normal: 1, low: 2 } as const;
  const due = (t: Task) => (t.due_at ? Date.parse(t.due_at) : Number.POSITIVE_INFINITY);
  return open(a) - open(b) || prio[a.priority] - prio[b.priority] || due(a) - due(b) || b.created_at.localeCompare(a.created_at);
}

export function describeProcedureError(error: unknown, t: TFunction): string {
  const e = (error ?? {}) as { code?: string; message?: string };
  const m = e.message ?? "";
  if (e.code === "23P01" && /procedure_room_busy/.test(m)) return t("procedures.errors.roomBusy");
  if (e.code === "23P01" && /procedure_specialist_busy/.test(m)) return t("procedures.errors.specialistBusy");
  if (e.code === "23P01" && /procedure_guest_busy/.test(m)) return t("procedures.errors.guestBusy");
  if (e.code === "23505") return t("procedures.errors.nameTaken");
  if (/outside the stay dates/.test(m)) return t("procedures.errors.outsideStay");
  if (/in the past/.test(m)) return t("procedures.errors.past");
  if (/has not started yet/.test(m)) return t("procedures.errors.notStarted");
  if (/specialist is not available/.test(m)) return t("procedures.errors.specialist");
  if (/treatment room is not available/.test(m)) return t("procedures.errors.room");
  if (/procedure is not available/.test(m)) return t("procedures.errors.inactive");
  if (/booking is not active|does not belong/.test(m)) return t("procedures.errors.booking");
  if (/guest is archived/.test(m)) return t("procedures.errors.archived");
  return describeError(error, t);
}

export function describeTaskError(error: unknown, t: TFunction): string {
  const m = ((error ?? {}) as { message?: string }).message ?? "";
  if (/assignee is not available/.test(m)) return t("tasks.errors.assignee");
  if (/task is closed/.test(m)) return t("tasks.errors.closed");
  return describeError(error, t);
}
