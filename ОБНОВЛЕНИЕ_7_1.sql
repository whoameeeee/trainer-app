-- Продвижение 7.1. Выполнить после ОБНОВЛЕНИЕ_7_0.sql.
-- Существующие абонементы по занятиям сохраняются для истории.
begin;
create table if not exists public.studio_money_passes (
 id uuid primary key default gen_random_uuid(),
 studio_id uuid not null references public.studios(id),
 client_id uuid not null references public.studio_clients(id),
 initial_amount numeric(12,2) not null check(initial_amount>0),
 balance numeric(12,2) not null check(balance>=0),
 expires_on date,
 created_at timestamptz not null default now()
);
create index if not exists money_pass_client_idx on public.studio_money_passes(studio_id,client_id);
alter table public.studio_money_passes enable row level security;
drop policy if exists money_pass_read on public.studio_money_passes;
create policy money_pass_read on public.studio_money_passes for select to authenticated using (
 public.is_studio_owner(studio_id) or exists (
 select 1 from public.studio_clients c where c.id=client_id and c.studio_id=studio_money_passes.studio_id
 and c.assigned_trainer_id=auth.uid() and public.my_studio_role(c.studio_id)='employee'
 ));
revoke all on public.studio_money_passes from anon,authenticated;
grant select on public.studio_money_passes to authenticated;
create table if not exists public.studio_money_pass_uses (
 request_id uuid primary key,
 pass_id uuid not null references public.studio_money_passes(id),
 kind text not null,
 amount numeric(12,2) not null check(amount>0),
 cashflow_id uuid not null unique references public.studio_cashflows(id),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.studio_money_pass_uses enable row level security;
revoke all on public.studio_money_pass_uses from anon,authenticated;
-- Покупка абонемента = поступление, списание занятия = выручка. Не суммировать их как одну выручку.
alter table public.studio_cashflows drop constraint if exists studio_cashflows_kind_check;
alter table public.studio_cashflows add constraint studio_cashflows_kind_check check(kind in ('deposit','session','expense','pass_purchase'));
alter table public.studio_cashflows drop constraint if exists studio_cashflows_method_check;
alter table public.studio_cashflows add constraint studio_cashflows_method_check check(method in ('cash','card','transfer','other','deposit','pass'));
alter table public.studio_cashflows drop constraint if exists cf_method_check;
alter table public.studio_cashflows add constraint cf_method_check check((method<>'deposit' or kind='session') and (method<>'pass' or kind='session'));
create or replace function public.create_studio_money_pass(p_client uuid,p_amount numeric,p_method text,p_expires date,p_request uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_studio uuid;v_id uuid;v_old public.studio_cashflows%rowtype;
begin
 select studio_id into v_studio from public.studio_clients where id=p_client;
 if v_studio is null or not public.is_studio_owner(v_studio) then raise exception 'Только владелец может оформлять абонементы';end if;
 if p_request is null or p_amount is null or p_amount<=0 or p_amount>10000000 or round(p_amount,2)<>p_amount or p_method not in ('cash','card','transfer','other') or (p_expires is not null and p_expires<current_date) then raise exception 'Неверные данные абонемента';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_client::text,0));
 select * into v_old from public.studio_cashflows where request_id=p_request;
 if found then
   if v_old.studio_id=v_studio and v_old.client_id=p_client and v_old.kind='pass_purchase' and v_old.amount=p_amount and v_old.method=p_method then
     select id into v_id from public.studio_money_passes where id=(v_old.note::uuid);
     if v_id is not null then return v_id;end if;
   end if;
   raise exception 'ID операции уже использован';
 end if;
 insert into public.studio_money_passes(studio_id,client_id,initial_amount,balance,expires_on)
 values(v_studio,p_client,p_amount,p_amount,p_expires) returning id into v_id;
 insert into public.studio_cashflows(request_id,studio_id,client_id,kind,amount,method,event_date,note,created_by)
 values(p_request,v_studio,p_client,'pass_purchase',p_amount,p_method,current_date,v_id::text,auth.uid());
 return v_id;
end$$;
create or replace function public.use_studio_money_pass(p_pass uuid,p_kind text,p_request uuid)
returns numeric language plpgsql security definer set search_path='' as $$
declare v_pass public.studio_money_passes%rowtype;v_actor uuid:=auth.uid();v_price numeric;v_trainer uuid;v_share numeric:=0;v_cashflow uuid;v_old public.studio_money_pass_uses%rowtype;
begin
 if p_request is null or p_kind not in ('personal','mat_split','reformer_split','group') then raise exception 'Неверная операция';end if;
 select * into v_old from public.studio_money_pass_uses where request_id=p_request;
 if found then
   if v_old.pass_id=p_pass and v_old.kind=p_kind then return (select balance from public.studio_money_passes where id=p_pass);end if;
   raise exception 'ID операции уже использован';
 end if;
 select * into v_pass from public.studio_money_passes where id=p_pass for update;
 if not found then raise exception 'Абонемент не найден';end if;
 if not public.is_studio_owner(v_pass.studio_id) and not exists (
  select 1 from public.studio_clients c where c.id=v_pass.client_id and c.studio_id=v_pass.studio_id
  and c.assigned_trainer_id=v_actor and public.my_studio_role(v_pass.studio_id)='employee'
 ) then raise exception 'Нет доступа';end if;
 if v_pass.expires_on is not null and v_pass.expires_on<current_date then raise exception 'Срок абонемента истёк';end if;
 select amount into v_price from public.studio_client_prices where client_id=v_pass.client_id and studio_id=v_pass.studio_id and kind=p_kind;
 if v_price is null or v_price<=0 then raise exception 'Сначала установите цену занятия';end if;
 if v_pass.balance<v_price then raise exception 'Недостаточно средств на абонементе. Остаток: % ₽, цена: % ₽',v_pass.balance,v_price;end if;
 select assigned_trainer_id into v_trainer from public.studio_clients where id=v_pass.client_id and studio_id=v_pass.studio_id;
 if v_trainer is not null then
   select share_percent into v_share from public.studio_members where studio_id=v_pass.studio_id and user_id=v_trainer and role='employee' and approved;
   if not found then raise exception 'Тренер не активен';end if;
 end if;
 update public.studio_money_passes set balance=balance-v_price where id=p_pass;
 insert into public.studio_cashflows(request_id,studio_id,client_id,trainer_id,kind,amount,method,share_percent,event_date,note,created_by)
 values(p_request,v_pass.studio_id,v_pass.client_id,v_trainer,'session',v_price,'pass',coalesce(v_share,0),current_date,'Списание денежного абонемента',v_actor) returning id into v_cashflow;
 insert into public.studio_money_pass_uses(request_id,pass_id,kind,amount,cashflow_id,created_by)
 values(p_request,p_pass,p_kind,v_price,v_cashflow,v_actor);
 return v_pass.balance-v_price;
end$$;
revoke all on function public.create_studio_money_pass(uuid,numeric,text,date,uuid),public.use_studio_money_pass(uuid,text,uuid) from public,anon;
grant execute on function public.create_studio_money_pass(uuid,numeric,text,date,uuid),public.use_studio_money_pass(uuid,text,uuid) to authenticated;
commit;
