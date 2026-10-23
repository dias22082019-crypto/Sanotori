import { useState } from "react";
import { Link, NavLink, Outlet, useNavigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeftRight, ExternalLink, LogOut, Menu, UserRound } from "lucide-react";
import { useAuth } from "@/auth/AuthProvider";
import { myOrganizationsQuery, useOrg } from "@/auth/OrgProvider";
import { supabase } from "@/lib/supabase";
import { formatDate } from "@/lib/format";
import { appUrl, cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { LanguageSwitcher } from "@/components/LanguageSwitcher";
import { Logo } from "@/components/Logo";
import { ADMIN_ICON, NAV_SECTIONS } from "./navigation";

function SidebarNav({ onNavigate }: { onNavigate?: () => void }) {
  const { t } = useTranslation();
  const { org, can } = useOrg();
  const base = `/app/${org.slug}`;
  const isPlatformAdmin = useIsPlatformAdmin();

  return (
    <nav className="flex-1 space-y-5 overflow-y-auto px-3 py-4">
      {NAV_SECTIONS.map((section) => {
        const items = section.items.filter((i) => !i.permission || can(i.permission));
        if (items.length === 0) return null;
        return (
          <div key={section.key}>
            <p className="px-2 pb-1 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
              {t(`nav.${section.key}`)}
            </p>
            <ul className="space-y-0.5">
              {items.map((item) => (
                <li key={item.key}>
                  <NavLink
                    to={item.path ? `${base}/${item.path}` : base}
                    end={!item.path}
                    onClick={onNavigate}
                    className={({ isActive }) =>
                      cn(
                        "flex items-center gap-2.5 rounded-md px-2 py-1.5 text-sm transition-colors",
                        isActive ? "bg-accent font-medium text-accent-foreground" : "text-foreground/80 hover:bg-muted",
                      )
                    }
                  >
                    <item.icon className="h-4 w-4 shrink-0" />
                    <span className="truncate">{t(`nav.${item.key}`)}</span>
                    {item.stage && (
                      <span className="ml-auto rounded bg-muted px-1.5 text-[10px] text-muted-foreground">{item.stage}</span>
                    )}
                  </NavLink>
                </li>
              ))}
            </ul>
          </div>
        );
      })}
      {isPlatformAdmin && (
        <NavLink
          to="/admin"
          onClick={onNavigate}
          className="flex items-center gap-2.5 rounded-md px-2 py-1.5 text-sm text-foreground/80 hover:bg-muted"
        >
          <ADMIN_ICON className="h-4 w-4" />
          {t("nav.admin")}
        </NavLink>
      )}
    </nav>
  );
}

export function usePlatformAdminQuery() {
  const { user } = useAuth();
  return useQuery({
    queryKey: ["is-platform-admin", user?.id],
    enabled: Boolean(user),
    queryFn: async () => {
      const { data, error } = await supabase.from("platform_admins").select("user_id").maybeSingle();
      if (error) throw error;
      return Boolean(data);
    },
  });
}

export function useIsPlatformAdmin(): boolean {
  return usePlatformAdminQuery().data ?? false;
}

function OrgHeader() {
  const { org } = useOrg();
  return (
    <div className="flex h-14 items-center gap-2 border-b px-4">
      <Logo compact />
      <div className="min-w-0">
        <p className="truncate text-sm font-semibold leading-tight">{org.name}</p>
        <p className="truncate text-xs text-muted-foreground">{org.city ?? org.slug}</p>
      </div>
    </div>
  );
}

function SubscriptionBanner() {
  const { t, i18n } = useTranslation();
  const { subscription, writable } = useOrg();
  const lang = i18n.language === "kk" ? "kk" : "ru";
  if (!writable) {
    return <div className="border-b border-warning/30 bg-warning/10 px-4 py-2 text-sm text-foreground">{t("subscription.readOnly")}</div>;
  }
  if (subscription?.status === "trialing" && subscription.trial_ends_at) {
    return (
      <div className="border-b bg-accent px-4 py-1.5 text-xs text-accent-foreground">
        {t("subscription.trialUntil", { date: formatDate(subscription.trial_ends_at, lang) })}
      </div>
    );
  }
  return null;
}

function UserMenu() {
  const { t } = useTranslation();
  const { user, signOut } = useAuth();
  const { org } = useOrg();
  const navigate = useNavigate();
  const orgs = useQuery(myOrganizationsQuery);

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" aria-label={t("nav.account")}>
          <UserRound />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64">
        <DropdownMenuLabel className="truncate">{user?.email}</DropdownMenuLabel>
        <DropdownMenuItem onSelect={() => navigate("/account")}>
          <UserRound /> {t("nav.account")}
        </DropdownMenuItem>
        {org.is_published && (
          <DropdownMenuItem onSelect={() => window.open(appUrl(`/s/${org.slug}`), "_blank", "noopener")}>
            <ExternalLink /> {t("nav.publicPage")}
          </DropdownMenuItem>
        )}
        {(orgs.data?.length ?? 0) > 1 && (
          <DropdownMenuItem onSelect={() => navigate("/select-org")}>
            <ArrowLeftRight /> {t("nav.switchOrg")}
          </DropdownMenuItem>
        )}
        <DropdownMenuSeparator />
        <DropdownMenuItem
          onSelect={async () => {
            await signOut();
            navigate("/login", { replace: true });
          }}
        >
          <LogOut /> {t("common.signOut")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

/** Рабочее пространство санатория: боковая навигация (на мобильных — выезжающая), верхняя панель */
export function AppLayout() {
  const { t } = useTranslation();
  const { org } = useOrg();
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 hidden h-screen w-64 shrink-0 flex-col border-r bg-sidebar lg:flex">
        <OrgHeader />
        <SidebarNav />
      </aside>

      <Sheet open={mobileOpen} onOpenChange={setMobileOpen}>
        <SheetContent title={t("nav.openMenu")}>
          <OrgHeader />
          <SidebarNav onNavigate={() => setMobileOpen(false)} />
        </SheetContent>
      </Sheet>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-30 flex h-14 items-center gap-2 border-b bg-card/95 px-4 backdrop-blur">
          <Button variant="ghost" size="icon" className="lg:hidden" onClick={() => setMobileOpen(true)} aria-label={t("nav.openMenu")}>
            <Menu />
          </Button>
          <Link to={`/app/${org.slug}`} className="truncate text-sm font-semibold lg:hidden">
            {org.name}
          </Link>
          <div className="ml-auto flex items-center gap-2">
            <LanguageSwitcher />
            <UserMenu />
          </div>
        </header>
        <SubscriptionBanner />
        <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-6 sm:px-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
