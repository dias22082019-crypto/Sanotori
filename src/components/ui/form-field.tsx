import * as React from "react";
import { Label } from "./label";
import { cn } from "@/lib/utils";

/** Поле формы: подпись, контрол, подсказка и ошибка валидации */
export function FormField(props: {
  id: string;
  label: string;
  error?: string;
  hint?: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={cn("grid gap-1.5", props.className)}>
      <Label htmlFor={props.id}>{props.label}</Label>
      {props.children}
      {props.error ? (
        <p role="alert" className="text-xs text-destructive">{props.error}</p>
      ) : props.hint ? (
        <p className="text-xs text-muted-foreground">{props.hint}</p>
      ) : null}
    </div>
  );
}
