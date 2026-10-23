import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { LanguageSwitcher } from "@/components/LanguageSwitcher";
import { Logo } from "@/components/Logo";

/** Оформление экранов входа и регистрации */
export function AuthLayout(props: { title: string; subtitle?: string; children: ReactNode; footer?: ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col bg-background">
      <header className="flex items-center justify-between px-4 py-4 sm:px-8">
        <Link to="/"><Logo /></Link>
        <LanguageSwitcher />
      </header>
      <main className="flex flex-1 items-start justify-center px-4 pb-16 pt-6 sm:items-center sm:pt-0">
        <div className="w-full max-w-sm">
          <div className="rounded-lg border bg-card p-6 shadow-sm">
            <h1 className="text-lg font-semibold">{props.title}</h1>
            {props.subtitle && <p className="mt-1 text-sm text-muted-foreground">{props.subtitle}</p>}
            <div className="mt-5">{props.children}</div>
          </div>
          {props.footer && <div className="mt-4 text-center text-sm text-muted-foreground">{props.footer}</div>}
        </div>
      </main>
    </div>
  );
}
