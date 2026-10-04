-- ПРОДВИЖЕНИЕ 7.0. Выполнить ПОСЛЕ базы 6.5 и исправления создания студии 6.7.1.
-- Не удаляет старые данные. Сначала сделайте резервную копию.
begin;
create extension if not exists pgcrypto;
create table if not exists public.studio_clients (
 id uuid primary key default gen_random_uuid(),studio_id uuid not null references public.studios(id),
 legacy_client_id uuid unique references public.clients(id),name text not null,phone text not null default '',
 goal text not null default '',assigned_trainer_id uuid references auth.users(id),created_at timestamptz not null default now());
create index if not exists sc_studio_trainer on public.studio_clients(studio_id,assigned_trainer_id);
create table if not exists public.studio_client_prices (
 studio_id uuid not null references public.studios(id),client_id uuid not null references public.studio_clients(id),
 kind text not null check(kind in ('personal','mat_split','reformer_split','group')),
 amount numeric(12,2) not null check(amount>=0),primary key(client_id,kind));
create table if not exists public.studio_client_passes (
 id uuid primary key default gen_random_uuid(),studio_id uuid not null references public.studios(id),
 client_id uuid not null references public.studio_clients(id),kind text not null check(kind in ('personal','mat_split','reformer_split','group')),
 sessions_total integer not null check(sessions_total>0),sessions_used integer not null default 0 check(sessions_used>=0 and sessions_used<=sessions_total),
 expires_on date,created_at timestamptz not null default now());
create table if not exists public.studio_cashflows (
 id uuid primary key default gen_random_uuid(),request_id uuid not null unique,
 studio_id uuid not null references public.studios(id),client_id uuid references public.studio_clients(id),
 trainer_id uuid references auth.users(id),kind text not null check(kind in ('deposit','session','expense')),
 amount numeric(12,2) not null check(amount>0),method text not null check(method in ('cash','card','transfer','other','deposit')),
 share_percent numeric(5,2) not null default 0 check(share_percent between 0 and 100),
 event_date date not null default current_date,note text not null default '',
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),
 constraint cf_method_check check(method<>'deposit' or kind='session'));
create index if not exists cf_studio_date on public.studio_cashflows(studio_id,event_date);
create index if not exists cf_client on public.studio_cashflows(client_id);
-- Политики чтения: владелец видит всё, сотрудник — только закреплённых клиентов и свои занятия.
alter table public.studio_clients enable row level security;
alter table public.studio_client_prices enable row level security;
alter table public.studio_client_passes enable row level security;
alter table public.studio_cashflows enable row level security;
drop policy if exists sc_read on public.studio_clients;
create policy sc_read on public.studio_clients for select to authenticated using (
 public.is_studio_owner(studio_id) or
 (public.my_studio_role(studio_id)='employee' and assigned_trainer_id=auth.uid()));
drop policy if exists prices_read7 on public.studio_client_prices;
create policy prices_read7 on public.studio_client_prices for select to authenticated using (
 public.is_studio_owner(studio_id) or exists(select 1 from public.studio_clients c where c.id=client_id and c.studio_id=studio_client_prices.studio_id and c.assigned_trainer_id=auth.uid() and public.my_studio_role(c.studio_id)='employee'));
drop policy if exists passes_read7 on public.studio_client_passes;
create policy passes_read7 on public.studio_client_passes for select to authenticated using (
 public.is_studio_owner(studio_id) or exists(select 1 from public.studio_clients c where c.id=client_id and c.studio_id=studio_client_passes.studio_id and c.assigned_trainer_id=auth.uid() and public.my_studio_role(c.studio_id)='employee'));
drop policy if exists cash_read7 on public.studio_cashflows;
create policy cash_read7 on public.studio_cashflows for select to authenticated using (
 public.is_studio_owner(studio_id) or
 (public.my_studio_role(studio_id)='employee' and
 ((kind='session' and trainer_id=auth.uid()) or
 (kind='deposit' and exists(select 1 from public.studio_clients c where c.id=client_id and c.studio_id=studio_cashflows.studio_id and c.assigned_trainer_id=auth.uid())))));
-- Доступ к прежним карточкам и расписанию с учётом назначенного тренера.
-- Существующие политики trainer_id сохраняются; эти политики только добавляют доступ.
drop policy if exists studio7_clients_read on public.clients;
create policy studio7_clients_read on public.clients for select to authenticated using (
 exists(select 1 from public.studio_clients sc where sc.legacy_client_id=clients.id and
 (public.is_studio_owner(sc.studio_id) or (public.my_studio_role(sc.studio_id)='employee' and sc.assigned_trainer_id=auth.uid()))));
drop policy if exists studio7_workouts_read on public.workouts;
create policy studio7_workouts_read on public.workouts for select to authenticated using (
 exists(select 1 from public.studio_clients sc where sc.legacy_client_id=workouts.client_id and
 (public.is_studio_owner(sc.studio_id) or (public.my_studio_role(sc.studio_id)='employee' and sc.assigned_trainer_id=auth.uid()))));
-- Никаких прямых INSERT/UPDATE/DELETE финансов из браузера: только функции ниже.
revoke insert,update,delete on public.studio_cashflows,public.studio_client_passes,public.studio_client_prices,public.studio_clients from authenticated;
grant select on public.studio_clients,public.studio_client_prices,public.studio_client_passes,public.studio_cashflows to authenticated;
-- Привязка старых клиентов владельца к новой студии. Без удаления и дублирования при повторном запуске.
create or replace function public.sync_my_old_clients(p_studio uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
 if not public.is_studio_owner(p_studio) then raise exception 'Только владелец';end if;
 insert into public.studio_clients(studio_id,legacy_client_id,name,phone,goal)
 select p_studio,c.id,c.name,coalesce(c.phone,''),coalesce(c.goal,'')
 from public.clients c where c.trainer_id=auth.uid()
 and not exists(select 1 from public.studio_clients sc where sc.legacy_client_id=c.id);
 get diagnostics v_count=row_count;return v_count;
end$$;
-- Создание клиента одновременно в старой и новой карточке; сотрудник закрепляет за собой.
create or replace function public.create_studio_client(p_studio uuid,p_name text,p_phone text default '',p_goal text default '',p_trainer uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid();v_owner uuid;v_legacy uuid;v_id uuid;v_assigned uuid;
begin
 select owner_id into v_owner from public.studios where id=p_studio;
 if v_owner is null or (v_owner<>v_actor and public.my_studio_role(p_studio)<>'employee') then raise exception 'Нет доступа';end if;
 if length(trim(coalesce(p_name,'')))<2 or length(p_name)>150 then raise exception 'Укажите имя клиента';end if;
 v_assigned:=case when v_actor=v_owner then p_trainer else v_actor end;
 if v_assigned is not null and not exists(select 1 from public.studio_members where studio_id=p_studio and user_id=v_assigned and role='employee' and approved) then raise exception 'Тренер не подтверждён';end if;
 insert into public.clients(trainer_id,name,phone,goal) values(coalesce(v_assigned,v_owner),trim(p_name),coalesce(p_phone,''),coalesce(p_goal,'')) returning id into v_legacy;
 insert into public.studio_clients(studio_id,legacy_client_id,name,phone,goal,assigned_trainer_id) values(p_studio,v_legacy,trim(p_name),coalesce(p_phone,''),coalesce(p_goal,''),v_assigned) returning id into v_id;
 return v_id;
end$$;
-- Владелец назначает сотрудника по почте, не требуя от него искать UUID.
create or replace function public.invite_studio_employee(p_studio uuid,p_email text,p_share numeric default 50)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_uid uuid;
begin
 if not public.is_studio_owner(p_studio) then raise exception 'Только владелец';end if;
 if p_share is null or p_share<0 or p_share>100 then raise exception 'Неверный процент';end if;
 select id into v_uid from auth.users where lower(email)=lower(trim(p_email)) limit 1;
 if v_uid is null then raise exception 'Сотрудник сначала должен зарегистрироваться';end if;
 if exists(select 1 from public.studios where owner_id=v_uid) then raise exception 'Этот аккаунт уже является владельцем студии';end if;
 insert into public.studio_members(studio_id,user_id,role,approved,share_percent)
 values(p_studio,v_uid,'employee',true,p_share)
 on conflict(studio_id,user_id) do update set share_percent=excluded.share_percent,approved=true
 where studio_members.role='employee';
 if not found then raise exception 'Нельзя заменить существующую роль';end if;
 return v_uid;
end$$;
create or replace function public.set_studio_client_trainer(p_client uuid,p_trainer uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_studio uuid;v_legacy uuid;v_owner uuid;
begin
 select studio_id,legacy_client_id into v_studio,v_legacy from public.studio_clients where id=p_client;
 if not public.is_studio_owner(v_studio) then raise exception 'Только владелец';end if;
 select owner_id into v_owner from public.studios where id=v_studio;
 if p_trainer is not null and not exists(select 1 from public.studio_members where studio_id=v_studio and user_id=p_trainer and role='employee' and approved) then raise exception 'Сотрудник не найден';end if;
 update public.studio_clients set assigned_trainer_id=p_trainer where id=p_client;
 if v_legacy is not null then update public.clients set trainer_id=coalesce(p_trainer,v_owner) where id=v_legacy;end if;
end$$;
create or replace function public.set_studio_client_price(p_client uuid,p_kind text,p_amount numeric)
returns void language plpgsql security definer set search_path='' as $$
declare v_studio uuid;
begin
 select studio_id into v_studio from public.studio_clients where id=p_client;
 if not public.is_studio_owner(v_studio) then raise exception 'Только владелец';end if;
 if p_kind not in ('personal','mat_split','reformer_split','group') or p_amount is null or p_amount<0 or p_amount>10000000 then raise exception 'Некорректная цена';end if;
 insert into public.studio_client_prices(studio_id,client_id,kind,amount) values(v_studio,p_client,p_kind,p_amount)
 on conflict(client_id,kind) do update set amount=excluded.amount;
end$$;
create or replace function public.create_studio_pass(p_client uuid,p_kind text,p_total integer,p_expires date default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_studio uuid;v_id uuid;
begin
 select studio_id into v_studio from public.studio_clients where id=p_client;
 if not public.is_studio_owner(v_studio) then raise exception 'Только владелец';end if;
 if p_kind not in ('personal','mat_split','reformer_split','group') or p_total is null or p_total<1 or p_total>1000 or (p_expires is not null and p_expires<current_date) then raise exception 'Некорректный абонемент';end if;
 insert into public.studio_client_passes(studio_id,client_id,kind,sessions_total,expires_on) values(v_studio,p_client,p_kind,p_total,p_expires) returning id into v_id;
 return v_id;
end$$;
create table if not exists public.studio_pass_uses(id uuid primary key default gen_random_uuid(),request_id uuid not null unique,pass_id uuid not null references public.studio_client_passes(id),created_by uuid not null references auth.users(id),created_at timestamptz not null default now());
alter table public.studio_pass_uses enable row level security;
revoke all on public.studio_pass_uses from anon,authenticated;
create or replace function public.use_studio_pass(p_pass uuid,p_request uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare v_pass public.studio_client_passes%rowtype;v_actor uuid:=auth.uid();v_old uuid;
begin
 if p_request is null then raise exception 'Нет ID операции';end if;
 select pass_id into v_old from public.studio_pass_uses where request_id=p_request;
 if found then if v_old=p_pass then return (select sessions_total-sessions_used from public.studio_client_passes where id=p_pass);end if;raise exception 'ID операции уже занят';end if;
 select * into v_pass from public.studio_client_passes where id=p_pass for update;
 if not found then raise exception 'Абонемент не найден';end if;
 if not public.is_studio_owner(v_pass.studio_id) and not exists(select 1 from public.studio_clients c where c.id=v_pass.client_id and c.assigned_trainer_id=v_actor and public.my_studio_role(v_pass.studio_id)='employee') then raise exception 'Нет доступа';end if;
 if v_pass.sessions_used>=v_pass.sessions_total or (v_pass.expires_on is not null and v_pass.expires_on<current_date) then raise exception 'Абонемент закончился или истёк';end if;
 update public.studio_client_passes set sessions_used=sessions_used+1 where id=p_pass;
 insert into public.studio_pass_uses(request_id,pass_id,created_by) values(p_request,p_pass,v_actor);
 return v_pass.sessions_total-v_pass.sessions_used-1;
end$$;
-- Атомарная операция с защитой от повторного списания и отрицательного депозита.
create or replace function public.record_studio_cashflow(p_studio uuid,p_request uuid,p_client uuid,p_kind text,p_amount numeric,p_method text,p_date date,p_note text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid();v_owner boolean;v_client public.studio_clients%rowtype;v_trainer uuid;v_share numeric:=0;v_balance numeric;v_id uuid;
begin
 v_owner:=public.is_studio_owner(p_studio);
 if not v_owner and public.my_studio_role(p_studio)<>'employee' then raise exception 'Нет доступа';end if;
 if p_request is null or p_amount is null or p_amount<=0 or p_amount>10000000 or round(p_amount,2)<>p_amount then raise exception 'Неверная сумма или ID';end if;
 if p_kind not in ('deposit','session','expense') or p_method not in ('cash','card','transfer','other','deposit') or p_date is null then raise exception 'Неверная операция';end if;
 if (p_method='deposit' and p_kind<>'session') or (p_kind='deposit' and p_method='deposit') then raise exception 'Недопустимый способ оплаты';end if;
 if p_kind='expense' then
   if not v_owner or p_client is not null or p_method='deposit' then raise exception 'Расходы добавляет только владелец';end if;
 else
   select * into v_client from public.studio_clients where id=p_client and studio_id=p_studio;
   if not found then raise exception 'Клиент не найден';end if;
   if not v_owner and v_client.assigned_trainer_id is distinct from v_actor then raise exception 'Это не ваш клиент';end if;
 end if;
 -- Последовательные финансовые операции по клиенту не могут списать один остаток дважды.
 if p_client is not null then perform pg_advisory_xact_lock(hashtextextended(p_client::text,0));end if;
 select id into v_id from public.studio_cashflows where request_id=p_request;
 if found then
   if exists(select 1 from public.studio_cashflows where id=v_id and studio_id=p_studio and client_id is not distinct from p_client and kind=p_kind and amount=p_amount and method=p_method and event_date=p_date and note=coalesce(p_note,'')) then return v_id;end if;
   raise exception 'Повторно использован ID другой операции';
 end if;
 if p_kind='session' then
   v_trainer:=v_client.assigned_trainer_id;
   if v_trainer is not null then
     select share_percent into v_share from public.studio_members where studio_id=p_studio and user_id=v_trainer and role='employee' and approved;
     if not found then raise exception 'Тренер не активен';end if;
   end if;
 end if;
 if p_method='deposit' then
   select coalesce(sum(case when kind='deposit' then amount when kind='session' and method='deposit' then -amount else 0 end),0) into v_balance
   from public.studio_cashflows where studio_id=p_studio and client_id=p_client;
   if v_balance<p_amount then raise exception 'Недостаточно денег на депозите: %',v_balance;end if;
 end if;
 insert into public.studio_cashflows(request_id,studio_id,client_id,trainer_id,kind,amount,method,share_percent,event_date,note,created_by)
 values(p_request,p_studio,p_client,v_trainer,p_kind,p_amount,p_method,coalesce(v_share,0),p_date,coalesce(p_note,''),v_actor) returning id into v_id;
 return v_id;
end$$;
revoke all on function public.sync_my_old_clients(uuid),public.create_studio_client(uuid,text,text,text,uuid),public.invite_studio_employee(uuid,text,numeric),public.set_studio_client_trainer(uuid,uuid),public.set_studio_client_price(uuid,text,numeric),public.create_studio_pass(uuid,text,integer,date),public.use_studio_pass(uuid,uuid),public.record_studio_cashflow(uuid,uuid,uuid,text,numeric,text,date,text) from public,anon;
grant execute on function public.sync_my_old_clients(uuid),public.create_studio_client(uuid,text,text,text,uuid),public.invite_studio_employee(uuid,text,numeric),public.set_studio_client_trainer(uuid,uuid),public.set_studio_client_price(uuid,text,numeric),public.create_studio_pass(uuid,text,integer,date),public.use_studio_pass(uuid,uuid),public.record_studio_cashflow(uuid,uuid,uuid,text,numeric,text,date,text) to authenticated;
commit;
