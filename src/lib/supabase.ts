import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

/** true, если в окружении заданы адрес и публичный ключ Supabase */
export const isSupabaseConfigured = Boolean(url && anonKey);

/**
 * Клиент Supabase. Во фронтенде используется только публичный anon key:
 * все ограничения доступа обеспечивают RLS и серверные функции.
 */
export const supabase: SupabaseClient = createClient(url ?? "http://localhost:54321", anonKey ?? "missing-anon-key", {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});
