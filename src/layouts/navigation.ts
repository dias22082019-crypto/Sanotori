import {
  BarChart3, BedDouble, CalendarRange, ClipboardList, ClipboardCheck, CreditCard, HeartPulse, Inbox,
  LayoutDashboard, MessageCircle, UtensilsCrossed, Package, ScrollText, Settings, Star, Stethoscope, Users, Wallet, UserRound,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";
import type { Permission } from "@/lib/types";

export interface NavItem {
  key: string;
  path: string;
  icon: LucideIcon;
  /** Право, без которого пункт не показывается */
  permission?: Permission;
  /** Этап плана, на котором модуль начнёт работать (для заглушек) */
  stage?: number;
}

export interface NavSection {
  key: string;
  items: NavItem[];
}

export const NAV_SECTIONS: NavSection[] = [
  {
    key: "sectionMain",
    items: [
      { key: "dashboard", path: "", icon: LayoutDashboard },
      { key: "bookings", path: "bookings", icon: ClipboardList, permission: "bookings.read" },
      { key: "calendar", path: "calendar", icon: CalendarRange, permission: "bookings.read" },
      { key: "rooms", path: "rooms", icon: BedDouble, permission: "rooms.read" },
      { key: "guests", path: "guests", icon: UserRound, permission: "guests.read" },
      { key: "leads", path: "leads", icon: Inbox, permission: "leads.read" },
      { key: "tasks", path: "tasks", icon: ClipboardCheck, permission: "tasks.read" },
      { key: "kitchen", path: "kitchen", icon: UtensilsCrossed, permission: "kitchen.read" },
    ],
  },
  {
    key: "sectionMedical",
    items: [
      { key: "medical", path: "medical", icon: Stethoscope, permission: "medical.read" },
      { key: "procedures", path: "procedures", icon: HeartPulse, permission: "procedures.read" },
    ],
  },
  {
    key: "sectionBusiness",
    items: [
      { key: "finance", path: "finance", icon: Wallet, permission: "finance.read" },
      { key: "analytics", path: "analytics", icon: BarChart3, permission: "reports.read" },
      { key: "inventory", path: "inventory", icon: Package, permission: "inventory.read" },
      { key: "messages", path: "messages", icon: MessageCircle, permission: "messages.read" },
      { key: "marketing", path: "marketing", icon: Star, permission: "marketing.read" },
    ],
  },
  {
    key: "sectionAdmin",
    items: [
      { key: "staff", path: "staff", icon: Users, permission: "members.read" },
      { key: "settings", path: "settings", icon: Settings, permission: "settings.manage" },
      { key: "billing", path: "billing", icon: CreditCard, permission: "billing.manage" },
      { key: "audit", path: "audit", icon: ScrollText, permission: "audit.read" },
    ],
  },
];

export const ADMIN_ICON = BarChart3;
