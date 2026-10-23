export function Logo({ compact = false }: { compact?: boolean }) {
  return (
    <span className="inline-flex items-center gap-2 font-semibold">
      <img src="/favicon.svg" alt="" className="h-7 w-7" />
      {!compact && <span>Sanatorium OS</span>}
    </span>
  );
}
