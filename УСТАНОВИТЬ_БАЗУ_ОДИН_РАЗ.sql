-- ПРОДВИЖЕНИЕ: ЕДИНЫЙ УСТАНОВОЧНЫЙ SQL 6.2–6.4
-- Сначала сделайте резервную копию. Выполнять целиком в Supabase SQL Editor.
-- Сохраняет старые таблицы; не переносит платежи и не включает автоматическое списание.

-- Продвижение 6.2. Выполнить после резервной копии в SQL Editor.
-- Создаёт финансовые таблицы и усиливает ограничения доступа.
begin;
create extension if not exists pgcrypto;
create table if not exists public.studios (id uuid primary key default gen_random_uuid(), name text not null default 'Продвижение', owner_id uuid not null unique references auth.users(id), created_at timestamptz default now());
create table if not exists public.studio_members (studio_id uuid not null references public.studios(id), user_id uuid not null references auth.users(id), role text not null check(role in ('owner','employee','client')), approved boolean not null default false, trainer_id uuid references auth.users(id), share_percent numeric(5,2) not null default 50 check(share_percent between 0 and 100), primary key(studio_id,user_id));
create table if not exists public.studio_prices (studio_id uuid not null references public.studios(id), client_id uuid not null references auth.users(id), kind text not null check(kind in ('personal','mat_split','reformer_split','group')), amount numeric(12,2) not null check(amount>=0), primary key(studio_id,client_id,kind));
create table if not exists public.studio_ledger (id uuid primary key default gen_random_uuid(), studio_id uuid not null references public.studios(id), client_id uuid references auth.users(id), trainer_id uuid references auth.users(id), kind text not null check(kind in ('deposit','session','expense','refund')), amount numeric(12,2) not null check(amount>0), method text not null check(method in ('cash','card','transfer','other','deposit')), event_date date not null default current_date, note text not null default '', created_by uuid not null default auth.uid(), created_at timestamptz default now());
create or replace function public.is_studio_owner(s uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.studios where id=s and owner_id=(select auth.uid())) $$;
create or replace function public.my_studio_role(s uuid) returns text language sql stable security definer set search_path=public as $$ select role from public.studio_members where studio_id=s and user_id=(select auth.uid()) and approved=true limit 1 $$;
create or replace function public.is_my_client(s uuid,c uuid) returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from public.studio_members where studio_id=s and user_id=c and role='client' and approved and trainer_id=(select auth.uid()))$$;
revoke all on function public.is_studio_owner(uuid),public.my_studio_role(uuid),public.is_my_client(uuid,uuid) from public;
grant execute on function public.is_studio_owner(uuid),public.my_studio_role(uuid),public.is_my_client(uuid,uuid) to authenticated;
alter table public.studios enable row level security;
alter table public.studio_members enable row level security;
alter table public.studio_prices enable row level security;
alter table public.studio_ledger enable row level security;
-- Удаляем прежние политики, чтобы небезопасная политика не действовала параллельно.
drop policy if exists studio_view on public.studios;
drop policy if exists studio_create on public.studios;
drop policy if exists member_view on public.studio_members;
drop policy if exists member_insert on public.studio_members;
drop policy if exists member_update on public.studio_members;
drop policy if exists member_delete on public.studio_members;
drop policy if exists price_view on public.studio_prices;
drop policy if exists price_write on public.studio_prices;
drop policy if exists price_insert on public.studio_prices;
drop policy if exists price_update on public.studio_prices;
drop policy if exists price_delete on public.studio_prices;
drop policy if exists ledger_view on public.studio_ledger;
drop policy if exists ledger_write on public.studio_ledger;
create policy studio_view on public.studios for select to authenticated using(public.is_studio_owner(id) or public.my_studio_role(id) is not null);
create policy studio_create on public.studios for insert to authenticated with check(owner_id=(select auth.uid()));
create policy member_view on public.studio_members for select to authenticated using(public.is_studio_owner(studio_id) or user_id=(select auth.uid()) or (public.my_studio_role(studio_id)='employee' and public.is_my_client(studio_id,user_id)));
-- Владелец добавляет сотрудников и утверждает клиентов. Владелецскую строку создаёт триггер.
create policy member_insert on public.studio_members for insert to authenticated with check((public.is_studio_owner(studio_id) and role in ('employee','client')) or (user_id=(select auth.uid()) and role='client' and approved=false and trainer_id is null));
create policy member_update on public.studio_members for update to authenticated using(public.is_studio_owner(studio_id)) with check(public.is_studio_owner(studio_id) and role<>'owner');
create policy member_delete on public.studio_members for delete to authenticated using(public.is_studio_owner(studio_id) and role<>'owner');
create policy price_view on public.studio_prices for select to authenticated using(public.is_studio_owner(studio_id) or (client_id=(select auth.uid()) and public.my_studio_role(studio_id)='client') or (public.my_studio_role(studio_id)='employee' and public.is_my_client(studio_id,client_id)));
create policy price_insert on public.studio_prices for insert to authenticated with check(public.is_studio_owner(studio_id));
create policy price_update on public.studio_prices for update to authenticated using(public.is_studio_owner(studio_id)) with check(public.is_studio_owner(studio_id));
create policy price_delete on public.studio_prices for delete to authenticated using(public.is_studio_owner(studio_id));
-- Сотрудник видит только начисления за свои занятия, но не расходы и депозиты студии.
create policy ledger_view on public.studio_ledger for select to authenticated using(public.is_studio_owner(studio_id) or (public.my_studio_role(studio_id)='employee' and trainer_id=(select auth.uid()) and kind='session') or (public.my_studio_role(studio_id)='client' and client_id=(select auth.uid()) and kind in ('deposit','session','refund')));
create policy ledger_write on public.studio_ledger for insert to authenticated with check(public.is_studio_owner(studio_id) and created_by=(select auth.uid()));
-- Создание студии автоматически создаёт её владельца, без возможности подделать роль из браузера.
create or replace function public.create_owner_membership() returns trigger language plpgsql security definer set search_path=public as $$begin insert into public.studio_members(studio_id,user_id,role,approved) values(new.id,new.owner_id,'owner',true);return new;end$$;
drop trigger if exists studio_owner_membership on public.studios;
create trigger studio_owner_membership after insert on public.studios for each row execute function public.create_owner_membership();
-- Для студий, созданных ранее, восстановим запись владельца, если её ещё нет.
insert into public.studio_members(studio_id,user_id,role,approved)
select s.id,s.owner_id,'owner',true from public.studios s
where not exists(select 1 from public.studio_members m where m.studio_id=s.id and m.user_id=s.owner_id);
-- Для предотвращения дублирования доходов проверяем сочетание вида операции и способа оплаты.
alter table public.studio_ledger drop constraint if exists studio_ledger_deposit_method_check;
alter table public.studio_ledger add constraint studio_ledger_deposit_method_check check(method <> 'deposit' or kind='session');
grant usage on schema public to authenticated;
grant select,insert on public.studios to authenticated;
grant select,insert,update,delete on public.studio_members,public.studio_prices to authenticated;
grant select,insert on public.studio_ledger to authenticated;
commit;


-- Выполнять после finance_6_2.sql. Не удаляет существующие данные.
begin;
create table if not exists public.studio_subscriptions (
 id uuid primary key default gen_random_uuid(),
 studio_id uuid not null references public.studios(id),
 client_id uuid not null references auth.users(id),
 kind text not null check(kind in ('personal','mat_split','reformer_split','group')),
 sessions_total integer not null check(sessions_total>0),
 sessions_used integer not null default 0 check(sessions_used>=0 and sessions_used<=sessions_total),
 starts_on date not null default current_date,
 expires_on date,
 note text not null default '',
 created_at timestamptz not null default now(),
 constraint subscription_valid_dates check(expires_on is null or expires_on>=starts_on)
);
create index if not exists studio_subscriptions_studio_client on public.studio_subscriptions(studio_id,client_id);
alter table public.studio_subscriptions enable row level security;
drop policy if exists subscriptions_read on public.studio_subscriptions;
drop policy if exists subscriptions_insert on public.studio_subscriptions;
drop policy if exists subscriptions_update on public.studio_subscriptions;
create policy subscriptions_read on public.studio_subscriptions for select to authenticated
 using(public.is_studio_owner(studio_id) or (client_id=auth.uid() and public.my_studio_role(studio_id)='client') or (public.my_studio_role(studio_id)='employee' and public.is_my_client(studio_id,client_id)));
create policy subscriptions_insert on public.studio_subscriptions for insert to authenticated
 with check(public.is_studio_owner(studio_id) and exists(select 1 from public.studio_members m where m.studio_id=studio_subscriptions.studio_id and m.user_id=studio_subscriptions.client_id and m.role='client' and m.approved));
create policy subscriptions_update on public.studio_subscriptions for update to authenticated
 using(public.is_studio_owner(studio_id)) with check(public.is_studio_owner(studio_id));
grant select,insert,update on public.studio_subscriptions to authenticated;
commit;


-- Продвижение 6.4: связь существующих карточек с аккаунтами студии.
-- Требует finance_6_2.sql и subscriptions_6_3.sql. Не изменяет старые записи.
begin;
create table if not exists public.studio_client_links (
 studio_id uuid not null references public.studios(id) on delete cascade,
 legacy_client_id uuid not null references public.clients(id) on delete cascade,
 client_user_id uuid not null references auth.users(id),
 linked_by uuid not null default auth.uid() references auth.users(id),
 linked_at timestamptz not null default now(),
 primary key (studio_id,legacy_client_id),
 unique(studio_id,client_user_id)
);
create index if not exists studio_client_links_user_idx on public.studio_client_links(client_user_id);
alter table public.studio_client_links enable row level security;
drop policy if exists links_owner_select on public.studio_client_links;
drop policy if exists links_owner_insert on public.studio_client_links;
drop policy if exists links_owner_delete on public.studio_client_links;
create policy links_owner_select on public.studio_client_links for select to authenticated
 using(public.is_studio_owner(studio_id));
create policy links_owner_insert on public.studio_client_links for insert to authenticated
 with check(public.is_studio_owner(studio_id) and linked_by=auth.uid()
 and exists(select 1 from public.clients c where c.id=legacy_client_id and c.trainer_id=auth.uid())
 and exists(select 1 from public.studio_members m where m.studio_id=studio_client_links.studio_id
 and m.user_id=studio_client_links.client_user_id and m.role='client' and m.approved));
create policy links_owner_delete on public.studio_client_links for delete to authenticated
 using(public.is_studio_owner(studio_id));
grant select,insert,delete on public.studio_client_links to authenticated;
commit;
