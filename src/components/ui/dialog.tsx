import * as React from "react";
import * as DialogPrimitive from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import { cn } from "@/lib/utils";

/** Модальное окно с формой (создание и редактирование записей) */
export function Dialog(props: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <DialogPrimitive.Root open={props.open} onOpenChange={props.onOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="fixed inset-0 z-50 bg-black/40 data-[state=open]:animate-in data-[state=open]:fade-in-0" />
        <DialogPrimitive.Content
          className={cn(
            "fixed left-1/2 top-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-lg -translate-x-1/2 -translate-y-1/2 flex-col rounded-lg border bg-card shadow-lg",
            props.className,
          )}
        >
          <div className="border-b px-5 py-4 pr-12">
            <DialogPrimitive.Title className="text-base font-semibold">{props.title}</DialogPrimitive.Title>
            <DialogPrimitive.Description className={props.description ? "mt-1 text-sm text-muted-foreground" : "sr-only"}>
              {props.description ?? props.title}
            </DialogPrimitive.Description>
          </div>
          <div className="overflow-y-auto px-5 py-4">{props.children}</div>
          <DialogPrimitive.Close className="absolute right-3 top-3 rounded-sm p-1 opacity-70 hover:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring">
            <X className="h-4 w-4" />
            <span className="sr-only">Close</span>
          </DialogPrimitive.Close>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}

/** Нижняя панель кнопок формы в диалоге */
export function DialogFooter({ children }: { children: React.ReactNode }) {
  return <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">{children}</div>;
}
