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
