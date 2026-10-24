import { Star } from "lucide-react";
import { cn } from "@/lib/utils";

/** Оценка звёздами 1–5 (только показ) */
export function Stars({ rating, className }: { rating: number; className?: string }) {
  return (
    <span className={cn("inline-flex gap-0.5", className)} role="img" aria-label={`${rating}/5`}>
      {[1, 2, 3, 4, 5].map((i) => (
        <Star key={i} className={cn("h-4 w-4", i <= rating ? "fill-warning text-warning" : "text-muted-foreground/40")} />
      ))}
    </span>
  );
}
