// =====================================================================
// Monte a Pizza · servidor local
// Substitui a nuvem (Supabase) para rodar tudo no seu computador:
// banco de dados, login do painel, regras anti-trapaça e as páginas.
// Uso: npm install  →  npm start
// =====================================================================
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import selfsigned from 'selfsigned';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');                 // pasta com index.html e painel.html
const DATA = path.join(HERE, 'dados');                 // banco e chaves ficam aqui
const PORT = Number(process.env.PORT || 8443);
fs.mkdirSync(DATA, { recursive: true });

/* ---------- Endereço na rede (para o celular) ---------- */
function lanIPs(){
  const out = [];
  for(const list of Object.values(os.networkInterfaces())) for(const a of list || [])
    if(a.family === 'IPv4' && !a.internal) out.push(a.address);
  return out;
}
const IPS = lanIPs();
const IN_DOCKER = !!process.env.DATABASE_URL;
const LAN = process.env.HOST_IP || (IN_DOCKER ? 'localhost' : (IPS.find(ip => ip.startsWith('192.168.')) || IPS[0] || 'localhost'));
// Endereço que vai dentro dos QR Codes. No Docker sem HOST_IP, usa o endereço pelo qual o painel foi aberto.
const FIXED_GAME = (process.env.HOST_IP || !IN_DOCKER) ? `https://${LAN}:${PORT}/` : null;
const CERT_IPS = [...new Set([...(process.env.HOST_IP ? [process.env.HOST_IP] : []), ...IPS])];

/* ---------- Certificado HTTPS (o celular só libera a câmera em https) ---------- */
const certFile = path.join(DATA, 'certificado.json');
let cert = fs.existsSync(certFile) ? JSON.parse(fs.readFileSync(certFile, 'utf8')) : null;
if(!cert || cert.ip !== LAN || cert.ips !== CERT_IPS.join(',')){
  const pems = await selfsigned.generate([{ name:'commonName', value:'Monte a Pizza local' }], {
    days:825, keySize:2048, algorithm:'sha256',
    extensions:[{ name:'subjectAltName', altNames:[{ type:2, value:'localhost' }, { type:7, ip:'127.0.0.1' }, ...CERT_IPS.map(ip => ({ type:7, ip }))] }]
  });
  cert = { ip:LAN, ips:CERT_IPS.join(','), key:pems.private, cert:pems.cert };
  fs.writeFileSync(certFile, JSON.stringify(cert));
}

/* ---------- Banco de dados ----------
   Com DATABASE_URL (Docker): PostgreSQL de verdade.
   Sem DATABASE_URL: Postgres embutido, gravado em ./dados/banco. */
let DB;
if(IN_DOCKER){
  const pg = (await import('pg')).default;
  const pool = new pg.Pool({ connectionString:process.env.DATABASE_URL, max:10 });
  for(let i = 0; ; i++){ try{ await pool.query('select 1'); break; }catch(e){ if(i > 30) throw e; console.log('Aguardando o banco de dados…'); await new Promise(r => setTimeout(r, 2000)); } }
  DB = {
    query:(sql, params) => pool.query(sql, params),
    exec:async sql => { const r = await pool.query(sql); return Array.isArray(r) ? r : [r]; },
    asRole:async (uid, fn) => {
      const c = await pool.connect();
      try{
        await c.query('begin');
        await c.query(`set local role ${uid ? 'authenticated' : 'anon'}`);
        await c.query(`select set_config('app.uid', $1, true)`, [uid || '']);
        const out = await fn((sql, params) => c.query(sql, params));
        await c.query('commit'); return out;
      }catch(e){ await c.query('rollback').catch(() => {}); throw e; }
      finally{ c.release(); }
    }
  };
} else {
  const { PGlite } = await import('@electric-sql/pglite');
  const { pgcrypto } = await import('@electric-sql/pglite/contrib/pgcrypto');
  const lite = new PGlite(path.join(DATA, 'banco'), { extensions:{ pgcrypto } });
  await lite.waitReady;
  let chain = Promise.resolve();
  const serial = fn => { const p = chain.then(fn); chain = p.catch(() => {}); return p; };
  DB = {
    query:(sql, params) => serial(() => lite.query(sql, params)),
    exec:sql => serial(() => lite.exec(sql)),
    asRole:(uid, fn) => serial(async () => {
      await lite.exec(`set role ${uid ? 'authenticated' : 'anon'}`);
      await lite.query(`select set_config('app.uid', $1, false)`, [uid || '']);
      try{ return await fn((sql, params) => lite.query(sql, params)); }
      finally{ await lite.exec('reset role'); }
    })
  };
}
const ready = (await DB.query(`select 1 from information_schema.schemata where schema_name = 'crm'`)).rows.length > 0;
let firstCode = null;
if(!ready){
  await DB.exec(`
    do $$ begin
      if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
      if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
    end $$;
    create extension if not exists pgcrypto;
    create schema if not exists auth;
    create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('app.uid', true), '')::uuid $$;
    grant usage on schema auth to anon, authenticated;
    grant execute on function auth.uid() to anon, authenticated;
    create table if not exists auth.local_users (
      id uuid primary key default gen_random_uuid(), email text unique not null, pass text not null,
      refresh text, created_at timestamptz default now());`);
  const res = await DB.exec(fs.readFileSync(path.join(ROOT, 'supabase', 'schema.sql'), 'utf8'));
  firstCode = res[res.length - 1].rows[0];
}

const CODES = (await DB.query(`select name, prefix, join_code from crm.pizzerias order by created_at`)).rows;

/* ---------- Login (senha com scrypt, sessão assinada) ---------- */
const keyFile = path.join(DATA, 'chave.secreta');
if(!fs.existsSync(keyFile)) fs.writeFileSync(keyFile, crypto.randomBytes(32).toString('hex'));
const SECRET = fs.readFileSync(keyFile, 'utf8');
const b64u = b => Buffer.from(b).toString('base64url');
function sign(payload){
  const h = b64u(JSON.stringify({ alg:'HS256', typ:'JWT' })), p = b64u(JSON.stringify(payload));
  return h + '.' + p + '.' + crypto.createHmac('sha256', SECRET).update(h + '.' + p).digest('base64url');
}
function verify(tok){
  try{
    const [h, p, s] = tok.split('.');
    const ok = crypto.timingSafeEqual(Buffer.from(s), Buffer.from(crypto.createHmac('sha256', SECRET).update(h + '.' + p).digest('base64url')));
    const data = JSON.parse(Buffer.from(p, 'base64url'));
    return ok && data.exp > Date.now()/1000 ? data : null;
  }catch(e){ return null; }
}
const hashPass = (pw, salt = crypto.randomBytes(16).toString('hex')) => salt + ':' + crypto.scryptSync(pw, salt, 32).toString('hex');
const checkPass = (pw, stored) => { const [salt] = stored.split(':'); return crypto.timingSafeEqual(Buffer.from(hashPass(pw, salt)), Buffer.from(stored)); };
const DAY = 86400;
function session(u, refresh){
  const exp = Math.floor(Date.now()/1000) + 7*DAY;
  const user = { id:u.id, email:u.email, aud:'authenticated', role:'authenticated', app_metadata:{ provider:'email' }, user_metadata:{}, created_at:u.created_at };
  return { access_token:sign({ sub:u.id, email:u.email, role:'authenticated', aud:'authenticated', exp }), token_type:'bearer', expires_in:7*DAY, expires_at:exp, refresh_token:refresh, user };
}

const SETOF = new Set(['staff_create_batch', 'staff_batch_stickers']);
const ALLOWED = /^(game|staff)_[a-z_]+$/;

async function rpc(fn, args, uid){
  if(!ALLOWED.test(fn)) throw new Error('Função não permitida');
  const keys = Object.keys(args || {}).filter(k => /^p_[a-z_]+$/.test(k));
  const list = keys.map((k, i) => `${k} => $${i + 1}`).join(', ');
  return DB.asRole(uid, async q => {
    if(SETOF.has(fn)) return (await q(`select * from public.${fn}(${list})`, keys.map(k => args[k]))).rows;
    return (await q(`select public.${fn}(${list}) as v`, keys.map(k => args[k]))).rows[0].v;
  });
}

/* ---------- Servidor ---------- */
const TYPES = { '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8', '.mjs':'text/javascript; charset=utf-8', '.png':'image/png', '.glb':'model/gltf-binary', '.mind':'application/octet-stream', '.json':'application/json', '.pdf':'application/pdf', '.css':'text/css' };
const BLOCK = ['/local', '/supabase', '/.git', '/node_modules'];

const server = https.createServer({ key:cert.key, cert:cert.cert }, async (req, res) => {
  const cors = { 'Access-Control-Allow-Origin':'*', 'Access-Control-Allow-Headers':'*', 'Access-Control-Allow-Methods':'GET,POST,PUT,DELETE,OPTIONS' };
  const json = (code, obj) => { res.writeHead(code, { ...cors, 'Content-Type':'application/json' }); res.end(obj === undefined ? '' : JSON.stringify(obj)); };
  if(req.method === 'OPTIONS'){ res.writeHead(204, cors); return res.end(); }
  const url = new URL(req.url, 'https://local');
  let body = ''; for await (const c of req) body += c;
  const data = () => { try{ return body ? JSON.parse(body) : {}; }catch(e){ return {}; } };
  try{
    /* Configuração para as páginas: aponta para este próprio servidor */
    if(url.pathname === '/config.js'){
      res.writeHead(200, { 'Content-Type':'text/javascript; charset=utf-8', 'Cache-Control':'no-store' });
      return res.end(`window.PIZZA_CONFIG={SUPABASE_URL:location.origin,SUPABASE_ANON_KEY:'local',GAME_URL:${FIXED_GAME ? JSON.stringify(FIXED_GAME) : "location.origin+'/'"}};`);
    }
    /* Login */
    if(url.pathname === '/auth/v1/signup'){
      const { email, password } = data();
      if(!email || !password || password.length < 6) return json(422, { msg:'Password should be at least 6 characters', error_code:'weak_password' });
      const ex = await DB.query(`select 1 from auth.local_users where email = lower($1)`, [email]);
      if(ex.rows.length) return json(422, { msg:'User already registered', error_code:'user_already_exists' });
      const refresh = crypto.randomBytes(24).toString('hex');
      const u = (await DB.query(`insert into auth.local_users (email, pass, refresh) values (lower($1), $2, $3) returning *`, [email, hashPass(password), refresh])).rows[0];
      return json(200, session(u, refresh));
    }
    if(url.pathname === '/auth/v1/token'){
      const d = data(), grant = url.searchParams.get('grant_type');
      if(grant === 'refresh_token'){
        const u = (await DB.query(`select * from auth.local_users where refresh = $1`, [d.refresh_token || ''])).rows[0];
        if(!u) return json(400, { error:'invalid_grant', error_description:'Invalid Refresh Token', msg:'Invalid Refresh Token' });
        return json(200, session(u, u.refresh));
      }
      const u = (await DB.query(`select * from auth.local_users where email = lower($1)`, [d.email || ''])).rows[0];
      if(!u || !checkPass(d.password || '', u.pass)) return json(400, { error:'invalid_grant', error_description:'Invalid login credentials', msg:'Invalid login credentials' });
      return json(200, session(u, u.refresh));
    }
    if(url.pathname === '/auth/v1/user'){
      const t = verify((req.headers.authorization || '').replace(/^Bearer /, ''));
      if(!t) return json(401, { msg:'invalid token' });
      return json(200, { id:t.sub, email:t.email, aud:'authenticated', role:'authenticated', app_metadata:{}, user_metadata:{} });
    }
    if(url.pathname === '/auth/v1/logout'){ res.writeHead(204, cors); return res.end(); }
    /* Funções do jogo e do painel */
    if(url.pathname.startsWith('/rest/v1/rpc/')){
      const t = verify((req.headers.authorization || '').replace(/^Bearer /, ''));
      try{
        const v = await rpc(url.pathname.split('/').pop(), data(), t ? t.sub : null);
        return json(200, v === undefined ? null : v);
      }catch(e){ return json(400, { message:e.message, code:'P0001' }); }
    }
    /* Páginas e arquivos */
    let p = decodeURIComponent(url.pathname);
    if(BLOCK.some(b => p.startsWith(b))) return json(404, { message:'not found' });
    if(p.endsWith('/')) p += 'index.html';
    const file = path.normalize(path.join(ROOT, p));
    if(!file.startsWith(ROOT) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return json(404, { message:'not found' });
    res.writeHead(200, { 'Content-Type':TYPES[path.extname(file)] || 'application/octet-stream' });
    return res.end(fs.readFileSync(file));
  }catch(e){ console.error(e); return json(500, { message:'Erro interno' }); }
});

server.listen(PORT, '0.0.0.0', () => {
  const line = '─'.repeat(64);
  console.log('\n' + line + '\n  Monte a Pizza rodando no seu computador\n' + line);
  console.log(`  Painel (neste computador):  https://localhost:${PORT}/painel.html`);
  console.log(`  Painel (outro aparelho):    https://${LAN}:${PORT}/painel.html`);
  console.log(`  Jogo no celular:            https://${LAN}:${PORT}/`);
  if(firstCode) console.log(`\n  Banco criado agora.`);
  for(const pz of CODES) console.log(`  Pizzaria ${pz.name} (${pz.prefix}) · CÓDIGO DA EQUIPE: ${pz.join_code}`);
  console.log(`  ↑ use esse código em "Criar acesso" no painel`);
  console.log(`\n  O navegador vai avisar que o certificado não é confiável:`);
  console.log(`  é normal num servidor local. Toque em "Avançado" / "Mostrar detalhes"`);
  console.log(`  e depois em "Continuar" / "visitar este site".`);
  console.log(`\n  O celular precisa estar no mesmo Wi-Fi deste computador.`);
  console.log(IN_DOCKER ? `  Banco: PostgreSQL no contêiner "db" (porta 5432).\n` + line + '\n' : `  Para parar: Ctrl+C. Os dados ficam em local/dados.\n` + line + '\n');
});
