-- ПРОДВИЖЕНИЕ 6.7: выполнить ПОСЛЕ объединённой базы 6.5.
-- Включает 6.6 и улучшения 6.7. Старые данные не удаляет.
-- Продвижение 6.6. Выполнить ПОСЛЕ 6.5, только после резервной копии.
-- Новые финансовые операции проводятся через атомарную серверную функцию.
-- Существующие таблицы и строки не удаляются.
begin;
alter table public.studio_ledger add column if not exists request_id uuid;
create unique index if not exists studio_ledger_request_unique on public.studio_ledger(request_id) where request_id is not null;
create index if not exists studio_ledger_balance_idx on public.studio_ledger(studio_id,client_id,kind,method);

-- Функция выполняется от имени создателя (definer), но сама проверяет auth.uid() и роль владельца.
create or replace function public.record_studio_operation(
 p_studio uuid, p_request uuid, p_kind text, p_amount numeric,
 p_method text, p_date date, p_client uuid default null,
 p_trainer uuid default null, p_note text default ''
) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_old uuid; v_balance numeric; v_id uuid;
begin
 if v_uid is null or not public.is_studio_owner(p_studio) then
   raise exception 'Доступ к финансовым операциям запрещён';
 end if;
 if p_request is null then raise exception 'Отсутствует идентификатор операции'; end if;
 if p_amount is null or p_amount<=0 or p_amount>1000000000 or round(p_amount,2)<>p_amount then
   raise exception 'Укажите корректную сумму';
 end if;
 if p_kind not in ('deposit','session','expense','refund') or
    p_method not in ('cash','card','transfer','other','deposit') or p_date is null then
   raise exception 'Неверные параметры операции';
 end if;
 if (p_method='deposit' and p_kind<>'session') or (p_kind='deposit' and p_method='deposit') then
   raise exception 'Недопустимый способ оплаты';
 end if;
 if p_kind in ('deposit','session','refund') then
   if p_client is null or not exists (
     select 1 from public.studio_members m where m.studio_id=p_studio
     and m.user_id=p_client and m.role='client' and m.approved
   ) then raise exception 'Выберите подтверждённого клиента студии'; end if;
 else
   if p_client is not null or p_trainer is not null then
     raise exception 'Для расхода не указывайте клиента или тренера';
   end if;
 end if;
 if p_trainer is not null and not exists (
   select 1 from public.studio_members m where m.studio_id=p_studio
   and m.user_id=p_trainer and m.role='employee' and m.approved
 ) then raise exception 'Тренер не является сотрудником студии'; end if;
 if p_kind<>'session' and p_trainer is not null then
   raise exception 'Тренер указывается только для оплаты занятия';
 end if;
 -- Один клиент: сериализуем проверки и списания даже при параллельных запросах.
 if p_client is not null then
   perform pg_advisory_xact_lock(hashtextextended(p_studio::text||':'||p_client::text,0));
 end if;
 select id into v_old from public.studio_ledger where request_id=p_request;
 if found then
   if exists(select 1 from public.studio_ledger l where l.id=v_old and l.studio_id=p_studio
       and l.kind=p_kind and l.amount=p_amount and l.method=p_method
       and l.event_date=p_date and l.client_id is not distinct from p_client
       and l.trainer_id is not distinct from p_trainer and l.note=coalesce(p_note,'')) then
     return v_old;
   end if;
   raise exception 'Идентификатор операции уже использован';
 end if;
 if p_kind='session' and p_method='deposit' then
   select coalesce(sum(case when kind='deposit' then amount
     when kind='session' and method='deposit' then -amount
     when kind='refund' and method='deposit' then -amount
     else 0 end),0) into v_balance
   from public.studio_ledger where studio_id=p_studio and client_id=p_client;
   if v_balance<p_amount then raise exception 'Недостаточно средств на депозите (остаток: %)',v_balance; end if;
 end if;
 insert into public.studio_ledger(studio_id,request_id,client_id,trainer_id,kind,amount,method,event_date,note,created_by)
 values(p_studio,p_request,p_client,p_trainer,p_kind,p_amount,p_method,p_date,coalesce(p_note,''),v_uid)
 returning id into v_id;
 return v_id;
end$$;
revoke all on function public.record_studio_operation(uuid,uuid,text,numeric,text,date,uuid,uuid,text) from public;
grant execute on function public.record_studio_operation(uuid,uuid,text,numeric,text,date,uuid,uuid,text) to authenticated;
-- Не позволяем обходить проверки функции прямой вставкой из приложения.
drop policy if exists ledger_write on public.studio_ledger;
revoke insert on public.studio_ledger from authenticated;
commit;


begin;
-- Фиксируем процент сотрудника в момент оплаты занятия: последующие изменения процента
-- не переписывают историю начислений.
alter table public.studio_ledger add column if not exists share_at_sale numeric(5,2);
create or replace function public.record_studio_operation(
 p_studio uuid,p_request uuid,p_kind text,p_amount numeric,p_method text,p_date date,
 p_client uuid default null,p_trainer uuid default null,p_note text default ''
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid();v_old uuid;v_balance numeric;v_id uuid;v_share numeric;
begin
 if v_uid is null or not public.is_studio_owner(p_studio) then raise exception 'Доступ запрещён';end if;
 if p_request is null then raise exception 'Нет идентификатора операции';end if;
 if p_amount is null or p_amount<=0 or p_amount>1000000000 or round(p_amount,2)<>p_amount then raise exception 'Некорректная сумма';end if;
 if p_kind not in ('deposit','session','expense','refund') or p_method not in ('cash','card','transfer','other','deposit') or p_date is null then raise exception 'Некорректные параметры';end if;
 if p_method='deposit' and p_kind not in ('session','refund') then raise exception 'Недопустимый способ оплаты';end if;
 if p_kind in ('deposit','session','refund') then
  if p_client is null or not exists(select 1 from public.studio_members m where m.studio_id=p_studio and m.user_id=p_client and m.role='client' and m.approved) then raise exception 'Нет подтверждённого клиента';end if;
 else
  if p_client is not null or p_trainer is not null then raise exception 'Расход без клиента и тренера';end if;
 end if;
 if p_trainer is not null then
  if p_kind<>'session' then raise exception 'Тренер только для занятия';end if;
  select m.share_percent into v_share from public.studio_members m where m.studio_id=p_studio and m.user_id=p_trainer and m.role='employee' and m.approved;
  if not found then raise exception 'Нет подтверждённого сотрудника';end if;
 end if;
 if p_client is not null then perform pg_advisory_xact_lock(hashtextextended(p_studio::text||':'||p_client::text,0));end if;
 select id into v_old from public.studio_ledger where request_id=p_request;
 if found then
  if exists(select 1 from public.studio_ledger l where l.id=v_old and l.studio_id=p_studio and l.kind=p_kind and l.amount=p_amount and l.method=p_method and l.event_date=p_date and l.client_id is not distinct from p_client and l.trainer_id is not distinct from p_trainer and l.note=coalesce(p_note,'')) then return v_old;end if;
  raise exception 'ID операции уже использован';
 end if;
 if p_method='deposit' and p_kind in ('session','refund') then
  select coalesce(sum(case when kind='deposit' then amount when kind in ('session','refund') and method='deposit' then -amount else 0 end),0) into v_balance from public.studio_ledger where studio_id=p_studio and client_id=p_client;
  if v_balance<p_amount then raise exception 'Недостаточно средств на депозите (остаток: %)',v_balance;end if;
 end if;
 insert into public.studio_ledger(studio_id,request_id,client_id,trainer_id,kind,amount,method,event_date,note,created_by,share_at_sale)
 values(p_studio,p_request,p_client,p_trainer,p_kind,p_amount,p_method,p_date,coalesce(p_note,''),v_uid,v_share) returning id into v_id;
 return v_id;
end$$;
revoke all on function public.record_studio_operation(uuid,uuid,text,numeric,text,date,uuid,uuid,text) from public;
grant execute on function public.record_studio_operation(uuid,uuid,text,numeric,text,date,uuid,uuid,text) to authenticated;
-- Атомарное и идемпотентное списание абонемента.
create table if not exists public.studio_subscription_uses (
 id uuid primary key default gen_random_uuid(),
 subscription_id uuid not null references public.studio_subscriptions(id),
 request_id uuid not null unique,
 used_by uuid not null references auth.users(id),
 used_at timestamptz not null default now()
);
alter table public.studio_subscription_uses enable row level security;
drop policy if exists subscription_uses_owner_read on public.studio_subscription_uses;
create policy subscription_uses_owner_read on public.studio_subscription_uses for select to authenticated
 using(exists(select 1 from public.studio_subscriptions s where s.id=subscription_id and public.is_studio_owner(s.studio_id)));
grant select on public.studio_subscription_uses to authenticated;
revoke insert,update,delete on public.studio_subscription_uses from authenticated;
drop policy if exists subscriptions_update on public.studio_subscriptions;
revoke update on public.studio_subscriptions from authenticated;
create or replace function public.consume_studio_subscription(p_subscription uuid,p_request uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.studio_subscriptions%rowtype;v_id uuid;
begin
 if auth.uid() is null or p_request is null then raise exception 'Нет доступа или ID операции';end if;
 select * into s from public.studio_subscriptions where id=p_subscription for update;
 if not found or not public.is_studio_owner(s.studio_id) then raise exception 'Абонемент не найден или нет доступа';end if;
 select id into v_id from public.studio_subscription_uses where request_id=p_request;
 if found then
  if exists(select 1 from public.studio_subscription_uses where id=v_id and subscription_id=p_subscription) then return v_id;end if;
  raise exception 'ID операции уже использован';
 end if;
 if s.sessions_used>=s.sessions_total then raise exception 'Занятия закончились';end if;
 if s.starts_on>current_date or (s.expires_on is not null and s.expires_on<current_date) then raise exception 'Абонемент не действует сегодня';end if;
 update public.studio_subscriptions set sessions_used=sessions_used+1 where id=p_subscription;
 insert into public.studio_subscription_uses(subscription_id,request_id,used_by) values(p_subscription,p_request,auth.uid()) returning id into v_id;
 return v_id;
end$$;
revoke all on function public.consume_studio_subscription(uuid,uuid) from public;
grant execute on function public.consume_studio_subscription(uuid,uuid) to authenticated;
commit;
