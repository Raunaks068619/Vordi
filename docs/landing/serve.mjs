import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
const types = { '.html':'text/html', '.css':'text/css', '.js':'text/javascript', '.svg':'image/svg+xml', '.png':'image/png', '.jpg':'image/jpeg' };
const port = process.env.PORT || 4178;
createServer(async (req,res)=>{ const p = req.url==='/'?'/index.html':req.url.split('?')[0]; try { const b = await readFile(join(root,p)); res.writeHead(200,{'content-type':types[extname(p)]||'application/octet-stream'}); res.end(b);} catch { res.writeHead(404); res.end('nf'); } }).listen(port,()=>console.log('landing on :'+port));
