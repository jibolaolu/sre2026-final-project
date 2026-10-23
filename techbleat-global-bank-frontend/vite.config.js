import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')

  return {
    plugins: [react()],
    server: {
      host: '0.0.0.0',
      port: 3000,
      proxy: {
        '/user-api': {
          target: env.VITE_USER_API_TARGET || 'http://localhost:8180',
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/user-api/, ''),
        },
        '/transaction-api': {
          target: env.VITE_TRANSACTION_API_TARGET || 'http://localhost:8090',
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/transaction-api/, ''),
        },
        '/activity-api': {
          target: env.VITE_ACTIVITY_API_TARGET || 'http://localhost:8001',
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/activity-api/, ''),
        },
        '/finance-agent-api': {
          target: env.VITE_FINANCE_AGENT_API_TARGET || 'http://localhost:9181',
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/finance-agent-api/, ''),
        },
      },
    },
  }
})
