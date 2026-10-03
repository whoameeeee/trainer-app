-- Продвижение 6.7.1: безопасное создание студии и владельца.
-- Выполнить в Supabase SQL Editor один раз после установки базы 6.7.
-- Существующие таблицы, клиенты, тренировки и платежи не удаляются.
BEGIN;
CREATE OR REPLACE FUNCTION public.create_my_studio()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_user_id uuid := (SELECT auth.uid());
  result_studio_id uuid;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Войдите в аккаунт, чтобы создать студию';
  END IF;
  SELECT s.id INTO result_studio_id
  FROM public.studios AS s WHERE s.owner_id = current_user_id;
  IF result_studio_id IS NULL THEN
    INSERT INTO public.studios(name, owner_id)
    VALUES ('Продвижение', current_user_id)
    RETURNING id INTO result_studio_id;
  END IF;
  -- На случай, если прежний триггер не создал запись владельца.
  INSERT INTO public.studio_members(studio_id, user_id, role, approved)
  VALUES (result_studio_id, current_user_id, 'owner', true)
  ON CONFLICT (studio_id, user_id) DO UPDATE
  SET role = 'owner', approved = true;
  RETURN result_studio_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_my_studio() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_my_studio() FROM anon;
GRANT EXECUTE ON FUNCTION public.create_my_studio() TO authenticated;
COMMIT;
