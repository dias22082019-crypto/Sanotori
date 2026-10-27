import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { FileText } from "lucide-react";
import { documentsFor } from "@/lib/documents";
import type { Booking } from "@/lib/bookings";
import { useOrg } from "@/auth/OrgProvider";
import { Button } from "@/components/ui/button";

/** Печать документов по брони. Номер документу присваивает сервер при первой печати. */
export function BookingDocuments({ booking, onNavigate }: { booking: Booking; onNavigate: () => void }) {
  const { t } = useTranslation();
  const { org, can } = useOrg();
  const money = can("finance.read") || can("payments.accept");
  const kinds = documentsFor(booking.status).filter((k) => (k === "contract" ? can("bookings.read") : money));
  if (kinds.length === 0) return null;
  return (
    <div className="mt-4 flex flex-wrap items-center gap-2 border-t pt-4">
      <span className="mr-1 text-sm font-medium">{t("documents.title_short")}</span>
      {kinds.map((k) => (
        <Button key={k} asChild variant="outline" size="sm">
          <Link to={`/app/${org.slug}/print/${k}/${booking.id}`} onClick={onNavigate}><FileText /> {t(`documents.kind.${k}`)}</Link>
        </Button>
      ))}
    </div>
  );
}
