import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import { Toaster } from "sonner";
import { isSupabaseConfigured } from "@/lib/supabase";
import { AuthProvider } from "@/auth/AuthProvider";
import { OrgProvider } from "@/auth/OrgProvider";
import { RequireAuth, RequirePermission } from "@/auth/guards";
import { AppLayout } from "@/layouts/AppLayout";
import { NAV_SECTIONS } from "@/layouts/navigation";
import { LandingPage } from "@/pages/LandingPage";
import { LoginPage } from "@/pages/auth/LoginPage";
import { RegisterPage } from "@/pages/auth/RegisterPage";
import { VerifyEmailPage } from "@/pages/auth/VerifyEmailPage";
import { ForgotPasswordPage } from "@/pages/auth/ForgotPasswordPage";
import { ResetPasswordPage } from "@/pages/auth/ResetPasswordPage";
import { OnboardingPage } from "@/pages/OnboardingPage";
import { SelectOrgPage } from "@/pages/SelectOrgPage";
import { AcceptInvitePage } from "@/pages/AcceptInvitePage";
import { AccountPage } from "@/pages/AccountPage";
import { DashboardPage } from "@/pages/app/DashboardPage";
import { SettingsPage } from "@/pages/app/SettingsPage";
import { StaffPage } from "@/pages/app/StaffPage";
import { ModuleSoonPage } from "@/pages/app/ModuleSoonPage";
import { RoomsPage } from "@/pages/app/RoomsPage";
import { GuestsPage } from "@/pages/app/GuestsPage";
import { BookingsPage } from "@/pages/app/BookingsPage";
import { CalendarPage } from "@/pages/app/CalendarPage";
import { FinancePage } from "@/pages/app/FinancePage";
import { ProceduresPage } from "@/pages/app/ProceduresPage";
import { TasksPage } from "@/pages/app/TasksPage";
import { AuditPage } from "@/pages/app/AuditPage";
import { AnalyticsPage } from "@/pages/app/AnalyticsPage";
import { InventoryPage } from "@/pages/app/InventoryPage";
import { MarketingPage } from "@/pages/app/MarketingPage";
import { BillingPage } from "@/pages/app/BillingPage";
import { MessagesPage } from "@/pages/app/MessagesPage";
import { LeadsPage } from "@/pages/app/LeadsPage";
import { MedicalCardPage, MedicalPage } from "@/pages/app/MedicalPage";
import { KitchenPage } from "@/pages/app/KitchenPage";
import { BookingDocumentPage, MedicalExtractPage } from "@/pages/print/PrintPages";
import { PublicSanatoriumPage } from "@/pages/public/PublicSanatoriumPage";
import { ReviewPage } from "@/pages/public/ReviewPage";
import { AdminPage } from "@/pages/admin/AdminPage";
import { NotFoundState } from "@/components/states/ErrorState";

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, staleTime: 30_000, refetchOnWindowFocus: false } },
});

/** Модули, которые появятся на следующих этапах: честные заглушки вместо фиктивных экранов */
const upcomingModules = NAV_SECTIONS.flatMap((s) => s.items).filter((i) => i.stage);

function ConfigMissing() {
  const { t } = useTranslation();
  return (
    <div className="mx-auto max-w-lg px-4 py-24 text-center">
      <h1 className="text-xl font-semibold">{t("config.missingTitle")}</h1>
      <p className="mt-2 text-sm text-muted-foreground">{t("config.missingText")}</p>
    </div>
  );
}

export default function App() {
  if (!isSupabaseConfigured) return <ConfigMissing />;
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter basename={import.meta.env.BASE_URL.replace(/\/$/, "")}>
          <Routes>
            <Route path="/" element={<LandingPage />} />
            <Route path="/s/:slug" element={<PublicSanatoriumPage />} />
            <Route path="/review/:token" element={<ReviewPage />} />
            <Route path="/login" element={<LoginPage />} />
            <Route path="/register" element={<RegisterPage />} />
            <Route path="/verify-email" element={<VerifyEmailPage />} />
            <Route path="/forgot-password" element={<ForgotPasswordPage />} />
            <Route path="/reset-password" element={<ResetPasswordPage />} />
            <Route path="/invite/:token" element={<AcceptInvitePage />} />

            <Route path="/onboarding" element={<RequireAuth><OnboardingPage /></RequireAuth>} />
            <Route path="/select-org" element={<RequireAuth><SelectOrgPage /></RequireAuth>} />
            <Route path="/account" element={<RequireAuth><AccountPage /></RequireAuth>} />
            <Route path="/admin" element={<RequireAuth><AdminPage /></RequireAuth>} />

            <Route path="/app/:orgSlug/print/medical/:guestId" element={<RequireAuth><OrgProvider><RequirePermission permission="medical.read"><MedicalExtractPage /></RequirePermission></OrgProvider></RequireAuth>} />
            <Route path="/app/:orgSlug/print/:kind/:bookingId" element={<RequireAuth><OrgProvider><BookingDocumentPage /></OrgProvider></RequireAuth>} />
            <Route path="/app/:orgSlug" element={<RequireAuth><OrgProvider><AppLayout /></OrgProvider></RequireAuth>}>
              <Route index element={<DashboardPage />} />
              <Route path="settings" element={<RequirePermission permission="settings.manage"><SettingsPage /></RequirePermission>} />
              <Route path="staff" element={<RequirePermission permission="members.read"><StaffPage /></RequirePermission>} />
              <Route path="bookings" element={<RequirePermission permission="bookings.read"><BookingsPage /></RequirePermission>} />
              <Route path="calendar" element={<RequirePermission permission="bookings.read"><CalendarPage /></RequirePermission>} />
              <Route path="rooms" element={<RequirePermission permission="rooms.read"><RoomsPage /></RequirePermission>} />
              <Route path="finance" element={<RequirePermission permission="finance.read"><FinancePage /></RequirePermission>} />
              <Route path="guests" element={<RequirePermission permission="guests.read"><GuestsPage /></RequirePermission>} />
              <Route path="procedures" element={<RequirePermission permission="procedures.read"><ProceduresPage /></RequirePermission>} />
              <Route path="medical" element={<RequirePermission permission="medical.read"><MedicalPage /></RequirePermission>} />
              <Route path="medical/:guestId" element={<RequirePermission permission="medical.read"><MedicalCardPage /></RequirePermission>} />
              <Route path="kitchen" element={<RequirePermission permission="kitchen.read"><KitchenPage /></RequirePermission>} />
              <Route path="tasks" element={<RequirePermission permission="tasks.read"><TasksPage /></RequirePermission>} />
              <Route path="inventory" element={<RequirePermission permission="inventory.read"><InventoryPage /></RequirePermission>} />
              <Route path="leads" element={<RequirePermission permission="leads.read"><LeadsPage /></RequirePermission>} />
              <Route path="messages" element={<RequirePermission permission="messages.read"><MessagesPage /></RequirePermission>} />
              <Route path="marketing" element={<RequirePermission permission="marketing.read"><MarketingPage /></RequirePermission>} />
              <Route path="analytics" element={<RequirePermission permission="reports.read"><AnalyticsPage /></RequirePermission>} />
              <Route path="audit" element={<RequirePermission permission="audit.read"><AuditPage /></RequirePermission>} />
              <Route path="billing" element={<RequirePermission permission="billing.manage"><BillingPage /></RequirePermission>} />
              {upcomingModules.map((m) => (
                <Route
                  key={m.key}
                  path={m.path}
                  element={
                    m.permission ? (
                      <RequirePermission permission={m.permission}><ModuleSoonPage moduleKey={m.key} stage={m.stage!} /></RequirePermission>
                    ) : (
                      <ModuleSoonPage moduleKey={m.key} stage={m.stage!} />
                    )
                  }
                />
              ))}
              <Route path="*" element={<NotFoundState />} />
            </Route>

            <Route path="/app" element={<Navigate to="/select-org" replace />} />
            <Route path="*" element={<NotFoundState />} />
          </Routes>
        </BrowserRouter>
        <Toaster position="top-right" richColors closeButton />
      </AuthProvider>
    </QueryClientProvider>
  );
}
