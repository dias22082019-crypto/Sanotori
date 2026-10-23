import {
  BarChart3, BedDouble, CalendarRange, ClipboardList, ClipboardCheck, CreditCard, HeartPulse, Inbox,
  LayoutDashboard, MessageCircle, Package, ScrollText, Settings, Star, Users, Wallet, UserRound,
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
      { key: "leads", path: "leads", icon: Inbox, permission: "leads.read", stage: 5 },
      { key: "tasks", path: "tasks", icon: ClipboardCheck, permission: "tasks.read", stage: 4 },
    ],
  },
  {
    key: "sectionMedical",
    items: [{ key: "procedures", path: "procedures", icon: HeartPulse, permission: "procedures.read", stage: 4 }],
  },
  {
    key: "sectionBusiness",
    items: [
      { key: "finance", path: "finance", icon: Wallet, permission: "finance.read", stage: 4 },
      { key: "inventory", path: "inventory", icon: Package, permission: "inventory.read", stage: 6 },
      { key: "messages", path: "messages", icon: MessageCircle, permission: "messages.read", stage: 5 },
      { key: "marketing", path: "marketing", icon: Star, permission: "marketing.read", stage: 6 },
    ],
  },
  {
    key: "sectionAdmin",
    items: [
      { key: "staff", path: "staff", icon: Users, permission: "members.read" },
      { key: "settings", path: "settings", icon: Settings, permission: "settings.manage" },
      { key: "billing", path: "billing", icon: CreditCard, permission: "billing.manage", stage: 6 },
      { key: "audit", path: "audit", icon: ScrollText, permission: "audit.read", stage: 6 },
    ],
  },
];

export const ADMIN_ICON = BarChart3;
