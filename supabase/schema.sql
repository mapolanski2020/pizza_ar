-- =====================================================================
-- Monte a Pizza · CRM de fidelidade com jogo AR
-- Banco de dados para Supabase (Postgres). Rode este arquivo inteiro no
-- SQL Editor do Supabase. Pode rodar de novo: ele recria tudo do zero
-- (apaga os dados de teste).
-- =====================================================================

create extension if not exists pgcrypto;

drop schema if exists crm cascade;
create schema crm;

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------

-- Pizzarias clientes da plataforma
create table crm.pizzerias (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  prefix       text not null unique check (prefix ~ '^[A-Z]{3}$'),
  join_code    text not null unique default upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 8)),
  reward_goal  int  not null default 10 check (reward_goal between 2 and 50),
  created_at   timestamptz not null default now()
);

-- Equipe da pizzaria (usuários do painel)
create table crm.staff (
  user_id      uuid primary key,
  pizzeria_id  uuid not null references crm.pizzerias(id) on delete cascade,
  name         text not null,
  role         text not null default 'atendente' check (role in ('dono', 'atendente')),
  created_at   timestamptz not null default now()
);

-- Clientes: um cadastro por celular em cada pizzaria
create table crm.customers (
  id               uuid primary key default gen_random_uuid(),
  pizzeria_id      uuid not null references crm.pizzerias(id) on delete cascade,
  phone            text not null check (phone ~ '^[0-9]{10,11}$'),
  name             text not null check (length(name) between 2 and 60),
  secret           uuid not null default gen_random_uuid(),
  points           int  not null default 0,
  total_orders     int  not null default 0,
  rewards_redeemed int  not null default 0,
  best_level       int  not null default 0,
  created_at       timestamptz not null default now(),
  last_order_at    timestamptz,
  unique (pizzeria_id, phone),
  unique (secret)
);

-- Lotes de adesivos impressos
create table crm.sticker_batches (
  id           uuid primary key default gen_random_uuid(),
  pizzeria_id  uuid not null references crm.pizzerias(id) on delete cascade,
  label        text not null,
  qty          int  not null,
  first_serial int  not null,
  last_serial  int  not null,
  created_by   uuid,
  created_at   timestamptz not null default now()
);

-- Adesivos: cada um vale 1 pizza comprovada, uma única vez
create table crm.stickers (
  token        text primary key,
  pizzeria_id  uuid not null references crm.pizzerias(id) on delete cascade,
  batch_id     uuid not null references crm.sticker_batches(id) on delete cascade,
  serial       int  not null,
  status       text not null default 'novo' check (status in ('novo', 'usado', 'cancelado')),
  customer_id  uuid references crm.customers(id) on delete set null,
  claimed_at   timestamptz,
  unique (pizzeria_id, serial)
);
create index on crm.stickers (customer_id);
create index on crm.stickers (batch_id);

-- Pizzas grátis entregues
create table crm.rewards (
  id           uuid primary key default gen_random_uuid(),
  pizzeria_id  uuid not null references crm.pizzerias(id) on delete cascade,
  customer_id  uuid not null references crm.customers(id) on delete cascade,
  points_used  int  not null,
  staff_id     uuid,
  staff_name   text,
  note         text,
  created_at   timestamptz not null default now()
);

-- Registro de tudo o que acontece (comprovação e auditoria)
create table crm.events (
  id           bigserial primary key,
  pizzeria_id  uuid not null references crm.pizzerias(id) on delete cascade,
  customer_id  uuid references crm.customers(id) on delete set null,
  kind         text not null,
  sticker_serial int,
  phone        text,
  detail       jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index on crm.events (pizzeria_id, created_at desc);
create index on crm.events (customer_id);

-- ---------------------------------------------------------------------
-- Funções auxiliares
-- ---------------------------------------------------------------------

-- Código aleatório do adesivo (sem letras que se confundem)
create or replace function crm.gen_token() returns text
language plpgsql volatile as $$
declare
  alphabet text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  bytes bytea := gen_random_bytes(12);
  out text := '';
begin
  for i in 0..11 loop
    out := out || substr(alphabet, (get_byte(bytes, i) % 32) + 1, 1);
  end loop;
  return out;
end $$;

-- Pizzaria de quem está logado no painel
create or replace function crm.my_pizzeria() returns uuid
language sql stable security definer set search_path = crm, public as $$
  select pizzeria_id from crm.staff where user_id = auth.uid()
$$;

create or replace function crm.clean_phone(p text) returns text
language sql immutable as $$ select regexp_replace(coalesce(p, ''), '\D', '', 'g') $$;

-- Fases liberadas: sem compra joga a fase 1; cada pizza comprovada libera a próxima
create or replace function crm.unlocked_levels(total int) returns int
language sql immutable as $$ select least(10, greatest(1, coalesce(total, 0) + 1)) $$;

-- ---------------------------------------------------------------------
-- Funções públicas do jogo (qualquer pessoa com o link pode chamar)
-- ---------------------------------------------------------------------

-- O que é este adesivo?
create or replace function public.game_sticker_info(p_token text, p_secret uuid default null)
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare
  s crm.stickers; pz crm.pizzerias; me crm.customers;
begin
  select * into s from crm.stickers where token = upper(trim(p_token));
  if not found then return json_build_object('status', 'invalido'); end if;
  select * into pz from crm.pizzerias where id = s.pizzeria_id;
  if p_secret is not null then
    select * into me from crm.customers where secret = p_secret and pizzeria_id = s.pizzeria_id;
  end if;
  return json_build_object(
    'status', case when s.status = 'usado' and me.id is not null and s.customer_id = me.id then 'seu' else s.status end,
    'pizzeria', pz.name, 'serial', s.serial, 'reward_goal', pz.reward_goal);
end $$;

-- Registrar a pizza: o primeiro celular que usa o adesivo ganha o ponto
create or replace function public.game_claim(p_token text, p_phone text, p_name text)
returns json language plpgsql volatile security definer set search_path = crm, public as $$
declare
  s crm.stickers; pz crm.pizzerias; c crm.customers;
  ph text := crm.clean_phone(p_phone);
  nm text := left(trim(coalesce(p_name, '')), 60);
  recent int;
begin
  select * into s from crm.stickers where token = upper(trim(p_token)) for update;
  if not found then return json_build_object('ok', false, 'reason', 'invalido'); end if;
  select * into pz from crm.pizzerias where id = s.pizzeria_id;

  if s.status = 'cancelado' then return json_build_object('ok', false, 'reason', 'cancelado', 'pizzeria', pz.name); end if;
  if ph !~ '^[0-9]{10,11}$' then return json_build_object('ok', false, 'reason', 'telefone'); end if;
  if length(nm) < 2 then return json_build_object('ok', false, 'reason', 'nome'); end if;

  if s.status = 'usado' then
    select * into c from crm.customers where id = s.customer_id;
    if c.phone = ph then
      return json_build_object('ok', true, 'reason', 'ja_registrado', 'secret', c.secret, 'name', c.name, 'pizzeria', pz.name,
        'points', c.points, 'total_orders', c.total_orders, 'unlocked', crm.unlocked_levels(c.total_orders), 'reward_goal', pz.reward_goal);
    end if;
    insert into crm.events (pizzeria_id, kind, sticker_serial, phone, detail)
      values (pz.id, 'reuso_bloqueado', s.serial, ph, json_build_object('dono_do_adesivo', c.id)::jsonb);
    return json_build_object('ok', false, 'reason', 'usado', 'pizzeria', pz.name);
  end if;

  -- Limite contra uso em massa: no máximo 6 adesivos por celular a cada hora
  -- (cobre um pedido grande de família, mas barra quem tenta registrar um rolo inteiro)
  select count(*) into recent from crm.events
   where pizzeria_id = pz.id and phone = ph and kind = 'ponto' and created_at > now() - interval '1 hour';
  if recent >= 6 then
    insert into crm.events (pizzeria_id, kind, sticker_serial, phone) values (pz.id, 'limite', s.serial, ph);
    return json_build_object('ok', false, 'reason', 'limite', 'pizzeria', pz.name);
  end if;

  insert into crm.customers (pizzeria_id, phone, name) values (pz.id, ph, nm)
    on conflict (pizzeria_id, phone) do nothing;
  update crm.customers set points = points + 1, total_orders = total_orders + 1, last_order_at = now()
   where pizzeria_id = pz.id and phone = ph returning * into c;

  update crm.stickers set status = 'usado', customer_id = c.id, claimed_at = now() where token = s.token;
  insert into crm.events (pizzeria_id, customer_id, kind, sticker_serial, phone, detail)
    values (pz.id, c.id, 'ponto', s.serial, ph, json_build_object('pontos', c.points, 'pizzas', c.total_orders)::jsonb);

  return json_build_object('ok', true, 'reason', 'novo', 'secret', c.secret, 'name', c.name, 'pizzeria', pz.name,
    'points', c.points, 'total_orders', c.total_orders, 'unlocked', crm.unlocked_levels(c.total_orders),
    'reward_goal', pz.reward_goal, 'reward_ready', c.points >= pz.reward_goal);
end $$;

-- Progresso do jogador (só com a chave secreta guardada no celular dele)
create or replace function public.game_progress(p_secret uuid)
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare c crm.customers; pz crm.pizzerias;
begin
  select * into c from crm.customers where secret = p_secret;
  if not found then return json_build_object('ok', false); end if;
  select * into pz from crm.pizzerias where id = c.pizzeria_id;
  return json_build_object('ok', true, 'name', c.name, 'pizzeria', pz.name, 'points', c.points,
    'total_orders', c.total_orders, 'unlocked', crm.unlocked_levels(c.total_orders),
    'reward_goal', pz.reward_goal, 'reward_ready', c.points >= pz.reward_goal, 'best_level', c.best_level);
end $$;

-- Guarda a maior fase vencida (só informativo; não vale ponto)
create or replace function public.game_level_done(p_secret uuid, p_level int)
returns void language sql volatile security definer set search_path = crm, public as $$
  update crm.customers set best_level = greatest(best_level, least(p_level, crm.unlocked_levels(total_orders)))
   where secret = p_secret
$$;

-- ---------------------------------------------------------------------
-- Funções do painel (só para a equipe logada)
-- ---------------------------------------------------------------------

-- Entrar na equipe de uma pizzaria com o código dela
create or replace function public.staff_join(p_code text, p_name text)
returns json language plpgsql volatile security definer set search_path = crm, public as $$
declare pz crm.pizzerias; is_first boolean;
begin
  if auth.uid() is null then raise exception 'Faça login primeiro'; end if;
  if exists (select 1 from crm.staff where user_id = auth.uid()) then
    return json_build_object('ok', true, 'already', true);
  end if;
  select * into pz from crm.pizzerias where join_code = upper(trim(p_code));
  if not found then return json_build_object('ok', false, 'reason', 'codigo'); end if;
  is_first := not exists (select 1 from crm.staff where pizzeria_id = pz.id);
  insert into crm.staff (user_id, pizzeria_id, name, role)
    values (auth.uid(), pz.id, left(trim(coalesce(p_name, 'Equipe')), 60), case when is_first then 'dono' else 'atendente' end);
  return json_build_object('ok', true, 'pizzeria', pz.name);
end $$;

-- Quem sou eu no painel
create or replace function public.staff_me()
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare st crm.staff; pz crm.pizzerias;
begin
  select * into st from crm.staff where user_id = auth.uid();
  if not found then return json_build_object('ok', false); end if;
  select * into pz from crm.pizzerias where id = st.pizzeria_id;
  return json_build_object('ok', true, 'name', st.name, 'role', st.role, 'pizzeria', pz.name, 'prefix', pz.prefix,
    'join_code', case when st.role = 'dono' then pz.join_code else null end, 'reward_goal', pz.reward_goal);
end $$;

-- Gerar um lote de adesivos numerados
create or replace function public.staff_create_batch(p_qty int, p_label text)
returns table (token text, serial int) language plpgsql volatile security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria(); start_serial int; b uuid; i int; t text;
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Quantidade entre 1 e 1000'; end if;
  perform 1 from crm.pizzerias where id = pid for update;
  select coalesce(max(s.serial), 0) + 1 into start_serial from crm.stickers s where s.pizzeria_id = pid;
  insert into crm.sticker_batches (pizzeria_id, label, qty, first_serial, last_serial, created_by)
    values (pid, coalesce(nullif(trim(p_label), ''), 'Lote'), p_qty, start_serial, start_serial + p_qty - 1, auth.uid())
    returning id into b;
  for i in 0..p_qty - 1 loop
    loop
      t := crm.gen_token();
      exit when not exists (select 1 from crm.stickers where crm.stickers.token = t);
    end loop;
    insert into crm.stickers (token, pizzeria_id, batch_id, serial) values (t, pid, b, start_serial + i);
  end loop;
  insert into crm.events (pizzeria_id, kind, detail) values (pid, 'lote', json_build_object('qtd', p_qty, 'de', start_serial, 'ate', start_serial + p_qty - 1)::jsonb);
  return query select s.token, s.serial from crm.stickers s where s.batch_id = b order by s.serial;
end $$;

-- Reimprimir um lote
create or replace function public.staff_batch_stickers(p_batch uuid)
returns table (token text, serial int, status text) language sql stable security definer set search_path = crm, public as $$
  select s.token, s.serial, s.status from crm.stickers s
   where s.batch_id = p_batch and s.pizzeria_id = crm.my_pizzeria() order by s.serial
$$;

-- Cancelar adesivo perdido ou extraviado
create or replace function public.staff_cancel_sticker(p_serial int)
returns json language plpgsql volatile security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria(); s crm.stickers;
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  select * into s from crm.stickers where pizzeria_id = pid and serial = p_serial for update;
  if not found then return json_build_object('ok', false, 'reason', 'nao_encontrado'); end if;
  if s.status <> 'novo' then return json_build_object('ok', false, 'reason', s.status); end if;
  update crm.stickers set status = 'cancelado' where token = s.token;
  insert into crm.events (pizzeria_id, kind, sticker_serial) values (pid, 'cancelado', p_serial);
  return json_build_object('ok', true);
end $$;

-- Entregar a pizza grátis
create or replace function public.staff_redeem(p_customer uuid, p_note text default null)
returns json language plpgsql volatile security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria(); c crm.customers; pz crm.pizzerias; st crm.staff;
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  select * into pz from crm.pizzerias where id = pid;
  select * into st from crm.staff where user_id = auth.uid();
  select * into c from crm.customers where id = p_customer and pizzeria_id = pid for update;
  if not found then return json_build_object('ok', false, 'reason', 'nao_encontrado'); end if;
  if c.points < pz.reward_goal then return json_build_object('ok', false, 'reason', 'pontos'); end if;
  update crm.customers set points = points - pz.reward_goal, rewards_redeemed = rewards_redeemed + 1 where id = c.id;
  insert into crm.rewards (pizzeria_id, customer_id, points_used, staff_id, staff_name, note)
    values (pid, c.id, pz.reward_goal, auth.uid(), st.name, nullif(trim(p_note), ''));
  insert into crm.events (pizzeria_id, customer_id, kind, phone, detail)
    values (pid, c.id, 'resgate', c.phone, json_build_object('atendente', st.name)::jsonb);
  return json_build_object('ok', true);
end $$;

-- Números do painel
create or replace function public.staff_overview()
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria();
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  return json_build_object(
    'customers',      (select count(*) from crm.customers where pizzeria_id = pid),
    'orders',         (select coalesce(sum(total_orders), 0) from crm.customers where pizzeria_id = pid),
    'open_points',    (select coalesce(sum(points), 0) from crm.customers where pizzeria_id = pid),
    'ready',          (select count(*) from crm.customers c join crm.pizzerias p on p.id = c.pizzeria_id where c.pizzeria_id = pid and c.points >= p.reward_goal),
    'rewards',        (select count(*) from crm.rewards where pizzeria_id = pid),
    'stickers_new',   (select count(*) from crm.stickers where pizzeria_id = pid and status = 'novo'),
    'stickers_used',  (select count(*) from crm.stickers where pizzeria_id = pid and status = 'usado'),
    'stickers_void',  (select count(*) from crm.stickers where pizzeria_id = pid and status = 'cancelado'),
    'blocked_7d',     (select count(*) from crm.events where pizzeria_id = pid and kind in ('reuso_bloqueado', 'limite') and created_at > now() - interval '7 days'),
    'daily', (select coalesce(json_agg(json_build_object('day', d::date, 'n', coalesce(n, 0)) order by d), '[]'::json)
                from generate_series(current_date - 13, current_date, interval '1 day') d
                left join (select claimed_at::date as day, count(*) n from crm.stickers
                            where pizzeria_id = pid and status = 'usado' and claimed_at > current_date - 14 group by 1) x on x.day = d::date)
  );
end $$;

-- Lista de clientes (com busca por nome ou celular)
create or replace function public.staff_customers(p_search text default '')
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria(); q text := trim(coalesce(p_search, ''));
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  return coalesce((select json_agg(x) from (
    select c.id, c.name, c.phone, c.points, c.total_orders, c.rewards_redeemed, c.best_level, c.created_at, c.last_order_at
      from crm.customers c
     where c.pizzeria_id = pid
       and (q = '' or c.name ilike '%' || q || '%' or c.phone like '%' || crm.clean_phone(q) || '%' and crm.clean_phone(q) <> '')
     order by c.last_order_at desc nulls last limit 500) x), '[]'::json);
end $$;

-- Ficha do cliente: cada pizza comprovada (adesivo, data e hora) e cada resgate
create or replace function public.staff_customer(p_id uuid)
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria(); c crm.customers;
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  select * into c from crm.customers where id = p_id and pizzeria_id = pid;
  if not found then return json_build_object('ok', false); end if;
  return json_build_object('ok', true,
    'customer', row_to_json(c)::jsonb - 'secret',
    'orders', coalesce((select json_agg(json_build_object('serial', s.serial, 'claimed_at', s.claimed_at, 'batch', b.label) order by s.claimed_at desc)
                 from crm.stickers s join crm.sticker_batches b on b.id = s.batch_id where s.customer_id = c.id), '[]'::json),
    'rewards', coalesce((select json_agg(json_build_object('created_at', r.created_at, 'staff', r.staff_name, 'note', r.note, 'points', r.points_used) order by r.created_at desc)
                 from crm.rewards r where r.customer_id = c.id), '[]'::json),
    'blocked', (select count(*) from crm.events e where e.pizzeria_id = pid and e.phone = c.phone and e.kind in ('reuso_bloqueado', 'limite')));
end $$;

-- Lotes de adesivos com contagem por situação
create or replace function public.staff_batches()
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria();
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select b.id, b.label, b.qty, b.first_serial, b.last_serial, b.created_at,
      (select count(*) from crm.stickers s where s.batch_id = b.id and s.status = 'novo') as novos,
      (select count(*) from crm.stickers s where s.batch_id = b.id and s.status = 'usado') as usados,
      (select count(*) from crm.stickers s where s.batch_id = b.id and s.status = 'cancelado') as cancelados
    from crm.sticker_batches b where b.pizzeria_id = pid) x), '[]'::json);
end $$;

-- Pizzas grátis entregues
create or replace function public.staff_rewards()
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria();
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  return coalesce((select json_agg(json_build_object('created_at', r.created_at, 'customer', c.name, 'phone', c.phone,
      'customer_id', c.id, 'staff', r.staff_name, 'note', r.note) order by r.created_at desc)
    from crm.rewards r join crm.customers c on c.id = r.customer_id where r.pizzeria_id = pid), '[]'::json);
end $$;

-- Atividade recente
create or replace function public.staff_events(p_limit int default 40)
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria();
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  return coalesce((select json_agg(x) from (
    select e.kind, e.sticker_serial, e.phone, e.detail, e.created_at, c.name as customer, c.id as customer_id
      from crm.events e left join crm.customers c on c.id = e.customer_id
     where e.pizzeria_id = pid order by e.created_at desc limit least(greatest(p_limit, 1), 200)) x), '[]'::json);
end $$;

-- Equipe
create or replace function public.staff_team()
returns json language plpgsql stable security definer set search_path = crm, public as $$
declare pid uuid := crm.my_pizzeria();
begin
  if pid is null then raise exception 'Sem acesso'; end if;
  return coalesce((select json_agg(json_build_object('name', s.name, 'role', s.role, 'created_at', s.created_at) order by s.created_at)
    from crm.staff s where s.pizzeria_id = pid), '[]'::json);
end $$;

-- ---------------------------------------------------------------------
-- Segurança: ninguém lê nem altera tabelas direto, exceto a própria equipe
-- lendo os dados da sua pizzaria. Toda escrita passa pelas funções acima.
-- ---------------------------------------------------------------------
alter table crm.pizzerias       enable row level security;
alter table crm.staff           enable row level security;
alter table crm.customers       enable row level security;
alter table crm.sticker_batches enable row level security;
alter table crm.stickers        enable row level security;
alter table crm.rewards         enable row level security;
alter table crm.events          enable row level security;

create policy le_propria on crm.pizzerias       for select to authenticated using (id = crm.my_pizzeria());
create policy le_propria on crm.staff           for select to authenticated using (pizzeria_id = crm.my_pizzeria());
create policy le_propria on crm.customers       for select to authenticated using (pizzeria_id = crm.my_pizzeria());
create policy le_propria on crm.sticker_batches for select to authenticated using (pizzeria_id = crm.my_pizzeria());
create policy le_propria on crm.stickers        for select to authenticated using (pizzeria_id = crm.my_pizzeria());
create policy le_propria on crm.rewards         for select to authenticated using (pizzeria_id = crm.my_pizzeria());
create policy le_propria on crm.events          for select to authenticated using (pizzeria_id = crm.my_pizzeria());

grant usage on schema crm to authenticated;
grant select on all tables in schema crm to authenticated;
revoke all on all tables in schema crm from anon;

revoke execute on all functions in schema public from public;
grant execute on function public.game_sticker_info(text, uuid), public.game_claim(text, text, text),
  public.game_progress(uuid), public.game_level_done(uuid, int) to anon, authenticated;
grant execute on function public.staff_join(text, text), public.staff_me(), public.staff_create_batch(int, text),
  public.staff_batch_stickers(uuid), public.staff_cancel_sticker(int), public.staff_redeem(uuid, text),
  public.staff_overview(), public.staff_customers(text), public.staff_customer(uuid), public.staff_batches(),
  public.staff_rewards(), public.staff_events(int), public.staff_team() to authenticated;

-- ---------------------------------------------------------------------
-- Primeira pizzaria (troque o nome e as 3 letras). O resultado mostra o
-- código de equipe que o dono usa no primeiro acesso ao painel.
-- ---------------------------------------------------------------------
insert into crm.pizzerias (name, prefix) values ('Forno a Lenha', 'FAL')
returning name, prefix, join_code as codigo_da_equipe;
