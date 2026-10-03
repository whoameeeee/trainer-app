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
