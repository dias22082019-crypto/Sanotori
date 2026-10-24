import type { ReactNode } from "react";

export function PageHeader(props: { title: string; description?: string; actions?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <h1 className="text-xl font-semibold tracking-tight sm:text-2xl">{props.title}</h1>
        {props.description && <p className="mt-1 text-sm text-muted-foreground">{props.description}</p>}
      </div>
      {props.actions && <div className="flex flex-wrap gap-2">{props.actions}</div>}
    </div>
  );
}
