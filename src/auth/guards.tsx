import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router-dom";
import { useAuth } from "./AuthProvider";
import { useOrg } from "./OrgProvider";
import type { Permission } from "@/lib/types";
import { LoadingScreen } from "@/components/states/LoadingScreen";
import { ForbiddenState } from "@/components/states/ErrorState";

/** Только для вошедших пользователей с подтверждённой почтой */
export function RequireAuth({ children }: { children: ReactNode }) {
  const { user, loading } = useAuth();
  const location = useLocation();
  if (loading) return <LoadingScreen />;
  if (!user) return <Navigate to="/login" replace state={{ from: location.pathname + location.search }} />;
  if (!user.email_confirmed_at) return <Navigate to="/verify-email" replace state={{ email: user.email }} />;
  return <>{children}</>;
}

/** Скрывает раздел без нужного права. Это удобство интерфейса; данные защищает RLS на сервере. */
export function RequirePermission({ permission, children }: { permission: Permission; children: ReactNode }) {
  const { can, org } = useOrg();
  if (!can(permission)) return <ForbiddenState homeTo={`/app/${org.slug}`} />;
  return <>{children}</>;
}
