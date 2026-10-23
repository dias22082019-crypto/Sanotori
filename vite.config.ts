import { defineConfig } from "vite";
import react from "@vitejs/plugin-react-swc";
import path from "node:path";

// VITE_BASE задаёт подпапку публикации, например /Sanotori/ для GitHub Pages
export default defineConfig({
  base: process.env.VITE_BASE ?? "/",
  server: { host: "::", port: 8080 },
  plugins: [react()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
});
