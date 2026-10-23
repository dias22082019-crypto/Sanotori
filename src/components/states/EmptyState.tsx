import type { ReactNode } from "react";

export function EmptyState(props: { icon: ReactNode; title: string; text?: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-center gap-2 rounded-lg border border-dashed bg-card px-6 py-12 text-center">
      <div className="flex h-10 w-10 items-center justify-center rounded-full bg-accent text-accent-foreground">{props.icon}</div>
      <p className="font-medium">{props.title}</p>
      {props.text && <p className="max-w-md text-sm text-muted-foreground">{props.text}</p>}
      {props.action}
    </div>
  );
}
