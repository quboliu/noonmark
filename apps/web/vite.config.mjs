import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { isAbsolute } from 'node:path';

for (const name of ['NOONMARK_WEB_DIST', 'NOONMARK_VITE_CACHE']) {
  if (!process.env[name] || !isAbsolute(process.env[name])) {
    throw new Error(`${name} must be provided by scripts/web`);
  }
}

export default defineConfig({
  plugins: [react()],
  cacheDir: process.env.NOONMARK_VITE_CACHE,
  build: { outDir: process.env.NOONMARK_WEB_DIST, emptyOutDir: true, sourcemap: false },
});
