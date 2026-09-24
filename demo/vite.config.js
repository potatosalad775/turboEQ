import { readFileSync } from 'node:fs';
import { defineConfig } from 'vite';

// The page ships turboeq.wasm, and AutoEq's and SciPy's licences travel with
// every copy of it, so the site serves NOTICE beside the bundle.
const notice = () => readFileSync(new URL('../NOTICE', import.meta.url), 'utf8');

export default defineConfig({
	// Relative, so the build works under GitHub Pages' /turboEQ/ prefix.
	base: './',
	// The sample curves are imported straight from tools/parity/real.
	server: { fs: { allow: ['..'] } },
	// The fit runs in a module worker, which loads the wasm the way the page would.
	worker: { format: 'es' },
	plugins: [
		{
			name: 'notice',
			configureServer(server) {
				server.middlewares.use('/NOTICE.txt', (_req, res) => {
					res.setHeader('content-type', 'text/plain; charset=utf-8');
					res.end(notice());
				});
			},
			generateBundle() {
				this.emitFile({ type: 'asset', fileName: 'NOTICE.txt', source: notice() });
			}
		}
	]
});
