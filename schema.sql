-- ============================================================
-- SCHEMA — Sistema de Gestão de Horas Extras (SDU Sul)
-- Estrutura completa do banco (SEM dados), extraída do banco real
-- em produção em 06/08/2026 (projeto Supabase "horas-extras-servidores",
-- org glgabrielleite12-svg).
--
-- Para recriar o sistema do zero num projeto Supabase novo:
--   1) SQL Editor → New query → cole este arquivo inteiro → Run.
--   2) Publique as 2 Edge Functions (ver supabase-functions/COMO-USAR.md).
--   3) Troque SUPABASE_URL e SUPABASE_KEY no index.html pelos do projeto novo.
-- (Isto cria só a estrutura. Para restaurar dados de um backup específico,
-- use o arquivo de backup daquele momento, não este.)
-- ============================================================

create extension if not exists pgcrypto;

-- Necessário porque as funções abaixo referenciam tabelas (ex.: he_perfis)
-- criadas mais adiante neste mesmo script.
set check_function_bodies = off;

-- ---------- FUNÇÕES AUXILIARES (usadas na segurança por perfil / RLS) ----------
create or replace function public.he_meu_papel() returns text language sql stable security definer set search_path to 'public' as $function$
  select papel from public.he_perfis where user_id = auth.uid();
$function$;
create or replace function public.he_meu_servidor() returns uuid language sql stable security definer set search_path to 'public' as $function$
  select servidor_id from public.he_perfis where user_id = auth.uid();
$function$;
create or replace function public.he_minha_secretaria() returns uuid language sql stable security definer set search_path to 'public' as $function$
  select secretaria_id from public.he_perfis where user_id = auth.uid();
$function$;
create or replace function public.he_minhas_chefias() returns setof uuid language sql stable security definer set search_path to 'public' as $function$
  select id from public.he_chefias where responsavel_servidor_id = public.he_meu_servidor();
$function$;
-- Lista pública de setores/chefias (para o seletor do cadastro, ainda deslogado)
create or replace function public.he_chefias_publicas() returns table(id uuid, nome text, sigla text) language sql stable security definer set search_path to 'public' as $function$
  select id, nome, sigla from public.he_chefias where ativo = true order by nome;
$function$;

-- ---------- TABELAS ----------
-- he_secretarias e he_app_chunks existem no banco mas NÃO são usadas pelo
-- index.html atual (resquício de uma versão anterior do modelo de dados).
-- Mantidas aqui só para o schema bater 100% com o banco real; não afetam o
-- funcionamento do sistema.
create table if not exists public.he_secretarias (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  sigla text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
create table if not exists public.he_chefias (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  responsavel_servidor_id uuid,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  sigla text
);
create table if not exists public.he_servidores (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  matricula text not null unique,
  secretaria_id uuid,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  chefia_id uuid
);
create table if not exists public.he_config (
  id int primary key default 1 check (id = 1),
  teto_diario_horas numeric(5,2) not null default 2,
  teto_mensal_horas numeric,           -- NULL ou 0 = sem limite mensal
  atualizado_em timestamptz not null default now(),
  mes_aberto text
);
-- para bancos ja existentes:
alter table public.he_config add column if not exists teto_mensal_horas numeric;
create table if not exists public.he_dias_bloqueados (
  data date primary key,
  motivo text,
  criado_por uuid,
  criado_em timestamptz not null default now()
);
create table if not exists public.he_perfis (
  user_id uuid primary key,
  nome text,
  email text,
  papel text not null default 'servidor' check (papel in ('servidor','chefia','rh')),
  servidor_id uuid,
  secretaria_id uuid,
  criado_em timestamptz not null default now(),
  matricula text
);
create table if not exists public.he_registros (
  id uuid primary key default gen_random_uuid(),
  servidor_id uuid not null,
  data date not null,
  horas numeric(5,2) not null check (horas > 0),
  tipo text not null default 'extra' check (tipo in ('extra','noturno')),
  justificativa text not null,
  status text not null default 'pendente' check (status in ('pendente','aprovado','rejeitado')),
  registrado_por uuid,
  aprovado_por uuid,
  aprovado_em timestamptz,
  observacao_aprovacao text,
  criado_em timestamptz not null default now(),
  horas_original numeric(5,2),
  constraint he_just_min check (char_length(btrim(justificativa)) >= 20)
);
create table if not exists public.he_app_chunks (
  seq int primary key,
  b64 text not null
);

-- ---------- ÍNDICES ----------
create index if not exists idx_he_registros_data on public.he_registros using btree (data);
create index if not exists idx_he_registros_servidor on public.he_registros using btree (servidor_id);
create index if not exists idx_he_registros_status on public.he_registros using btree (status);
create index if not exists idx_he_servidores_chefia on public.he_servidores using btree (chefia_id);
create index if not exists idx_he_servidores_secretaria on public.he_servidores using btree (secretaria_id);

-- ---------- VIEW (lançamentos com dados do servidor e do setor) ----------
create or replace view public.he_vw_registros as
 select r.id, r.servidor_id, s.nome as servidor_nome, s.matricula, s.chefia_id, ch.nome as chefia_nome, ch.sigla as chefia_sigla, r.data, r.horas, r.tipo, r.horas_original, r.justificativa, r.status, r.criado_em, r.aprovado_em, r.aprovado_por, r.observacao_aprovacao
 from public.he_registros r join public.he_servidores s on s.id = r.servidor_id left join public.he_chefias ch on ch.id = s.chefia_id;

-- ---------- TRIGGER DE REGRAS (mês liberado, dia bloqueado, teto diário) ----------
-- RH não tem limites. Guarda a hora original quando a chefia ajusta.
create or replace function public.he_registros_regras() returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_papel text; v_teto numeric; v_soma numeric; v_mes text; v_teto_mes numeric; v_soma_mes numeric;
begin
  if TG_OP = 'UPDATE' and NEW.horas <> OLD.horas and OLD.horas_original is null then
    NEW.horas_original := OLD.horas;
  end if;
  v_papel := public.he_meu_papel();
  if v_papel = 'rh' then return NEW; end if;
  if NEW.status = 'rejeitado' then return NEW; end if;
  if NEW.data > current_date then
    raise exception 'Nao e possivel lancar horas extras em data futura.';
  end if;
  if TG_OP = 'INSERT' then
    select mes_aberto into v_mes from public.he_config where id = 1;
    if v_mes is not null and v_mes <> '' and to_char(NEW.data,'YYYY-MM') <> v_mes then
      raise exception 'Lancamentos liberados apenas para a competencia %.', v_mes;
    end if;
    if exists (select 1 from public.he_dias_bloqueados where data = NEW.data) then
      raise exception 'O dia % esta bloqueado para lancamento de horas extras.', to_char(NEW.data,'DD/MM/YYYY');
    end if;
  end if;
  select teto_diario_horas into v_teto from public.he_config where id = 1;
  select coalesce(sum(horas),0) into v_soma from public.he_registros
  where servidor_id = NEW.servidor_id and data = NEW.data and status <> 'rejeitado' and id <> NEW.id;
  if (v_soma + NEW.horas) > v_teto then
    raise exception 'Teto diario de % h por dia excedido (ja ha % h lancadas nesta data).', v_teto, v_soma;
  end if;
  -- teto mensal por servidor (NULL ou 0 = sem limite); RH nao e limitado (retorna acima)
  select teto_mensal_horas into v_teto_mes from public.he_config where id = 1;
  if v_teto_mes is not null and v_teto_mes > 0 then
    select coalesce(sum(horas),0) into v_soma_mes from public.he_registros
    where servidor_id = NEW.servidor_id
      and data >= date_trunc('month', NEW.data)::date
      and data <  (date_trunc('month', NEW.data) + interval '1 month')::date
      and status <> 'rejeitado'
      and id <> NEW.id;
    if (v_soma_mes + NEW.horas) > v_teto_mes then
      raise exception 'Teto mensal de % h excedido (ja ha % h lancadas em %).', v_teto_mes, v_soma_mes, to_char(NEW.data,'MM/YYYY');
    end if;
  end if;
  return NEW;
end;
$function$;
drop trigger if exists trg_he_registros_regras on public.he_registros;
create trigger trg_he_registros_regras before insert or update on public.he_registros for each row execute function public.he_registros_regras();

-- ---------- NOVOS USUÁRIOS (cria perfil ao cadastrar no Auth com app='he') ----------
-- 1º cadastro do sistema vira RH; demais entram como servidor.
create or replace function public.he_handle_new_user() returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_papel text; v_mat text; v_nome text; v_serv uuid; v_chefia uuid;
begin
  if coalesce(new.raw_user_meta_data->>'app','') <> 'he' then return new; end if;
  v_mat  := nullif(btrim(new.raw_user_meta_data->>'matricula'), '');
  v_nome := coalesce(nullif(btrim(new.raw_user_meta_data->>'nome'),''), split_part(new.email,'@',1));
  begin v_chefia := nullif(btrim(new.raw_user_meta_data->>'chefia_id'),'')::uuid; exception when others then v_chefia := null; end;
  if exists (select 1 from public.he_perfis where papel='rh') then v_papel := 'servidor'; else v_papel := 'rh'; end if;
  if v_papel <> 'rh' then
    if v_mat is not null then select id into v_serv from public.he_servidores where matricula = v_mat; end if;
    if v_serv is null then
      insert into public.he_servidores (nome, matricula, chefia_id) values (v_nome, coalesce(v_mat,'SN-'||substr(replace(new.id::text,'-',''),1,8)), v_chefia) returning id into v_serv;
    else update public.he_servidores set chefia_id = coalesce(chefia_id, v_chefia) where id = v_serv; end if;
    if exists (select 1 from public.he_chefias where responsavel_servidor_id = v_serv) then v_papel := 'chefia'; end if;
  end if;
  insert into public.he_perfis (user_id, nome, email, papel, matricula, servidor_id) values (new.id, v_nome, new.email, v_papel, v_mat, v_serv) on conflict (user_id) do nothing;
  return new;
end; $function$;
drop trigger if exists on_auth_user_created_he on auth.users;
create trigger on_auth_user_created_he after insert on auth.users for each row execute function public.he_handle_new_user();

-- ---------- CHAVES ESTRANGEIRAS ----------
alter table public.he_chefias drop constraint if exists he_chefias_responsavel_servidor_id_fkey;
alter table public.he_chefias add constraint he_chefias_responsavel_servidor_id_fkey foreign key (responsavel_servidor_id) references public.he_servidores(id) on delete set null;
alter table public.he_servidores drop constraint if exists he_servidores_secretaria_id_fkey;
alter table public.he_servidores add constraint he_servidores_secretaria_id_fkey foreign key (secretaria_id) references public.he_secretarias(id) on delete set null;
alter table public.he_servidores drop constraint if exists he_servidores_chefia_id_fkey;
alter table public.he_servidores add constraint he_servidores_chefia_id_fkey foreign key (chefia_id) references public.he_chefias(id) on delete set null;
alter table public.he_perfis drop constraint if exists he_perfis_servidor_id_fkey;
alter table public.he_perfis add constraint he_perfis_servidor_id_fkey foreign key (servidor_id) references public.he_servidores(id) on delete set null;
alter table public.he_perfis drop constraint if exists he_perfis_secretaria_id_fkey;
alter table public.he_perfis add constraint he_perfis_secretaria_id_fkey foreign key (secretaria_id) references public.he_secretarias(id) on delete set null;
alter table public.he_registros drop constraint if exists he_registros_servidor_id_fkey;
alter table public.he_registros add constraint he_registros_servidor_id_fkey foreign key (servidor_id) references public.he_servidores(id) on delete cascade;
alter table public.he_perfis drop constraint if exists he_perfis_user_id_fkey;
alter table public.he_perfis add constraint he_perfis_user_id_fkey foreign key (user_id) references auth.users(id) on delete cascade;
alter table public.he_dias_bloqueados drop constraint if exists he_dias_bloqueados_criado_por_fkey;
alter table public.he_dias_bloqueados add constraint he_dias_bloqueados_criado_por_fkey foreign key (criado_por) references auth.users(id);
alter table public.he_registros drop constraint if exists he_registros_registrado_por_fkey;
alter table public.he_registros add constraint he_registros_registrado_por_fkey foreign key (registrado_por) references auth.users(id);
alter table public.he_registros drop constraint if exists he_registros_aprovado_por_fkey;
alter table public.he_registros add constraint he_registros_aprovado_por_fkey foreign key (aprovado_por) references auth.users(id);

-- ============================================================
-- SEGURANÇA POR PERFIL (Row Level Security)
-- ============================================================
alter table public.he_secretarias enable row level security;
alter table public.he_chefias enable row level security;
alter table public.he_servidores enable row level security;
alter table public.he_config enable row level security;
alter table public.he_dias_bloqueados enable row level security;
alter table public.he_perfis enable row level security;
alter table public.he_registros enable row level security;
alter table public.he_app_chunks enable row level security;

drop policy if exists he_sec_sel on public.he_secretarias;
create policy he_sec_sel on public.he_secretarias for select to authenticated using (true);
drop policy if exists he_sec_mod on public.he_secretarias;
create policy he_sec_mod on public.he_secretarias for all to authenticated using (he_meu_papel() = 'rh') with check (he_meu_papel() = 'rh');
drop policy if exists he_chefias_sel on public.he_chefias;
create policy he_chefias_sel on public.he_chefias for select to authenticated using (true);
drop policy if exists he_chefias_mod on public.he_chefias;
create policy he_chefias_mod on public.he_chefias for all to authenticated using (he_meu_papel() = 'rh') with check (he_meu_papel() = 'rh');
drop policy if exists he_serv_sel on public.he_servidores;
create policy he_serv_sel on public.he_servidores for select to authenticated using ((he_meu_papel() = 'rh') or ((he_meu_papel() = 'chefia') and (chefia_id in (select he_minhas_chefias()))) or (id = he_meu_servidor()));
drop policy if exists he_serv_mod on public.he_servidores;
create policy he_serv_mod on public.he_servidores for all to authenticated using (he_meu_papel() = 'rh') with check (he_meu_papel() = 'rh');
drop policy if exists he_cfg_sel on public.he_config;
create policy he_cfg_sel on public.he_config for select to authenticated using (true);
drop policy if exists he_cfg_upd on public.he_config;
create policy he_cfg_upd on public.he_config for update to authenticated using (he_meu_papel() = 'rh') with check (he_meu_papel() = 'rh');
drop policy if exists he_bloq_sel on public.he_dias_bloqueados;
create policy he_bloq_sel on public.he_dias_bloqueados for select to authenticated using (true);
drop policy if exists he_bloq_mod on public.he_dias_bloqueados;
create policy he_bloq_mod on public.he_dias_bloqueados for all to authenticated using (he_meu_papel() = 'rh') with check (he_meu_papel() = 'rh');
drop policy if exists he_perf_sel on public.he_perfis;
create policy he_perf_sel on public.he_perfis for select to authenticated using ((user_id = auth.uid()) or (he_meu_papel() = 'rh'));
drop policy if exists he_perf_upd on public.he_perfis;
create policy he_perf_upd on public.he_perfis for update to authenticated using (he_meu_papel() = 'rh') with check (he_meu_papel() = 'rh');
drop policy if exists he_perf_del on public.he_perfis;
create policy he_perf_del on public.he_perfis for delete to authenticated using (he_meu_papel() = 'rh');
drop policy if exists he_reg_sel on public.he_registros;
create policy he_reg_sel on public.he_registros for select to authenticated using ((he_meu_papel() = 'rh') or (servidor_id = he_meu_servidor()) or ((he_meu_papel() = 'chefia') and (servidor_id in (select he_servidores.id from he_servidores where he_servidores.chefia_id in (select he_minhas_chefias())))));
drop policy if exists he_reg_ins on public.he_registros;
create policy he_reg_ins on public.he_registros for insert to authenticated with check ((he_meu_papel() = 'rh') or (servidor_id = he_meu_servidor()));
drop policy if exists he_reg_upd on public.he_registros;
create policy he_reg_upd on public.he_registros for update to authenticated using ((he_meu_papel() = 'rh') or ((servidor_id = he_meu_servidor()) and (status = 'pendente')) or ((he_meu_papel() = 'chefia') and (servidor_id in (select he_servidores.id from he_servidores where he_servidores.chefia_id in (select he_minhas_chefias()))))) with check ((he_meu_papel() = 'rh') or (servidor_id = he_meu_servidor()) or ((he_meu_papel() = 'chefia') and (servidor_id in (select he_servidores.id from he_servidores where he_servidores.chefia_id in (select he_minhas_chefias())))));
drop policy if exists he_reg_del on public.he_registros;
create policy he_reg_del on public.he_registros for delete to authenticated using ((he_meu_papel() = 'rh') or ((servidor_id = he_meu_servidor()) and (status = 'pendente')));
drop policy if exists he_app_chunks_sel on public.he_app_chunks;
create policy he_app_chunks_sel on public.he_app_chunks for select to anon, authenticated using (true);

-- ---------- CONFIG INICIAL (1 linha obrigatória) ----------
insert into public.he_config (id, teto_diario_horas, mes_aberto) values (1, 2, null)
  on conflict (id) do nothing;
