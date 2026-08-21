


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "private"."concurrence_case_id"("p_hhid" "text", "p_episode_at" timestamp without time zone) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select 'CONC-' || private.concurrence_normalize_hhid(p_hhid) || '-'
    || pg_catalog.to_char(p_episode_at, 'YYYYMMDDHH24MISS');
$$;


ALTER FUNCTION "private"."concurrence_case_id"("p_hhid" "text", "p_episode_at" timestamp without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."concurrence_normalize_hhid"("p_value" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select upper(regexp_replace(btrim(coalesce(p_value, '')), '\s+', '', 'g'));
$$;


ALTER FUNCTION "private"."concurrence_normalize_hhid"("p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."concurrence_parse_timestamp"("p_value" "text") RETURNS timestamp without time zone
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
declare
  normalized text := btrim(coalesce(p_value, ''));
  parsed timestamp without time zone;
begin
  if normalized !~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' then
    return null;
  end if;

  begin
    parsed := pg_catalog.make_timestamp(
      substring(normalized from 1 for 4)::integer,
      substring(normalized from 6 for 2)::integer,
      substring(normalized from 9 for 2)::integer,
      substring(normalized from 12 for 2)::integer,
      substring(normalized from 15 for 2)::integer,
      substring(normalized from 18 for 2)::double precision
    );
  exception when others then
    return null;
  end;

  return parsed;
end;
$_$;


ALTER FUNCTION "private"."concurrence_parse_timestamp"("p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ipcr_can_edit_monitor_row"("target_hh_id" "text", "target_municipality" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select (select private.ipcr_is_editor()) or (
    (select auth.uid()) is not null
    and exists (
      select 1
      from public.staff_municipality sm
      where sm.user_id = (select auth.uid())
        and sm.municipality = target_municipality
    )
  );
$$;


ALTER FUNCTION "private"."ipcr_can_edit_monitor_row"("target_hh_id" "text", "target_municipality" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "private"."ipcr_can_edit_monitor_row"("target_hh_id" "text", "target_municipality" "text") IS 'Allows monitoring edits by editors or staff assigned to the row municipality; HHID caseload ownership is used only for assignment and attribution.';



CREATE OR REPLACE FUNCTION "private"."ipcr_can_view_all_monitor_rows"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select (select private.ipcr_is_editor())
    or exists (
      select 1
      from public.staff s
      where s.user_id = (select auth.uid())
        and s.role not in ('case_manager', 'social_welfare_assistant')
    );
$$;


ALTER FUNCTION "private"."ipcr_can_view_all_monitor_rows"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ipcr_can_view_municipality"("target_municipality" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select (select private.ipcr_is_editor())
    or exists (
      select 1 from public.staff s
      where s.user_id = (select auth.uid())
        and s.role not in ('case_manager', 'social_welfare_assistant')
    )
    or exists (
      select 1
      from public.staff_municipality sm
      where sm.user_id = (select auth.uid())
        and sm.municipality = target_municipality
    );
$$;


ALTER FUNCTION "private"."ipcr_can_view_municipality"("target_municipality" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ipcr_flag_household_profile_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if old.municipality is distinct from new.municipality
     or old.barangay is distinct from new.barangay
     or old.set_group is distinct from new.set_group
     or old.status is distinct from new.status then
    insert into public.ipcr_assignment_alert (
      period_id, hh_id, alert_type, before_data, after_data
    )
    select p.id, new.hh_id, 'profile_changed',
      jsonb_build_object(
        'municipality', old.municipality,
        'barangay', old.barangay,
        'set_group', old.set_group,
        'client_status', old.status
      ),
      jsonb_build_object(
        'municipality', new.municipality,
        'barangay', new.barangay,
        'set_group', new.set_group,
        'client_status', new.status
      )
    from public.ipcr_period p
    where p.status = 'published'
      and exists (
        select 1 from public.ipcr_household_assignment a
        where a.period_id = p.id and a.hh_id = new.hh_id
          and a.effective_to is null
      )
    on conflict (period_id, hh_id) where status = 'pending'
    do update set after_data = excluded.after_data, updated_at = now();
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."ipcr_flag_household_profile_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ipcr_is_editor"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce((select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false)
    or exists (
      select 1
      from public.staff s
      where s.user_id = (select auth.uid())
        and s.role in ('admin', 'provincial', 'swoIII', 'swoII')
    );
$$;


ALTER FUNCTION "private"."ipcr_is_editor"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ipcr_monitor_kpi_matches"("p_kpi" "jsonb", "p_data" "jsonb", "p_values" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  with rule as (
    select
      coalesce(p_kpi #>> '{match,op}', '') as op,
      coalesce(p_kpi #>> '{match,value}', '') as expected,
      case
        when jsonb_typeof(p_kpi #> '{match,values}') = 'array'
        then p_kpi #> '{match,values}'
        else '[]'::jsonb
      end as expected_values,
      case
        when coalesce(p_kpi #>> '{match,columnKey}', '') <> '' then
          coalesce(p_data ->> (p_kpi #>> '{match,columnKey}'), '')
        else
          coalesce(p_values ->> (p_kpi #>> '{match,fieldKey}'), '')
      end as actual
  )
  select case rule.op
    when 'set' then btrim(rule.actual) <> ''
    when 'notset' then btrim(rule.actual) = ''
    when 'eq' then
      case
        when jsonb_typeof(rule.expected_values) = 'array'
          and jsonb_array_length(rule.expected_values) > 0
        then exists (
          select 1
          from jsonb_array_elements_text(rule.expected_values) choice(value)
          where choice.value = rule.actual
        )
        else rule.actual = rule.expected
      end
    when 'neq' then
      case
        when jsonb_typeof(rule.expected_values) = 'array'
          and jsonb_array_length(rule.expected_values) > 0
        then not exists (
          select 1
          from jsonb_array_elements_text(rule.expected_values) choice(value)
          where choice.value = rule.actual
        )
        else rule.actual <> rule.expected
      end
    when 'true' then rule.actual = 'true'
    when 'false' then rule.actual <> 'true'
    else false
  end
  from rule;
$$;


ALTER FUNCTION "private"."ipcr_monitor_kpi_matches"("p_kpi" "jsonb", "p_data" "jsonb", "p_values" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ipcr_visible_municipalities"() RETURNS "text"[]
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce(
    array_agg(sm.municipality order by sm.municipality),
    '{}'::text[]
  )
  from public.staff_municipality sm
  where sm.user_id = (select auth.uid());
$$;


ALTER FUNCTION "private"."ipcr_visible_municipalities"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."monitor_csv_field_is_visible"("p_field_key" "text", "p_values" "jsonb", "p_data" "jsonb", "p_fields" "jsonb", "p_visiting" "text"[] DEFAULT ARRAY[]::"text"[]) RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  field_config jsonb;
  conditions jsonb;
  condition_config jsonb;
  controller_key text;
  column_key text;
  operator text;
  raw_value jsonb;
  text_value text;
  checked boolean;
  matches boolean;
  is_any boolean := false;
begin
  if p_field_key = any(coalesce(p_visiting, array[]::text[])) then
    return false;
  end if;

  select item
    into field_config
    from pg_catalog.jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) as item
   where item ->> 'key' = p_field_key
   limit 1;

  -- An unknown field is not eligible for conditional clearing.
  if field_config is null then
    return true;
  end if;

  if pg_catalog.jsonb_typeof(field_config -> 'visibleWhenAny') = 'array'
     and pg_catalog.jsonb_array_length(field_config -> 'visibleWhenAny') > 0 then
    conditions := field_config -> 'visibleWhenAny';
    is_any := true;
  elsif pg_catalog.jsonb_typeof(field_config -> 'visibleWhen') = 'object' then
    conditions := pg_catalog.jsonb_build_array(field_config -> 'visibleWhen');
  else
    return true;
  end if;

  for condition_config in
    select item
      from pg_catalog.jsonb_array_elements(conditions) as item
  loop
    controller_key := nullif(condition_config ->> 'fieldKey', '');
    column_key := nullif(condition_config ->> 'columnKey', '');

    if controller_key is null and column_key is null then
      if is_any then return true; end if;
      continue;
    end if;

    if controller_key is not null
       and not private.monitor_csv_field_is_visible(
         controller_key,
         p_values,
         p_data,
         p_fields,
         array_append(coalesce(p_visiting, array[]::text[]), p_field_key)
       ) then
      matches := false;
    else
      raw_value := case
        when column_key is not null then coalesce(p_data, '{}'::jsonb) -> column_key
        else coalesce(p_values, '{}'::jsonb) -> controller_key
      end;
      text_value := btrim(
        case
          when raw_value is null or raw_value = 'null'::jsonb then ''
          when pg_catalog.jsonb_typeof(raw_value) = 'string' then raw_value #>> '{}'
          else raw_value::text
        end
      );
      checked := raw_value = 'true'::jsonb or lower(text_value) = 'true';
      operator := coalesce(condition_config ->> 'op', 'eq');

      case operator
        when 'set' then
          matches := text_value <> '' and raw_value <> 'false'::jsonb;
        when 'notset' then
          matches := text_value = '' or raw_value = 'false'::jsonb;
        when 'eq' then
          if pg_catalog.jsonb_typeof(condition_config -> 'values') = 'array'
             and pg_catalog.jsonb_array_length(condition_config -> 'values') > 0 then
            select exists (
              select 1
                from pg_catalog.jsonb_array_elements_text(condition_config -> 'values') as choice(value)
               where choice.value = text_value
            ) into matches;
          else
            matches := text_value = coalesce(condition_config ->> 'value', '');
          end if;
        when 'neq' then
          if pg_catalog.jsonb_typeof(condition_config -> 'values') = 'array'
             and pg_catalog.jsonb_array_length(condition_config -> 'values') > 0 then
            select not exists (
              select 1
                from pg_catalog.jsonb_array_elements_text(condition_config -> 'values') as choice(value)
               where choice.value = text_value
            ) into matches;
          else
            matches := text_value <> coalesce(condition_config ->> 'value', '');
          end if;
        when 'true' then matches := checked;
        when 'false' then matches := not checked;
        else matches := true;
      end case;
    end if;

    if is_any and matches then return true; end if;
    if not is_any and not matches then return false; end if;
  end loop;

  return not is_any;
end;
$$;


ALTER FUNCTION "private"."monitor_csv_field_is_visible"("p_field_key" "text", "p_values" "jsonb", "p_data" "jsonb", "p_fields" "jsonb", "p_visiting" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."reconcile_concurrence_snapshot_impl"("p_filename" "text", "p_rows" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $_$
declare
  monitor_record public.monitor%rowtype;
  v_batch_id uuid;
  v_source_rows integer;
  v_cavite_episodes integer;
  v_duplicate_episode_keys integer;
  v_added_count integer := 0;
  v_retained_count integer := 0;
  v_returning_count integer := 0;
  v_grantee_matched_count integer := 0;
  v_protected_history_count integer := 0;
  v_archived_count integer := 0;
  v_unresolved_count integer := 0;
  v_visible_after integer := 0;
  status_field_key text;
  link_field_key text;
  yes_value text := 'Yes';
begin
  if (select auth.uid()) is null
     or not (select public.monitor_caller_is_editor()) then
    raise exception 'Editor access required';
  end if;

  if nullif(btrim(p_filename), '') is null then
    raise exception 'A source filename is required';
  end if;
  if pg_catalog.jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Concurrence rows must be a JSON array';
  end if;

  v_source_rows := pg_catalog.jsonb_array_length(p_rows);
  if v_source_rows = 0 then
    raise exception 'The file contains zero Cavite episodes';
  end if;
  if v_source_rows > 10000 then
    raise exception 'The snapshot exceeds the 10,000 row safety limit';
  end if;
  if exists (
    select 1
      from pg_catalog.jsonb_array_elements(p_rows) as element(payload)
     where pg_catalog.jsonb_typeof(element.payload) <> 'object'
        or not (element.payload ?& array[
          'listahanan_id',
          'current_address',
          'old_address',
          'new_address',
          'user_name',
          'date_inserted'
        ])
  ) then
    raise exception 'Every Concurrence row must contain all six expected columns';
  end if;

  select *
    into monitor_record
    from public.monitor
   where slug = 'for-concurrence'
   for update;
  if monitor_record.id is null then
    raise exception 'The for-concurrence monitor does not exist';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('concurrence:' || monitor_record.id::text, 0)
  );

  select field ->> 'key',
         coalesce(
           (
             select option_value
               from pg_catalog.jsonb_array_elements_text(coalesce(field -> 'options', '[]'::jsonb)) option_value
              where option_value ~* '^(yes|true|concurred)$'
              limit 1
           ),
           'Yes'
         )
    into status_field_key, yes_value
    from pg_catalog.jsonb_array_elements(coalesce(monitor_record.fields, '[]'::jsonb)) field
   where pg_catalog.regexp_replace(
     lower(coalesce(field ->> 'label', '')),
     '[^a-z0-9]+',
     ' ',
     'g'
   ) = 'is concurred'
   limit 1;

  select field ->> 'key'
    into link_field_key
    from pg_catalog.jsonb_array_elements(coalesce(monitor_record.fields, '[]'::jsonb)) field
   where lower(coalesce(field ->> 'type', '')) = 'link'
     and lower(coalesce(field ->> 'label', '')) like '%concurrence%'
   limit 1;

  if status_field_key is null or link_field_key is null then
    raise exception 'Concurrence status and endorsement-link fields must be configured';
  end if;

  drop table if exists pg_temp.concurrence_snapshot_stage;
  create temporary table concurrence_snapshot_stage (
    concurrence_case_id text primary key,
    beneficiary_hh_id text not null,
    episode_at timestamp without time zone not null,
    date_inserted text not null,
    current_address text not null,
    old_address text not null,
    new_address text not null,
    source_user text not null,
    region text not null,
    province text not null,
    municipality text not null,
    barangay text not null,
    street text not null
  ) on commit drop;
  truncate table concurrence_snapshot_stage;

  if exists (
    select 1
      from pg_catalog.jsonb_to_recordset(p_rows) as source_row(
        listahanan_id text,
        current_address text,
        old_address text,
        new_address text,
        user_name text,
        date_inserted text
      )
     where private.concurrence_normalize_hhid(source_row.listahanan_id) = ''
        or private.concurrence_parse_timestamp(source_row.date_inserted) is null
        or upper(btrim(pg_catalog.split_part(coalesce(source_row.new_address, ''), ',', 2))) <> 'CAVITE'
  ) then
    raise exception 'The snapshot contains a blank ID, invalid Date Inserted, or non-Cavite destination';
  end if;

  insert into concurrence_snapshot_stage (
    concurrence_case_id,
    beneficiary_hh_id,
    episode_at,
    date_inserted,
    current_address,
    old_address,
    new_address,
    source_user,
    region,
    province,
    municipality,
    barangay,
    street
  )
  select distinct on (private.concurrence_case_id(source_row.listahanan_id, parsed.episode_at))
    private.concurrence_case_id(source_row.listahanan_id, parsed.episode_at),
    private.concurrence_normalize_hhid(source_row.listahanan_id),
    parsed.episode_at,
    btrim(source_row.date_inserted),
    btrim(coalesce(source_row.current_address, '')),
    btrim(coalesce(source_row.old_address, '')),
    btrim(coalesce(source_row.new_address, '')),
    btrim(coalesce(source_row.user_name, '')),
    btrim(pg_catalog.split_part(source_row.new_address, ',', 1)),
    btrim(pg_catalog.split_part(source_row.new_address, ',', 2)),
    btrim(pg_catalog.split_part(source_row.new_address, ',', 3)),
    btrim(pg_catalog.split_part(source_row.new_address, ',', 4)),
    btrim(pg_catalog.regexp_replace(source_row.new_address, '^([^,]*,){4}\s*', ''))
    from pg_catalog.jsonb_to_recordset(p_rows) as source_row(
      listahanan_id text,
      current_address text,
      old_address text,
      new_address text,
      user_name text,
      date_inserted text
    )
    cross join lateral (
      select private.concurrence_parse_timestamp(source_row.date_inserted) as episode_at
    ) parsed
   order by private.concurrence_case_id(source_row.listahanan_id, parsed.episode_at);

  get diagnostics v_cavite_episodes = row_count;
  v_duplicate_episode_keys := v_source_rows - v_cavite_episodes;

  if v_cavite_episodes = 0 then
    raise exception 'The file contains zero valid Cavite episodes';
  end if;

  insert into public.concurrence_import_batch (
    monitor_id,
    filename,
    source_rows,
    cavite_episodes,
    duplicate_episode_keys,
    imported_by
  ) values (
    monitor_record.id,
    btrim(p_filename),
    v_source_rows,
    v_cavite_episodes,
    v_duplicate_episode_keys,
    (select auth.uid())
  ) returning id into v_batch_id;

  with candidates as (
    select stage.*,
           (
             select count(*)::integer
               from public.monitor_row existing_episode
              where existing_episode.monitor_id = monitor_record.id
                and existing_episode.beneficiary_hh_id = stage.beneficiary_hh_id
           ) + row_number() over (
             partition by stage.beneficiary_hh_id
             order by stage.episode_at, stage.concurrence_case_id
           )::integer as episode_no
      from concurrence_snapshot_stage stage
     where not exists (
       select 1
         from public.monitor_row existing_case
        where existing_case.monitor_id = monitor_record.id
          and existing_case.row_key = stage.concurrence_case_id
     )
  )
  insert into public.monitor_row (
    monitor_id,
    row_key,
    municipality,
    beneficiary_hh_id,
    data,
    values
  )
  select
    monitor_record.id,
    candidate.concurrence_case_id,
    candidate.municipality,
    candidate.beneficiary_hh_id,
    pg_catalog.jsonb_build_object(
      'Listahanan ID', candidate.beneficiary_hh_id,
      'Current Address', candidate.current_address,
      'Old Address', candidate.old_address,
      'New Address', candidate.new_address,
      'User', candidate.source_user,
      'Date Inserted', candidate.date_inserted,
      'Region', candidate.region,
      'Province', candidate.province,
      'Municipality', candidate.municipality,
      'Barangay', candidate.barangay,
      'Street', candidate.street,
      '__concurrence_case_id', candidate.concurrence_case_id,
      '__concurrence_episode_no', candidate.episode_no,
      '__concurrence_is_returning', candidate.episode_no > 1,
      '__concurrence_grantee_match', exists (
        select 1
          from public.grantee_list matched_grantee
         where matched_grantee.hh_id = candidate.beneficiary_hh_id
      ),
      '__concurrence_episode_at', candidate.date_inserted,
      '__concurrence_source_filename', btrim(p_filename),
      '__concurrence_import_batch_id', v_batch_id::text
    ),
    case
      when candidate.episode_no = 1
           and exists (
             select 1
               from public.grantee_list matched_grantee
              where matched_grantee.hh_id = candidate.beneficiary_hh_id
           )
        then pg_catalog.jsonb_build_object(status_field_key, yes_value)
      else '{}'::jsonb
    end
    from candidates candidate
  on conflict (monitor_id, row_key) do nothing;

  get diagnostics v_added_count = row_count;
  v_retained_count := v_cavite_episodes - v_added_count;

  select count(*)::integer
    into v_returning_count
    from public.monitor_row added_row
   where added_row.monitor_id = monitor_record.id
     and added_row.data ->> '__concurrence_import_batch_id' = v_batch_id::text
     and added_row.data ->> '__concurrence_is_returning' = 'true';

  perform public.sync_monitor_grantee_profiles(monitor_record.id);

  select count(*)::integer
    into v_protected_history_count
    from public.monitor_row historical_row
   where historical_row.monitor_id = monitor_record.id
     and not exists (
       select 1
         from concurrence_snapshot_stage stage
        where stage.concurrence_case_id = historical_row.row_key
     )
     and not exists (
       select 1
         from public.grantee_list current_grantee
        where current_grantee.hh_id = historical_row.beneficiary_hh_id
     )
     and (
       historical_row.values ->> status_field_key = yes_value
       or nullif(btrim(historical_row.values ->> link_field_key), '') is not null
       or historical_row.data ->> '__concurrence_archive_protected' = 'true'
     );

  with archived_rows as (
    insert into public.concurrence_row_archive (
      batch_id,
      monitor_id,
      original_row_id,
      concurrence_case_id,
      beneficiary_hh_id,
      row_snapshot,
      archived_by
    )
    select
      v_batch_id,
      historical_row.monitor_id,
      historical_row.id,
      historical_row.row_key,
      historical_row.beneficiary_hh_id,
      pg_catalog.to_jsonb(historical_row),
      (select auth.uid())
      from public.monitor_row historical_row
     where historical_row.monitor_id = monitor_record.id
       and not exists (
         select 1
           from concurrence_snapshot_stage stage
          where stage.concurrence_case_id = historical_row.row_key
       )
       and not exists (
         select 1
           from public.grantee_list current_grantee
          where current_grantee.hh_id = historical_row.beneficiary_hh_id
       )
       and coalesce(historical_row.values ->> status_field_key, '') <> yes_value
       and nullif(btrim(historical_row.values ->> link_field_key), '') is null
       and coalesce(historical_row.data ->> '__concurrence_archive_protected', 'false') <> 'true'
    returning original_row_id
  )
  delete from public.monitor_row active_row
   using archived_rows
   where active_row.id = archived_rows.original_row_id;
  get diagnostics v_archived_count = row_count;

  select count(*)::integer
    into v_grantee_matched_count
    from public.monitor_row matched_row
   where matched_row.monitor_id = monitor_record.id
     and matched_row.data ->> '__concurrence_grantee_match' = 'true';

  select count(*)::integer
    into v_unresolved_count
    from public.monitor_row unresolved_row
   where unresolved_row.monitor_id = monitor_record.id
     and (
       nullif(btrim(unresolved_row.beneficiary_hh_id), '') is null
       or nullif(btrim(unresolved_row.row_key), '') is null
     );

  select count(*)::integer
    into v_visible_after
    from public.monitor_row visible_row
   where visible_row.monitor_id = monitor_record.id;

  update public.concurrence_import_batch
     set added_count = v_added_count,
         retained_count = v_retained_count,
         returning_count = v_returning_count,
         grantee_matched_count = v_grantee_matched_count,
         protected_history_count = v_protected_history_count,
         archived_count = v_archived_count,
         unresolved_count = v_unresolved_count
   where id = v_batch_id;

  return pg_catalog.jsonb_build_object(
    'batch_id', v_batch_id,
    'source_rows', v_source_rows,
    'cavite_episodes', v_cavite_episodes,
    'duplicate_episode_keys', v_duplicate_episode_keys,
    'added', v_added_count,
    'retained', v_retained_count,
    'returning', v_returning_count,
    'matched', v_grantee_matched_count,
    'protected_history', v_protected_history_count,
    'archived', v_archived_count,
    'unresolved', v_unresolved_count,
    'visible_after', v_visible_after
  );
end;
$_$;


ALTER FUNCTION "private"."reconcile_concurrence_snapshot_impl"("p_filename" "text", "p_rows" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."restore_concurrence_row_impl"("p_archive_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '30s'
    AS $$
declare
  archived public.concurrence_row_archive%rowtype;
  restored_id uuid;
begin
  if (select auth.uid()) is null
     or not (select public.monitor_caller_is_editor()) then
    raise exception 'Editor access required';
  end if;

  select *
    into archived
    from public.concurrence_row_archive
   where id = p_archive_id
     and restored_at is null
   for update;
  if archived.id is null then
    raise exception 'Archived cancellation was not found or is already restored';
  end if;

  if exists (
    select 1
      from public.monitor_row current_row
     where current_row.monitor_id = archived.monitor_id
       and current_row.row_key = archived.concurrence_case_id
  ) then
    raise exception 'This exact Concurrence episode already exists';
  end if;

  restored_id := (archived.row_snapshot ->> 'id')::uuid;
  if exists (select 1 from public.monitor_row current_row where current_row.id = restored_id) then
    restored_id := gen_random_uuid();
  end if;

  insert into public.monitor_row (
    id,
    monitor_id,
    row_key,
    municipality,
    beneficiary_hh_id,
    data,
    values,
    encoded_by,
    encoded_at,
    created_at,
    updated_at
  ) values (
    restored_id,
    archived.monitor_id,
    archived.concurrence_case_id,
    archived.row_snapshot ->> 'municipality',
    archived.beneficiary_hh_id,
    pg_catalog.jsonb_set(
      coalesce(archived.row_snapshot -> 'data', '{}'::jsonb),
      array['__concurrence_archive_protected'],
      'true'::jsonb,
      true
    ),
    coalesce(archived.row_snapshot -> 'values', '{}'::jsonb),
    nullif(archived.row_snapshot ->> 'encoded_by', '')::uuid,
    nullif(archived.row_snapshot ->> 'encoded_at', '')::timestamptz,
    coalesce(nullif(archived.row_snapshot ->> 'created_at', '')::timestamptz, now()),
    coalesce(nullif(archived.row_snapshot ->> 'updated_at', '')::timestamptz, now())
  );

  update public.concurrence_row_archive
     set restored_by = (select auth.uid()),
         restored_at = now()
   where id = archived.id;

  return restored_id;
end;
$$;


ALTER FUNCTION "private"."restore_concurrence_row_impl"("p_archive_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulk_update_monitor_rows_from_csv"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_apply" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    SET "statement_timeout" TO '30s'
    AS $$
declare
  monitor_config public.monitor%rowtype;
  target_field jsonb;
  target_type text;
  target_text text;
  raw_match_mode text := btrim(coalesce(p_match_mode, ''));
  normalized_match_mode text;
  match_column text;
  person_match boolean := false;
  source_count bigint := 0;
  matched_count bigint := 0;
  changed_count bigint := 0;
  unchanged_count bigint := 0;
  conflict_count bigint := 0;
  unmatched_count bigint := 0;
  ambiguous_count bigint := 0;
  shared_household_count bigint := 0;
  cleared_value_count bigint := 0;
  current_text text;
  next_values jsonb;
  field_config jsonb;
  before_visible boolean;
  after_visible boolean;
  target_row record;
  unmatched_ids jsonb := '[]'::jsonb;
  ambiguous_ids jsonb := '[]'::jsonb;
  shared_households jsonb := '[]'::jsonb;
begin
  if (select auth.uid()) is null
     or not (select public.monitor_caller_is_editor()) then
    raise exception 'Editor access required';
  end if;

  select *
    into monitor_config
    from public.monitor
   where id = p_monitor_id
     and active = true;

  if not found then
    raise exception 'Monitoring tool not found';
  end if;
  if monitor_config.slug = 'for-concurrence' then
    raise exception 'Transfer of Residence uses its dedicated reconciliation workflow';
  end if;

  normalized_match_mode := lower(raw_match_mode);
  if normalized_match_mode = 'person_id' then
    person_match := true;
    if not exists (
      select 1
        from public.monitor_row
       where monitor_id = p_monitor_id
         and person_id is not null
       limit 1
    ) then
      raise exception 'PERSON_ID matching is unavailable for this monitoring tool';
    end if;
  elsif normalized_match_mode = 'hhid' then
    null;
  elsif left(raw_match_mode, 7) = 'column:' then
    match_column := substr(raw_match_mode, 8);
    if btrim(coalesce(match_column, '')) = ''
       or not exists (
         select 1
           from pg_catalog.jsonb_array_elements_text(
             coalesce(monitor_config.roster_columns, '[]'::jsonb)
           ) as configured(value)
          where configured.value = match_column
       ) then
      raise exception 'The selected monitoring match column does not exist';
    end if;
  else
    raise exception 'Select an existing monitoring table column to match';
  end if;

  if pg_catalog.jsonb_typeof(p_ids) <> 'array'
     or pg_catalog.jsonb_array_length(p_ids) = 0 then
    raise exception 'The CSV must contain at least one identifier';
  end if;
  if exists (
    select 1
      from pg_catalog.jsonb_array_elements(p_ids) as source(value)
     where pg_catalog.jsonb_typeof(source.value) <> 'string'
        or btrim(source.value #>> '{}') = ''
  ) then
    raise exception 'Blank or invalid CSV identifiers are not allowed';
  end if;

  create temporary table if not exists monitor_csv_source_ids (
    source_id text primary key
  ) on commit drop;
  truncate table pg_temp.monitor_csv_source_ids;

  insert into pg_temp.monitor_csv_source_ids(source_id)
  select distinct upper(regexp_replace(btrim(source.value), '[[:space:]]+', '', 'g'))
    from pg_catalog.jsonb_array_elements_text(p_ids) as source(value);

  get diagnostics source_count = row_count;
  if source_count <> pg_catalog.jsonb_array_length(p_ids) then
    raise exception 'Duplicate CSV identifiers are not allowed';
  end if;

  select item
    into target_field
    from pg_catalog.jsonb_array_elements(coalesce(monitor_config.fields, '[]'::jsonb)) as item
   where item ->> 'key' = p_field_key
   limit 1;
  if target_field is null then
    raise exception 'The selected monitoring input field does not exist';
  end if;

  target_type := target_field ->> 'type';
  if target_type not in ('dropdown', 'checkbox', 'text', 'textarea', 'link', 'date', 'number', 'qr') then
    raise exception 'The selected monitoring input field type is not supported';
  end if;
  if target_type = 'checkbox' then
    if pg_catalog.jsonb_typeof(p_target_value) <> 'boolean' then
      raise exception 'Checkbox updates require a true or false value';
    end if;
  else
    if pg_catalog.jsonb_typeof(p_target_value) not in ('string', 'number') then
      raise exception 'The fixed value must be text or a number';
    end if;
    target_text := btrim(p_target_value #>> '{}');
    if target_text = '' then
      raise exception 'The fixed value cannot be blank';
    end if;
    if target_type = 'dropdown'
       and not exists (
         select 1
           from pg_catalog.jsonb_array_elements_text(
             coalesce(target_field -> 'options', '[]'::jsonb)
           ) as option(value)
          where option.value = target_text
       ) then
      raise exception 'The fixed value is not an option for the selected dropdown';
    end if;
    if target_type = 'number' then
      begin
        perform target_text::numeric;
      exception when invalid_text_representation then
        raise exception 'The fixed value must be a number';
      end;
      if target_field ? 'min' and target_text::numeric < (target_field ->> 'min')::numeric then
        raise exception 'The fixed value is below the field minimum';
      end if;
      if target_field ? 'max' and target_text::numeric > (target_field ->> 'max')::numeric then
        raise exception 'The fixed value is above the field maximum';
      end if;
    end if;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('monitor_csv_update:' || p_monitor_id::text, 0)
  );

  create temporary table if not exists monitor_csv_matches (
    source_id text not null,
    row_id uuid not null,
    primary key (source_id, row_id)
  ) on commit drop;
  truncate table pg_temp.monitor_csv_matches;

  if person_match then
    insert into pg_temp.monitor_csv_matches(source_id, row_id)
    select source.source_id, mr.id
      from pg_temp.monitor_csv_source_ids as source
      join public.monitor_row as mr
        on mr.monitor_id = p_monitor_id
       and mr.person_id = source.source_id;
  elsif normalized_match_mode = 'hhid' then
    insert into pg_temp.monitor_csv_matches(source_id, row_id)
    select source.source_id, mr.id
      from pg_temp.monitor_csv_source_ids as source
      join public.monitor_row as mr
        on mr.monitor_id = p_monitor_id
       and mr.beneficiary_hh_id = source.source_id;
  else
    insert into pg_temp.monitor_csv_matches(source_id, row_id)
    select source.source_id, mr.id
      from public.monitor_row as mr
      join pg_temp.monitor_csv_source_ids as source
        on source.source_id = upper(
          regexp_replace(btrim(coalesce(mr.data ->> match_column, '')), '[[:space:]]+', '', 'g')
        )
     where mr.monitor_id = p_monitor_id;
  end if;

  select count(*)
    into unmatched_count
    from pg_temp.monitor_csv_source_ids as source
   where not exists (
     select 1
       from pg_temp.monitor_csv_matches as matched
      where matched.source_id = source.source_id
   );

  select coalesce(pg_catalog.jsonb_agg(sample.source_id order by sample.source_id), '[]'::jsonb)
    into unmatched_ids
    from (
      select source.source_id
        from pg_temp.monitor_csv_source_ids as source
       where not exists (
         select 1
           from pg_temp.monitor_csv_matches as matched
          where matched.source_id = source.source_id
       )
       order by source.source_id
       limit 100
    ) as sample;

  if not person_match then
    select count(*)
      into ambiguous_count
      from (
        select source_id
          from pg_temp.monitor_csv_matches
         group by source_id
        having count(*) > 1
      ) as ambiguous;

    select coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', sample.source_id, 'rows', sample.row_count)
        order by sample.source_id
      ),
      '[]'::jsonb
    )
      into ambiguous_ids
      from (
        select source_id, count(*) as row_count
          from pg_temp.monitor_csv_matches
         group by source_id
        having count(*) > 1
         order by source_id
         limit 100
      ) as sample;
  end if;

  select count(*)
    into matched_count
    from pg_temp.monitor_csv_matches as matched
   where person_match
      or not exists (
        select 1
          from pg_temp.monitor_csv_matches as duplicate_match
         where duplicate_match.source_id = matched.source_id
         group by duplicate_match.source_id
        having count(*) > 1
      );

  if person_match then
    select count(*)
      into shared_household_count
      from (
        select mr.beneficiary_hh_id
          from pg_temp.monitor_csv_matches as matched
          join public.monitor_row as mr on mr.id = matched.row_id
         where mr.beneficiary_hh_id is not null
         group by mr.beneficiary_hh_id
        having count(*) > 1
      ) as shared;

    select coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('hhid', sample.hhid, 'rows', sample.row_count)
        order by sample.hhid
      ),
      '[]'::jsonb
    )
      into shared_households
      from (
        select mr.beneficiary_hh_id as hhid, count(*) as row_count
          from pg_temp.monitor_csv_matches as matched
          join public.monitor_row as mr on mr.id = matched.row_id
         where mr.beneficiary_hh_id is not null
         group by mr.beneficiary_hh_id
        having count(*) > 1
         order by mr.beneficiary_hh_id
         limit 100
      ) as sample;
  end if;

  for target_row in
    select mr.id, mr.data, mr.values
      from pg_temp.monitor_csv_matches as matched
      join public.monitor_row as mr on mr.id = matched.row_id
     where person_match
        or not exists (
          select 1
            from pg_temp.monitor_csv_matches as duplicate_match
           where duplicate_match.source_id = matched.source_id
           group by duplicate_match.source_id
          having count(*) > 1
        )
     order by mr.id
  loop
    current_text := btrim(coalesce(target_row.values ->> p_field_key, ''));
    next_values := pg_catalog.jsonb_set(
      coalesce(target_row.values, '{}'::jsonb),
      array[p_field_key],
      p_target_value,
      true
    );

    if coalesce(target_row.values, '{}'::jsonb) -> p_field_key = p_target_value then
      unchanged_count := unchanged_count + 1;
      continue;
    end if;
    if current_text <> '' then
      conflict_count := conflict_count + 1;
    end if;

    for field_config in
      select item
        from pg_catalog.jsonb_array_elements(coalesce(monitor_config.fields, '[]'::jsonb)) as item
       where item ->> 'key' <> p_field_key
    loop
      before_visible := private.monitor_csv_field_is_visible(
        field_config ->> 'key',
        coalesce(target_row.values, '{}'::jsonb),
        coalesce(target_row.data, '{}'::jsonb),
        coalesce(monitor_config.fields, '[]'::jsonb)
      );
      after_visible := private.monitor_csv_field_is_visible(
        field_config ->> 'key',
        next_values,
        coalesce(target_row.data, '{}'::jsonb),
        coalesce(monitor_config.fields, '[]'::jsonb)
      );
      if before_visible and not after_visible and next_values ? (field_config ->> 'key') then
        next_values := next_values - (field_config ->> 'key');
        cleared_value_count := cleared_value_count + 1;
      end if;
    end loop;

    changed_count := changed_count + 1;
    if p_apply then
      update public.monitor_row
         set values = next_values,
             encoded_by = (select auth.uid()),
             encoded_at = pg_catalog.clock_timestamp()
       where id = target_row.id;
    end if;
  end loop;

  return pg_catalog.jsonb_build_object(
    'applied', p_apply,
    'source_ids', source_count,
    'matched', matched_count,
    'changed', changed_count,
    'unchanged', unchanged_count,
    'conflicts', conflict_count,
    'unmatched', unmatched_count,
    'ambiguous', ambiguous_count,
    'shared_households', shared_household_count,
    'cleared_values', cleared_value_count,
    'unmatched_ids', unmatched_ids,
    'ambiguous_ids', ambiguous_ids,
    'shared_household_samples', shared_households
  );
end;
$$;


ALTER FUNCTION "public"."bulk_update_monitor_rows_from_csv"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_apply" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."bulk_update_monitor_rows_from_csv"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_apply" boolean) IS 'Editor-only transactional preview/apply of a fixed monitoring field value matched by a configured monitoring table column; excludes Transfer of Residence.';



CREATE OR REPLACE FUNCTION "public"."bulk_update_monitor_rows_from_csv_v2"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_overwrite_existing" boolean DEFAULT true, "p_apply" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    SET "statement_timeout" TO '30s'
    AS $$
declare
  monitor_config public.monitor%rowtype;
  raw_match_mode text := btrim(coalesce(p_match_mode, ''));
  normalized_match_mode text;
  match_column text;
  person_match boolean := false;
  full_result jsonb;
  safe_result jsonb;
  safe_ids jsonb := '[]'::jsonb;
begin
  -- The core preview performs editor authorization plus all monitor, field,
  -- value, identifier, and Transfer of Residence validation before this
  -- wrapper derives its non-overwriting subset.
  full_result := public.bulk_update_monitor_rows_from_csv(
    p_monitor_id,
    p_match_mode,
    p_ids,
    p_field_key,
    p_target_value,
    false
  );

  if p_overwrite_existing then
    if p_apply then
      full_result := public.bulk_update_monitor_rows_from_csv(
        p_monitor_id,
        p_match_mode,
        p_ids,
        p_field_key,
        p_target_value,
        true
      );
    end if;
    return full_result || pg_catalog.jsonb_build_object(
      'overwrite_existing', true,
      'skipped_existing', 0
    );
  end if;

  select *
    into monitor_config
    from public.monitor
   where id = p_monitor_id
     and active = true;

  normalized_match_mode := lower(raw_match_mode);
  if normalized_match_mode = 'person_id' then
    person_match := true;
  elsif normalized_match_mode = 'hhid' then
    null;
  elsif left(raw_match_mode, 7) = 'column:' then
    match_column := substr(raw_match_mode, 8);
  end if;

  create temporary table if not exists monitor_csv_keep_source_ids (
    source_id text primary key
  ) on commit drop;
  truncate table pg_temp.monitor_csv_keep_source_ids;

  insert into pg_temp.monitor_csv_keep_source_ids(source_id)
  select distinct upper(regexp_replace(btrim(source.value), '[[:space:]]+', '', 'g'))
    from pg_catalog.jsonb_array_elements_text(p_ids) as source(value);

  create temporary table if not exists monitor_csv_keep_matches (
    source_id text not null,
    row_id uuid not null,
    primary key (source_id, row_id)
  ) on commit drop;
  truncate table pg_temp.monitor_csv_keep_matches;

  if person_match then
    insert into pg_temp.monitor_csv_keep_matches(source_id, row_id)
    select source.source_id, monitoring_row.id
      from pg_temp.monitor_csv_keep_source_ids source
      join public.monitor_row monitoring_row
        on monitoring_row.monitor_id = p_monitor_id
       and monitoring_row.person_id = source.source_id;
  elsif normalized_match_mode = 'hhid' then
    insert into pg_temp.monitor_csv_keep_matches(source_id, row_id)
    select source.source_id, monitoring_row.id
      from pg_temp.monitor_csv_keep_source_ids source
      join public.monitor_row monitoring_row
        on monitoring_row.monitor_id = p_monitor_id
       and monitoring_row.beneficiary_hh_id = source.source_id;
  else
    insert into pg_temp.monitor_csv_keep_matches(source_id, row_id)
    select source.source_id, monitoring_row.id
      from public.monitor_row monitoring_row
      join pg_temp.monitor_csv_keep_source_ids source
        on source.source_id = upper(
          regexp_replace(
            btrim(coalesce(monitoring_row.data ->> match_column, '')),
            '[[:space:]]+',
            '',
            'g'
          )
        )
     where monitoring_row.monitor_id = p_monitor_id;
  end if;

  create temporary table if not exists monitor_csv_keep_conflicts (
    source_id text primary key
  ) on commit drop;
  truncate table pg_temp.monitor_csv_keep_conflicts;

  insert into pg_temp.monitor_csv_keep_conflicts(source_id)
  select distinct matched.source_id
    from pg_temp.monitor_csv_keep_matches matched
    join public.monitor_row monitoring_row on monitoring_row.id = matched.row_id
   where (
       person_match
       or not exists (
         select 1
           from pg_temp.monitor_csv_keep_matches duplicate_match
          where duplicate_match.source_id = matched.source_id
          group by duplicate_match.source_id
         having count(*) > 1
       )
     )
     and btrim(coalesce(monitoring_row.values ->> p_field_key, '')) <> ''
     and monitoring_row.values -> p_field_key is distinct from p_target_value;

  select coalesce(pg_catalog.jsonb_agg(source.source_id order by source.source_id), '[]'::jsonb)
    into safe_ids
    from pg_temp.monitor_csv_keep_source_ids source
   where not exists (
     select 1
       from pg_temp.monitor_csv_keep_conflicts conflict
      where conflict.source_id = source.source_id
   );

  if pg_catalog.jsonb_array_length(safe_ids) > 0 then
    safe_result := public.bulk_update_monitor_rows_from_csv(
      p_monitor_id,
      p_match_mode,
      safe_ids,
      p_field_key,
      p_target_value,
      p_apply
    );
  else
    safe_result := pg_catalog.jsonb_build_object(
      'changed', 0,
      'unchanged', 0,
      'cleared_values', 0
    );
  end if;

  return full_result || pg_catalog.jsonb_build_object(
    'applied', p_apply,
    'overwrite_existing', false,
    'skipped_existing', coalesce((full_result ->> 'conflicts')::bigint, 0),
    'changed', coalesce((safe_result ->> 'changed')::bigint, 0),
    'unchanged', coalesce((safe_result ->> 'unchanged')::bigint, 0),
    'cleared_values', coalesce((safe_result ->> 'cleared_values')::bigint, 0)
  );
end;
$$;


ALTER FUNCTION "public"."bulk_update_monitor_rows_from_csv_v2"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_overwrite_existing" boolean, "p_apply" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."bulk_update_monitor_rows_from_csv_v2"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_overwrite_existing" boolean, "p_apply" boolean) IS 'Editor-only monitoring CSV preview/apply with an option to keep nonblank existing values.';



CREATE OR REPLACE FUNCTION "public"."case_list_municipality"("p_hh_id" "text", "p_muni" "text") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce(p_muni, (select g.municipality from public.grantee_list g where g.hh_id = p_hh_id))
$$;


ALTER FUNCTION "public"."case_list_municipality"("p_hh_id" "text", "p_muni" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."case_risk_counts"("p_cluster" integer DEFAULT NULL::integer) RETURNS TABLE("label" "text", "cnt" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(nullif(trim(c.risk_level), ''), '—') as label,
         count(*)::bigint as cnt
  from public.case_list c
  where p_cluster is null
     or c.municipality in (select name from public.municipality where cluster_id = p_cluster)
  group by 1
  order by cnt desc;
$$;


ALTER FUNCTION "public"."case_risk_counts"("p_cluster" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."case_typology_counts"("p_cluster" integer DEFAULT NULL::integer) RETURNS TABLE("label" "text", "cnt" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(nullif(trim(c.typology_category), ''), '—') as label,
         count(*)::bigint as cnt
  from public.case_list c
  where p_cluster is null
     or c.municipality in (select name from public.municipality where cluster_id = p_cluster)
  group by 1
  order by cnt desc;
$$;


ALTER FUNCTION "public"."case_typology_counts"("p_cluster" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_scope"() RETURNS TABLE("role" "text", "cluster_id" integer, "munis" "text"[])
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select s.role,
         s.cluster_id,
         coalesce(array_agg(sm.municipality) filter (where sm.municipality is not null), '{}')
    from public.staff s
    left join public.staff_municipality sm on sm.user_id = s.user_id
   where s.user_id = auth.uid()
   group by s.role, s.cluster_id
$$;


ALTER FUNCTION "public"."current_scope"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dashboard_municipality_metrics"("p_cluster" integer DEFAULT NULL::integer) RETURNS TABLE("municipality" "text", "active_hh" bigint, "open_cases" bigint, "closed_cases" bigint, "lhf_hh" bigint, "ip_total" bigint, "ip_active" bigint, "child_total" bigint, "child_active" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with g as (
    select
      coalesce(nullif(trim(grantee_list.municipality), ''), '—') as municipality,
      count(*) filter (where status ilike '1 - active')::bigint as active_hh,
      count(*) filter (where lhf = true)::bigint as lhf_hh,
      count(*) filter (
        where ip_affiliation is not null and ip_affiliation <> ''
      )::bigint as ip_total,
      count(*) filter (
        where status ilike '1 - active'
          and ip_affiliation is not null and ip_affiliation <> ''
      )::bigint as ip_active,
      count(*) filter (
        where birthday > (current_date - interval '18 years')
      )::bigint as child_total,
      count(*) filter (
        where status ilike '1 - active'
          and birthday > (current_date - interval '18 years')
      )::bigint as child_active
    from public.grantee_list
    where p_cluster is null
       or grantee_list.municipality in (
            select name from public.municipality where cluster_id = p_cluster
          )
    group by 1
  ),
  c as (
    select
      coalesce(nullif(trim(case_list.municipality), ''), '—') as municipality,
      count(*) filter (where status not ilike '%closed%' or status is null)::bigint as open_cases,
      count(*) filter (where status ilike '%closed%')::bigint as closed_cases
    from public.case_list
    where p_cluster is null
       or case_list.municipality in (
            select name from public.municipality where cluster_id = p_cluster
          )
    group by 1
  )
  select
    coalesce(g.municipality, c.municipality) as municipality,
    coalesce(g.active_hh, 0)    as active_hh,
    coalesce(c.open_cases, 0)   as open_cases,
    coalesce(c.closed_cases, 0) as closed_cases,
    coalesce(g.lhf_hh, 0)       as lhf_hh,
    coalesce(g.ip_total, 0)     as ip_total,
    coalesce(g.ip_active, 0)    as ip_active,
    coalesce(g.child_total, 0)  as child_total,
    coalesce(g.child_active, 0) as child_active
  from g
  full outer join c on g.municipality = c.municipality;
$$;


ALTER FUNCTION "public"."dashboard_municipality_metrics"("p_cluster" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_system_resend_secret"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if old.api_key_secret_id is not null then
    delete from vault.secrets where id = old.api_key_secret_id;
  end if;
  return old;
end;
$$;


ALTER FUNCTION "public"."delete_system_resend_secret"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_user_smtp_secret"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if old.password_secret_id is not null then
    delete from vault.secrets where id = old.password_secret_id;
  end if;
  return old;
end;
$$;


ALTER FUNCTION "public"."delete_user_smtp_secret"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_unique_account_employee_number"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  normalized_employee_no text;
  conflicting_user_id uuid;
begin
  if new.employee_no is null or btrim(new.employee_no) = '' then
    new.employee_no := null;
    return new;
  end if;

  new.employee_no := upper(btrim(new.employee_no));
  normalized_employee_no := lower(new.employee_no);

  perform pg_advisory_xact_lock(
    hashtextextended('account-employee-number:' || normalized_employee_no, 0)
  );

  if tg_table_name = 'registration_request' then
    select s.user_id
    into conflicting_user_id
    from public.staff as s
    where lower(btrim(s.employee_no)) = normalized_employee_no
      and s.user_id <> new.user_id
    limit 1;
  elsif tg_table_name = 'staff' then
    select rr.user_id
    into conflicting_user_id
    from public.registration_request as rr
    where lower(btrim(rr.employee_no)) = normalized_employee_no
      and rr.user_id <> new.user_id
    limit 1;
  end if;

  if conflicting_user_id is not null then
    raise exception using
      errcode = '23505',
      message = 'That employee number is already registered.',
      constraint = 'unique_account_employee_number';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_unique_account_employee_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_system_resend_config"() RETURNS TABLE("from_addr" "text", "reply_to" "text", "enabled" boolean, "has_api_key" boolean, "resend_api_key" "text", "updated_at" timestamp with time zone, "updated_by" "uuid")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    c.from_addr,
    c.reply_to,
    c.enabled,
    c.api_key_secret_id is not null,
    s.decrypted_secret,
    c.updated_at,
    c.updated_by
  from public.system_resend_config c
  left join vault.decrypted_secrets s on s.id = c.api_key_secret_id
  where c.id = 1;
$$;


ALTER FUNCTION "public"."get_system_resend_config"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_smtp_config"("p_user_id" "uuid") RETURNS TABLE("host" "text", "port" integer, "username" "text", "from_addr" "text", "enabled" boolean, "has_password" boolean, "smtp_password" "text", "updated_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    c.host,
    c.port,
    c.username,
    c.from_addr,
    c.enabled,
    c.password_secret_id is not null,
    s.decrypted_secret,
    c.updated_at
  from public.user_smtp_config c
  left join vault.decrypted_secrets s on s.id = c.password_secret_id
  where c.user_id = p_user_id;
$$;


ALTER FUNCTION "public"."get_user_smtp_config"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grantee_active_demographics"("p_cluster" integer DEFAULT NULL::integer) RETURNS TABLE("dim" "text", "label" "text", "cnt" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with active as (
    select sex, birthday
    from public.grantee_list
    where status ilike '1 - active'
      and (
        p_cluster is null
        or municipality in (select name from public.municipality where cluster_id = p_cluster)
      )
  )
  select 'sex' as dim,
         case
           when lower(trim(sex)) in ('m', 'male') then 'Male'
           when lower(trim(sex)) in ('f', 'female') then 'Female'
           else 'Unknown'
         end as label,
         count(*)::bigint as cnt
  from active
  group by 2

  union all

  select 'age' as dim,
         case
           when birthday is null then 'Unknown'
           when extract(year from age(birthday)) < 18 then '<18'
           when extract(year from age(birthday)) <= 30 then '18-30'
           when extract(year from age(birthday)) <= 45 then '31-45'
           when extract(year from age(birthday)) <= 59 then '46-59'
           else '60+'
         end as label,
         count(*)::bigint as cnt
  from active
  group by 2;
$$;


ALTER FUNCTION "public"."grantee_active_demographics"("p_cluster" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grantee_municipality_counts"("p_cluster" integer DEFAULT NULL::integer) RETURNS TABLE("label" "text", "cnt" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(nullif(trim(g.municipality), ''), '—') as label,
         count(*)::bigint as cnt
  from public.grantee_list g
  where p_cluster is null
     or g.municipality in (select name from public.municipality where cluster_id = p_cluster)
  group by 1
  order by cnt desc;
$$;


ALTER FUNCTION "public"."grantee_municipality_counts"("p_cluster" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grantee_status_counts"("p_cluster" integer DEFAULT NULL::integer) RETURNS TABLE("label" "text", "cnt" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(nullif(trim(g.status), ''), '—') as label,
         count(*)::bigint as cnt
  from public.grantee_list g
  where p_cluster is null
     or g.municipality in (select name from public.municipality where cluster_id = p_cluster)
  group by 1
  order by cnt desc;
$$;


ALTER FUNCTION "public"."grantee_status_counts"("p_cluster" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_admin_caseload_summary"("p_period_id" "uuid") RETURNS TABLE("user_id" "uuid", "staff_name" "text", "staff_role" "text", "municipality" "text", "caseload_households" bigint, "monitoring_entries" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with assignment_candidates as materialized (
    select r.scope_value as hh_id, r.municipality,
      r.responsible_cm_user_id, 2 as priority
    from public.ipcr_assignment_rule r
    where r.period_id = p_period_id and r.scope_type = 'hhid'
      and r.barangay_key = '' and r.status in ('draft', 'published')
    union all
    select a.hh_id, a.municipality, a.responsible_cm_user_id, 1 as priority
    from public.ipcr_household_assignment a
    where a.period_id = p_period_id and a.effective_to is null
  ), effective_assignments as materialized (
    select distinct on (candidate.hh_id) candidate.hh_id,
      candidate.municipality, candidate.responsible_cm_user_id
    from assignment_candidates candidate
    order by candidate.hh_id, candidate.priority desc
  ), monitor_counts as materialized (
    select mr.beneficiary_hh_id as hh_id, count(*)::bigint as monitor_count
    from public.monitor_row mr
    where mr.beneficiary_hh_id is not null
    group by mr.beneficiary_hh_id
  )
  select assignment.responsible_cm_user_id, coalesce(staff.full_name, 'Unnamed staff'),
    staff.role::text, assignment.municipality,
    count(*)::bigint, coalesce(sum(monitors.monitor_count), 0)::bigint
  from effective_assignments assignment
  join public.staff staff on staff.user_id = assignment.responsible_cm_user_id
  left join monitor_counts monitors on monitors.hh_id = assignment.hh_id
  group by assignment.responsible_cm_user_id, staff.full_name, staff.role, assignment.municipality
  order by staff.full_name, assignment.municipality;
$$;


ALTER FUNCTION "public"."ipcr_admin_caseload_summary"("p_period_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_assign_filtered_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangays" "text"[] DEFAULT NULL::"text"[], "p_set_groups" "text"[] DEFAULT NULL::"text"[], "p_query" "text" DEFAULT NULL::"text", "p_assignment" "text" DEFAULT 'all'::"text", "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_monitoring" "text" DEFAULT 'all'::"text", "p_client_status" "text" DEFAULT NULL::"text", "p_excluded_hhids" "text"[] DEFAULT '{}'::"text"[], "p_cm_id" "uuid" DEFAULT NULL::"uuid", "p_actor_id" "uuid" DEFAULT NULL::"uuid", "p_as_proposal" boolean DEFAULT false, "p_reason" "text" DEFAULT NULL::"text") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_count bigint := 0;
begin
  if p_period_id is null or p_cm_id is null or p_actor_id is null then
    raise exception 'Period, Case Manager, and actor are required';
  end if;
  if p_municipality is null or btrim(p_municipality) = '' then
    raise exception 'Select one municipality before assigning all filtered households';
  end if;
  if p_as_proposal and coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reason is required for assignment proposals';
  end if;
  if not exists (
    select 1
    from public.staff s
    join public.staff_municipality sm on sm.user_id = s.user_id
    where s.user_id = p_cm_id
      and s.role = 'case_manager'
      and s.is_active = true
      and sm.municipality = p_municipality
  ) then
    raise exception 'The selected Case Manager does not cover this municipality';
  end if;

  if p_as_proposal then
    with period_settings as materialized (
      select eligible_client_statuses
      from public.ipcr_period
      where id = p_period_id and status <> 'closed'
    ), effective_assignments as materialized (
      select distinct on (candidate.hh_id)
        candidate.hh_id,
        candidate.responsible_cm_user_id
      from (
        select r.scope_value as hh_id, r.responsible_cm_user_id, 2 as priority
        from public.ipcr_assignment_rule r
        where r.period_id = p_period_id and r.scope_type = 'hhid'
          and r.barangay_key = '' and r.status in ('draft', 'published')
        union all
        select a.hh_id, a.responsible_cm_user_id, 1 as priority
        from public.ipcr_household_assignment a
        where a.period_id = p_period_id and a.effective_to is null
      ) candidate
      order by candidate.hh_id, candidate.priority desc
    ), monitor_counts as materialized (
      select mr.beneficiary_hh_id as hh_id, count(*)::bigint as monitor_count
      from public.monitor_row mr where mr.beneficiary_hh_id is not null
      group by mr.beneficiary_hh_id
    ), candidates as materialized (
      select g.hh_id, g.municipality
      from public.grantee_list g
      cross join period_settings settings
      left join effective_assignments assignment on assignment.hh_id = g.hh_id
      left join monitor_counts monitors on monitors.hh_id = g.hh_id
      where g.municipality = p_municipality
        and (p_barangays is null or cardinality(p_barangays) = 0 or g.barangay = any(p_barangays))
        and (p_set_groups is null or cardinality(p_set_groups) = 0 or btrim(g.set_group) = any(p_set_groups))
        and (p_client_status is null or g.status = p_client_status)
        and (cardinality(settings.eligible_client_statuses) = 0 or g.status = any(settings.eligible_client_statuses))
        and (p_query is null or p_query = '' or g.hh_id ilike '%' || p_query || '%' or g.grantee_name ilike '%' || p_query || '%')
        and not (g.hh_id = any(coalesce(p_excluded_hhids, '{}'::text[])))
        and case p_assignment
          when 'assigned' then assignment.hh_id is not null
          when 'unassigned' then assignment.hh_id is null
          when 'mine' then assignment.responsible_cm_user_id = p_user_id
          else true
        end
        and case p_monitoring
          when 'with' then monitors.hh_id is not null
          when 'without' then monitors.hh_id is null
          else true
        end
    )
    insert into public.ipcr_assignment_proposal (
      period_id, hh_id, municipality, requested_worker_user_id,
      requested_cm_user_id, reason, proposed_by
    )
    select p_period_id, c.hh_id, c.municipality, p_cm_id,
      p_cm_id, btrim(p_reason), p_actor_id
    from candidates c
    where not exists (
      select 1 from public.ipcr_assignment_proposal proposal
      where proposal.period_id = p_period_id
        and proposal.hh_id = c.hh_id
        and proposal.status = 'pending'
    );
    get diagnostics v_count = row_count;
  else
    with period_settings as materialized (
      select eligible_client_statuses
      from public.ipcr_period
      where id = p_period_id and status <> 'closed'
    ), effective_assignments as materialized (
      select distinct on (candidate.hh_id)
        candidate.hh_id,
        candidate.responsible_cm_user_id
      from (
        select r.scope_value as hh_id, r.responsible_cm_user_id, 2 as priority
        from public.ipcr_assignment_rule r
        where r.period_id = p_period_id and r.scope_type = 'hhid'
          and r.barangay_key = '' and r.status in ('draft', 'published')
        union all
        select a.hh_id, a.responsible_cm_user_id, 1 as priority
        from public.ipcr_household_assignment a
        where a.period_id = p_period_id and a.effective_to is null
      ) candidate
      order by candidate.hh_id, candidate.priority desc
    ), monitor_counts as materialized (
      select mr.beneficiary_hh_id as hh_id, count(*)::bigint as monitor_count
      from public.monitor_row mr where mr.beneficiary_hh_id is not null
      group by mr.beneficiary_hh_id
    ), candidates as materialized (
      select g.hh_id, g.municipality
      from public.grantee_list g
      cross join period_settings settings
      left join effective_assignments assignment on assignment.hh_id = g.hh_id
      left join monitor_counts monitors on monitors.hh_id = g.hh_id
      where g.municipality = p_municipality
        and (p_barangays is null or cardinality(p_barangays) = 0 or g.barangay = any(p_barangays))
        and (p_set_groups is null or cardinality(p_set_groups) = 0 or btrim(g.set_group) = any(p_set_groups))
        and (p_client_status is null or g.status = p_client_status)
        and (cardinality(settings.eligible_client_statuses) = 0 or g.status = any(settings.eligible_client_statuses))
        and (p_query is null or p_query = '' or g.hh_id ilike '%' || p_query || '%' or g.grantee_name ilike '%' || p_query || '%')
        and not (g.hh_id = any(coalesce(p_excluded_hhids, '{}'::text[])))
        and case p_assignment
          when 'assigned' then assignment.hh_id is not null
          when 'unassigned' then assignment.hh_id is null
          when 'mine' then assignment.responsible_cm_user_id = p_user_id
          else true
        end
        and case p_monitoring
          when 'with' then monitors.hh_id is not null
          when 'without' then monitors.hh_id is null
          else true
        end
    )
    insert into public.ipcr_assignment_rule (
      period_id, scope_type, municipality, municipality_key, barangay,
      barangay_key, scope_value, scope_value_key, primary_worker_user_id,
      responsible_cm_user_id, status, created_by, approved_by, approved_at
    )
    select p_period_id, 'hhid', c.municipality, upper(btrim(c.municipality)), null,
      '', c.hh_id, upper(btrim(c.hh_id)), p_cm_id, p_cm_id, 'draft',
      p_actor_id, null, null
    from candidates c
    on conflict (period_id, scope_type, municipality_key, barangay_key, scope_value_key)
    do update set
      primary_worker_user_id = excluded.primary_worker_user_id,
      responsible_cm_user_id = excluded.responsible_cm_user_id,
      status = 'draft',
      created_by = excluded.created_by,
      approved_by = null,
      approved_at = null,
      updated_at = now();
    get diagnostics v_count = row_count;
  end if;

  return v_count;
end;
$$;


ALTER FUNCTION "public"."ipcr_assign_filtered_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangays" "text"[], "p_set_groups" "text"[], "p_query" "text", "p_assignment" "text", "p_user_id" "uuid", "p_monitoring" "text", "p_client_status" "text", "p_excluded_hhids" "text"[], "p_cm_id" "uuid", "p_actor_id" "uuid", "p_as_proposal" boolean, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_assignment_summary"("p_period_id" "uuid", "p_municipalities" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("total_households" bigint, "assigned_households" bigint, "unassigned_households" bigint, "awaiting_review" bigint, "needs_review" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with period_settings as materialized (
    select period.eligible_client_statuses, period.conflict_count
    from public.ipcr_period period
    where period.id = p_period_id
  ), eligible_households as materialized (
    select distinct g.hh_id, g.municipality
    from public.grantee_list g
    cross join period_settings settings
    where (
        p_municipalities is null
        or g.municipality = any(p_municipalities)
      )
      and (
        cardinality(settings.eligible_client_statuses) = 0
        or g.status = any(settings.eligible_client_statuses)
      )
  ), assignment_candidates as materialized (
    select r.scope_value as hh_id, 2 as priority
    from public.ipcr_assignment_rule r
    where r.period_id = p_period_id
      and r.scope_type = 'hhid'
      and r.barangay_key = ''
      and r.status in ('draft', 'published')
    union all
    select a.hh_id, 1 as priority
    from public.ipcr_household_assignment a
    where a.period_id = p_period_id
      and a.effective_to is null
  ), effective_assignments as materialized (
    select distinct on (candidate.hh_id) candidate.hh_id
    from assignment_candidates candidate
    order by candidate.hh_id, candidate.priority desc
  ), household_totals as materialized (
    select
      count(*)::bigint as total_count,
      count(assignment.hh_id)::bigint as assigned_count
    from eligible_households household
    left join effective_assignments assignment on assignment.hh_id = household.hh_id
  )
  select
    totals.total_count,
    totals.assigned_count,
    greatest(totals.total_count - totals.assigned_count, 0::bigint),
    (
      select count(*)::bigint
      from public.ipcr_assignment_proposal proposal
      where proposal.period_id = p_period_id
        and proposal.status = 'pending'
        and (
          p_municipalities is null
          or proposal.municipality = any(p_municipalities)
        )
    ) + (
      select count(*)::bigint
      from public.ipcr_supervision supervision
      where supervision.period_id = p_period_id
        and supervision.status = 'pending'
        and (
          p_municipalities is null
          or supervision.municipality = any(p_municipalities)
        )
    ),
    (
      select count(*)::bigint
      from public.ipcr_assignment_alert alert
      where alert.period_id = p_period_id
        and alert.status = 'pending'
        and (
          p_municipalities is null
          or exists (
            select 1
            from public.grantee_list g
            where g.hh_id = alert.hh_id
              and g.municipality = any(p_municipalities)
          )
        )
    ) + case
      when p_municipalities is null then settings.conflict_count::bigint
      else 0::bigint
    end
  from household_totals totals
  cross join period_settings settings;
$$;


ALTER FUNCTION "public"."ipcr_assignment_summary"("p_period_id" "uuid", "p_municipalities" "text"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."ipcr_assignment_summary"("p_period_id" "uuid", "p_municipalities" "text"[]) IS 'Returns Caseload Inventory assignment KPI totals for an optional municipality scope.';



CREATE OR REPLACE FUNCTION "public"."ipcr_client_status_options"() RETURNS TABLE("client_status" "text", "household_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select btrim(g.status), count(*)::bigint
  from public.grantee_list g
  where g.status is not null and btrim(g.status) <> ''
  group by btrim(g.status)
  order by btrim(g.status);
$$;


ALTER FUNCTION "public"."ipcr_client_status_options"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_my_caseload_scorecard"("p_period_id" "uuid", "p_user_id" "uuid") RETURNS TABLE("caseload_households" bigint, "monitoring_entries" bigint, "accomplished_entries" bigint, "variance_entries" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with assignment_candidates as materialized (
    select
      r.scope_value as hh_id,
      r.municipality,
      r.primary_worker_user_id,
      r.responsible_cm_user_id,
      2 as priority
    from public.ipcr_assignment_rule r
    where r.period_id = p_period_id
      and r.scope_type = 'hhid'
      and r.barangay_key = ''
      and r.status in ('draft', 'published')

    union all

    select
      a.hh_id,
      a.municipality,
      a.primary_worker_user_id,
      a.responsible_cm_user_id,
      1 as priority
    from public.ipcr_household_assignment a
    where a.period_id = p_period_id
      and a.effective_to is null
  ), effective_assignments as materialized (
    select distinct on (candidate.hh_id)
      candidate.hh_id,
      candidate.municipality,
      candidate.primary_worker_user_id,
      candidate.responsible_cm_user_id
    from assignment_candidates candidate
    order by candidate.hh_id, candidate.priority desc
  ), my_households as materialized (
    select assignment.hh_id
    from effective_assignments assignment
    where assignment.responsible_cm_user_id = p_user_id
       or assignment.primary_worker_user_id = p_user_id
       or exists (
         select 1
         from public.ipcr_supervision supervision
         where supervision.period_id = p_period_id
           and supervision.municipality = assignment.municipality
           and supervision.case_manager_user_id = assignment.responsible_cm_user_id
           and supervision.swa_user_id = p_user_id
           and supervision.status = 'approved'
       )
  ), monitoring_targets as materialized (
    select
      mr.id,
      coalesce(mr.data, '{}'::jsonb) as row_data,
      coalesce(mr.values, '{}'::jsonb) as row_values,
      case
        when jsonb_typeof(monitor.fields) = 'array' then monitor.fields
        else '[]'::jsonb
      end as fields,
      case
        when jsonb_typeof(monitor.kpis) = 'array' then monitor.kpis
        else '[]'::jsonb
      end as kpis,
      monitor.client_status_key
    from public.monitor_row mr
    join my_households household
      on household.hh_id = mr.beneficiary_hh_id
    join public.monitor monitor
      on monitor.id = mr.monitor_id
    where monitor.active = true
      and coalesce(monitor.status, 'open') <> 'hidden'
  ), auto_status as (
    select
      target.*,
      (
        -- Auto-accomplished KPI rules always feed My Caseload Accomplished.
        exists (
          select 1
          from jsonb_array_elements(target.kpis) kpi(value)
          where coalesce(kpi.value ->> 'disabled', 'false') <> 'true'
            and coalesce(kpi.value ->> 'autoAccomplished', 'false') = 'true'
            and private.ipcr_monitor_kpi_matches(
              kpi.value,
              target.row_data,
              target.row_values
            )
        )
        or (
          -- Preserve legacy Approved TOR behavior until an editor saves an
          -- explicit auto-accomplished configuration.
          target.client_status_key is not null
          and not exists (
            select 1
            from jsonb_array_elements(target.kpis) kpi(value)
            where kpi.value ->> 'key' = '__approved_tor_auto__'
               or kpi.value ? 'autoAccomplished'
          )
          and target.row_data ->> target.client_status_key = 'Approved TOR'
        )
      ) as auto_accomplished
    from monitoring_targets target
  ), kpi_status as (
    select
      target.id,
      target.auto_accomplished,
      exists (
        select 1
        from jsonb_array_elements(target.kpis) kpi(value)
        where coalesce(kpi.value ->> 'disabled', 'false') <> 'true'
          and (
            coalesce(kpi.value ->> 'autoAccomplished', 'false') = 'true'
            or kpi.value ->> 'scorecardRole' = 'accomplished'
            or (
              not (kpi.value ? 'scorecardRole')
              and lower(btrim(coalesce(kpi.value ->> 'label', ''))) = 'accomplished'
            )
          )
      ) as has_accomplished_mapping,
      (
        target.auto_accomplished
        or exists (
          select 1
          from jsonb_array_elements(target.kpis) kpi(value)
          where coalesce(kpi.value ->> 'disabled', 'false') <> 'true'
            and (
              kpi.value ->> 'scorecardRole' = 'accomplished'
              or (
                not (kpi.value ? 'scorecardRole')
                and lower(btrim(coalesce(kpi.value ->> 'label', ''))) = 'accomplished'
              )
            )
            and private.ipcr_monitor_kpi_matches(
              kpi.value,
              target.row_data,
              target.row_values
            )
            and (
              coalesce(kpi.value ->> 'excludeAutoAccomplished', 'false') <> 'true'
              or not target.auto_accomplished
            )
        )
      ) as mapped_accomplished,
      exists (
        select 1
        from jsonb_array_elements(target.kpis) kpi(value)
        where coalesce(kpi.value ->> 'disabled', 'false') <> 'true'
          and (
            kpi.value ->> 'scorecardRole' = 'variance'
            or (
              not (kpi.value ? 'scorecardRole')
              and lower(btrim(coalesce(kpi.value ->> 'label', ''))) = 'variance'
            )
          )
      ) as has_variance_mapping,
      exists (
        select 1
        from jsonb_array_elements(target.kpis) kpi(value)
        where coalesce(kpi.value ->> 'disabled', 'false') <> 'true'
          and (
            kpi.value ->> 'scorecardRole' = 'variance'
            or (
              not (kpi.value ? 'scorecardRole')
              and lower(btrim(coalesce(kpi.value ->> 'label', ''))) = 'variance'
            )
          )
          and private.ipcr_monitor_kpi_matches(
            kpi.value,
            target.row_data,
            target.row_values
          )
          and (
            coalesce(kpi.value ->> 'excludeAutoAccomplished', 'false') <> 'true'
            or not target.auto_accomplished
          )
      ) as mapped_variance,
      case
        when exists (
          select 1
          from jsonb_array_elements(target.fields) field(value)
          where coalesce(field.value ->> 'required', 'false') = 'true'
            and coalesce(field.value ->> 'editorOnly', 'false') <> 'true'
            and coalesce(field.value ->> 'type', '') <> 'checkbox'
        ) then not exists (
          select 1
          from jsonb_array_elements(target.fields) field(value)
          where coalesce(field.value ->> 'required', 'false') = 'true'
            and coalesce(field.value ->> 'editorOnly', 'false') <> 'true'
            and coalesce(field.value ->> 'type', '') <> 'checkbox'
            and btrim(coalesce(target.row_values ->> (field.value ->> 'key'), '')) = ''
        )
        else exists (
          select 1
          from jsonb_array_elements(target.fields) field(value)
          where coalesce(field.value ->> 'editorOnly', 'false') <> 'true'
            and coalesce(field.value ->> 'type', '') <> 'checkbox'
            and btrim(coalesce(target.row_values ->> (field.value ->> 'key'), '')) <> ''
        )
      end as fallback_accomplished
    from auto_status target
  ), completion_status as (
    select
      status.id,
      status.has_variance_mapping,
      status.mapped_variance,
      (
        status.mapped_accomplished
        or (
          not status.has_accomplished_mapping
          and status.fallback_accomplished
        )
      ) as accomplished
    from kpi_status status
  ), classified as (
    select
      status.id,
      status.accomplished,
      case
        when status.has_variance_mapping then status.mapped_variance
        else not status.accomplished
      end as variance
    from completion_status status
  )
  select
    (select count(*) from my_households)::bigint,
    (select count(*) from classified)::bigint,
    (select count(*) from classified where accomplished)::bigint,
    (select count(*) from classified where variance)::bigint;
$$;


ALTER FUNCTION "public"."ipcr_my_caseload_scorecard"("p_period_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."ipcr_my_caseload_scorecard"("p_period_id" "uuid", "p_user_id" "uuid") IS 'Returns assigned HHIDs and monitoring entry accomplishment totals for one staff member and assignment period.';



CREATE OR REPLACE FUNCTION "public"."ipcr_publish_period"("p_period_id" "uuid", "p_actor_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_now timestamptz := now();
  v_households integer := 0;
  v_assigned integer := 0;
begin
  if not exists (
    select 1 from public.staff
    where user_id = p_actor_id
      and role in ('admin', 'provincial', 'swoIII', 'swoII')
  ) and not exists (
    select 1 from auth.users
    where id = p_actor_id
      and raw_app_meta_data ->> 'role' = 'admin'
  ) then
    raise exception 'Only IPCR editors can publish assignments';
  end if;

  if not exists (select 1 from public.ipcr_period where id = p_period_id) then
    raise exception 'Assignment period not found';
  end if;

  if exists (
    select 1 from public.ipcr_period
    where id = p_period_id and status = 'closed'
  ) then
    raise exception 'Closed assignment periods cannot be republished';
  end if;

  if not exists (
    select 1 from public.ipcr_assignment_rule
    where period_id = p_period_id and status in ('draft', 'published')
  ) then
    raise exception 'Add at least one assignment rule before publishing';
  end if;

  if exists (
    select 1
    from public.ipcr_assignment_rule r
    left join public.staff w on w.user_id = r.primary_worker_user_id
    left join public.staff cm on cm.user_id = r.responsible_cm_user_id
    where r.period_id = p_period_id
      and r.status in ('draft', 'published')
      and (
        coalesce(w.role, '') not in ('case_manager', 'social_welfare_assistant')
        or coalesce(cm.role, '') <> 'case_manager'
        or (w.role = 'case_manager' and w.user_id <> cm.user_id)
        or (
          w.role = 'social_welfare_assistant'
          and not exists (
            select 1 from public.ipcr_supervision sp
            where sp.period_id = p_period_id
              and sp.swa_user_id = w.user_id
              and sp.case_manager_user_id = cm.user_id
              and sp.municipality = r.municipality
              and sp.status = 'approved'
          )
        )
      )
  ) then
    raise exception 'A rule has an invalid worker, Case Manager, or SWA supervision mapping';
  end if;

  -- Close the previously live period before publishing this version.
  update public.ipcr_period
  set status = 'closed', updated_at = v_now
  where status = 'published' and id <> p_period_id;

  update public.ipcr_assignment_rule
  set status = 'published', approved_by = p_actor_id,
      approved_at = v_now, updated_at = v_now
  where period_id = p_period_id and status = 'draft';

  -- Audit and close materialized assignments that no longer match the winning
  -- rule. The winning rule is deterministic and follows the agreed precedence.
  with classifications as (
    select upper(btrim(set_group_code)) as code_key, classification
    from public.ipcr_set_group_classification
  ), candidates as (
    select g.hh_id, r.id as rule_id, r.primary_worker_user_id,
      r.responsible_cm_user_id,
      case r.scope_type
        when 'hhid' then 500
        when 'set_group' then 400
        when 'classification' then 300
        when 'barangay' then 200
        when 'municipality' then 100
      end as priority
    from public.grantee_list g
    join public.ipcr_assignment_rule r
      on r.period_id = p_period_id
     and r.status = 'published'
     and r.municipality_key = upper(btrim(coalesce(g.municipality, '')))
    left join classifications c
      on c.code_key = upper(btrim(coalesce(g.set_group, '')))
    where case r.scope_type
      when 'hhid' then r.scope_value_key = upper(btrim(g.hh_id))
      when 'set_group' then
        r.scope_value_key = upper(btrim(coalesce(g.set_group, '')))
        and (r.barangay_key = '' or r.barangay_key = upper(btrim(coalesce(g.barangay, ''))))
      when 'classification' then
        r.scope_value_key = upper(btrim(coalesce(c.classification, '')))
        and (r.barangay_key = '' or r.barangay_key = upper(btrim(coalesce(g.barangay, ''))))
      when 'barangay' then r.barangay_key = upper(btrim(coalesce(g.barangay, '')))
      when 'municipality' then true
      else false end
  ), ranked as (
    select *, row_number() over (
      partition by hh_id order by priority desc, rule_id
    ) as rn
    from candidates
  ), resolved as (
    select * from ranked where rn = 1
  ), changing as (
    select a.*
    from public.ipcr_household_assignment a
    where a.period_id = p_period_id
      and a.effective_to is null
      and not exists (
        select 1 from resolved x
        where x.hh_id = a.hh_id
          and x.rule_id = a.source_rule_id
          and x.primary_worker_user_id = a.primary_worker_user_id
          and x.responsible_cm_user_id = a.responsible_cm_user_id
      )
  )
  insert into public.ipcr_assignment_audit (
    period_id, entity_type, entity_id, action, actor_user_id, before_data
  )
  select p_period_id, 'household_assignment', id::text, 'closed', p_actor_id,
    jsonb_build_object(
      'hh_id', hh_id,
      'primary_worker_user_id', primary_worker_user_id,
      'responsible_cm_user_id', responsible_cm_user_id,
      'source_rule_id', source_rule_id,
      'effective_from', effective_from
    )
  from changing;

  with classifications as (
    select upper(btrim(set_group_code)) as code_key, classification
    from public.ipcr_set_group_classification
  ), candidates as (
    select g.hh_id, r.id as rule_id, r.primary_worker_user_id,
      r.responsible_cm_user_id,
      case r.scope_type when 'hhid' then 500 when 'set_group' then 400
        when 'classification' then 300 when 'barangay' then 200 else 100 end as priority
    from public.grantee_list g
    join public.ipcr_assignment_rule r
      on r.period_id = p_period_id and r.status = 'published'
     and r.municipality_key = upper(btrim(coalesce(g.municipality, '')))
    left join classifications c on c.code_key = upper(btrim(coalesce(g.set_group, '')))
    where case r.scope_type
      when 'hhid' then r.scope_value_key = upper(btrim(g.hh_id))
      when 'set_group' then r.scope_value_key = upper(btrim(coalesce(g.set_group, '')))
        and (r.barangay_key = '' or r.barangay_key = upper(btrim(coalesce(g.barangay, ''))))
      when 'classification' then r.scope_value_key = upper(btrim(coalesce(c.classification, '')))
        and (r.barangay_key = '' or r.barangay_key = upper(btrim(coalesce(g.barangay, ''))))
      when 'barangay' then r.barangay_key = upper(btrim(coalesce(g.barangay, '')))
      when 'municipality' then true else false end
  ), ranked as (
    select *, row_number() over (partition by hh_id order by priority desc, rule_id) rn
    from candidates
  ), resolved as (select * from ranked where rn = 1)
  update public.ipcr_household_assignment a
  set effective_to = v_now
  where a.period_id = p_period_id and a.effective_to is null
    and not exists (
      select 1 from resolved x
      where x.hh_id = a.hh_id and x.rule_id = a.source_rule_id
        and x.primary_worker_user_id = a.primary_worker_user_id
        and x.responsible_cm_user_id = a.responsible_cm_user_id
    );

  with classifications as (
    select upper(btrim(set_group_code)) as code_key, classification
    from public.ipcr_set_group_classification
  ), candidates as (
    select g.hh_id, g.municipality, g.barangay, g.set_group, g.grantee_name,
      r.id as rule_id, r.primary_worker_user_id, r.responsible_cm_user_id,
      case r.scope_type when 'hhid' then 500 when 'set_group' then 400
        when 'classification' then 300 when 'barangay' then 200 else 100 end as priority
    from public.grantee_list g
    join public.ipcr_assignment_rule r
      on r.period_id = p_period_id and r.status = 'published'
     and r.municipality_key = upper(btrim(coalesce(g.municipality, '')))
    left join classifications c on c.code_key = upper(btrim(coalesce(g.set_group, '')))
    where case r.scope_type
      when 'hhid' then r.scope_value_key = upper(btrim(g.hh_id))
      when 'set_group' then r.scope_value_key = upper(btrim(coalesce(g.set_group, '')))
        and (r.barangay_key = '' or r.barangay_key = upper(btrim(coalesce(g.barangay, ''))))
      when 'classification' then r.scope_value_key = upper(btrim(coalesce(c.classification, '')))
        and (r.barangay_key = '' or r.barangay_key = upper(btrim(coalesce(g.barangay, ''))))
      when 'barangay' then r.barangay_key = upper(btrim(coalesce(g.barangay, '')))
      when 'municipality' then true else false end
  ), ranked as (
    select *, row_number() over (partition by hh_id order by priority desc, rule_id) rn
    from candidates
  ), resolved as (select * from ranked where rn = 1)
  insert into public.ipcr_household_assignment (
    period_id, hh_id, municipality, barangay, set_group, grantee_name,
    primary_worker_user_id, responsible_cm_user_id, source_rule_id,
    effective_from, assigned_by, assignment_reason
  )
  select p_period_id, x.hh_id, x.municipality, x.barangay, x.set_group,
    x.grantee_name, x.primary_worker_user_id, x.responsible_cm_user_id,
    x.rule_id, v_now, p_actor_id, 'Published assignment rules'
  from resolved x
  where not exists (
    select 1 from public.ipcr_household_assignment a
    where a.period_id = p_period_id and a.hh_id = x.hh_id
      and a.effective_to is null
  );

  -- Ownership did not change, but keep the current Grantee List profile on the
  -- materialized assignment so filters and review screens show fresh values.
  update public.ipcr_household_assignment a
  set municipality = g.municipality,
      barangay = g.barangay,
      set_group = g.set_group,
      grantee_name = g.grantee_name
  from public.grantee_list g
  where a.period_id = p_period_id
    and a.effective_to is null
    and a.hh_id = g.hh_id
    and (
      a.municipality is distinct from g.municipality
      or a.barangay is distinct from g.barangay
      or a.set_group is distinct from g.set_group
      or a.grantee_name is distinct from g.grantee_name
    );

  select count(*) into v_households from public.grantee_list;
  select count(*) into v_assigned
  from public.ipcr_household_assignment
  where period_id = p_period_id and effective_to is null;

  update public.ipcr_period
  set status = 'published', published_by = p_actor_id,
      published_at = v_now, household_count = v_households,
      assigned_count = v_assigned,
      unassigned_count = greatest(v_households - v_assigned, 0),
      conflict_count = 0, updated_at = v_now
  where id = p_period_id;

  update public.ipcr_assignment_alert
  set status = 'resolved', resolved_by = p_actor_id,
      resolved_at = v_now, updated_at = v_now
  where period_id = p_period_id and status = 'pending';

  insert into public.ipcr_assignment_audit (
    period_id, entity_type, entity_id, action, actor_user_id, after_data
  ) values (
    p_period_id, 'period', p_period_id::text, 'published', p_actor_id,
    jsonb_build_object('households', v_households, 'assigned', v_assigned,
      'unassigned', greatest(v_households - v_assigned, 0))
  );

  return jsonb_build_object(
    'households', v_households,
    'assigned', v_assigned,
    'unassigned', greatest(v_households - v_assigned, 0),
    'conflicts', 0
  );
end;
$$;


ALTER FUNCTION "public"."ipcr_publish_period"("p_period_id" "uuid", "p_actor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_remove_household_assignment"("p_period_id" "uuid", "p_hh_id" "text", "p_actor_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_rule public.ipcr_assignment_rule%rowtype;
  v_actor_role text;
  v_is_editor boolean := false;
  v_now timestamptz := now();
begin
  select s.role
  into v_actor_role
  from public.staff s
  where s.user_id = p_actor_id
    and s.is_active = true;

  v_is_editor := coalesce(
    v_actor_role in ('admin', 'provincial', 'swoIII', 'swoII'),
    false
  );

  if exists (
    select 1
    from public.ipcr_period p
    where p.id = p_period_id
      and p.status = 'closed'
  ) then
    raise exception 'Archived assignment periods are read-only';
  end if;

  select r.*
  into v_rule
  from public.ipcr_assignment_rule r
  where r.period_id = p_period_id
    and r.scope_type = 'hhid'
    and r.barangay_key = ''
    and r.scope_value_key = upper(btrim(p_hh_id))
    and r.status in ('draft', 'published')
  for update;

  if v_rule.id is null then
    raise exception 'Active HHID assignment not found';
  end if;

  if not v_is_editor and (
    v_actor_role is distinct from 'case_manager'
    or v_rule.responsible_cm_user_id is distinct from p_actor_id
  ) then
    raise exception 'You can remove only your own household assignment';
  end if;

  update public.ipcr_assignment_rule
  set status = 'retired', updated_at = v_now
  where id = v_rule.id;

  update public.ipcr_household_assignment
  set effective_to = v_now
  where period_id = p_period_id
    and upper(btrim(hh_id)) = upper(btrim(p_hh_id))
    and effective_to is null;

  insert into public.ipcr_assignment_audit (
    period_id,
    entity_type,
    entity_id,
    action,
    actor_user_id,
    before_data,
    after_data
  ) values (
    p_period_id,
    'household_assignment',
    p_hh_id,
    'removed',
    p_actor_id,
    jsonb_build_object(
      'rule_id', v_rule.id,
      'responsible_cm_user_id', v_rule.responsible_cm_user_id,
      'status', v_rule.status
    ),
    jsonb_build_object('status', 'retired')
  );

  return true;
end;
$$;


ALTER FUNCTION "public"."ipcr_remove_household_assignment"("p_period_id" "uuid", "p_hh_id" "text", "p_actor_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."ipcr_remove_household_assignment"("p_period_id" "uuid", "p_hh_id" "text", "p_actor_id" "uuid") IS 'Removes one exact-HHID assignment owned by the acting Case Manager or an editor without querying the protected auth schema; monitoring rows are preserved.';



CREATE OR REPLACE FUNCTION "public"."ipcr_reset_caseload"("p_period_id" "uuid", "p_actor_id" "uuid", "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_municipality" "text" DEFAULT NULL::"text") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_rules bigint := 0;
  v_assignments bigint := 0;
begin
  if (p_user_id is null) = (p_municipality is null) then
    raise exception 'Choose exactly one reset scope: staff or municipality';
  end if;
  if not exists (select 1 from public.ipcr_period where id = p_period_id and status <> 'closed') then
    raise exception 'Assignment period is missing or closed';
  end if;

  update public.ipcr_assignment_rule rule
  set status = 'retired', updated_at = now()
  where rule.period_id = p_period_id
    and rule.scope_type = 'hhid'
    and rule.status in ('draft', 'published')
    and (p_user_id is null or rule.responsible_cm_user_id = p_user_id)
    and (p_municipality is null or rule.municipality = p_municipality);
  get diagnostics v_rules = row_count;

  update public.ipcr_household_assignment assignment
  set effective_to = now()
  where assignment.period_id = p_period_id
    and assignment.effective_to is null
    and (p_user_id is null or assignment.responsible_cm_user_id = p_user_id)
    and (p_municipality is null or assignment.municipality = p_municipality);
  get diagnostics v_assignments = row_count;

  update public.ipcr_assignment_proposal proposal
  set status = 'rejected', reviewed_by = p_actor_id,
      reviewed_at = now(), updated_at = now()
  where proposal.period_id = p_period_id
    and proposal.status = 'pending'
    and (p_user_id is null or proposal.requested_cm_user_id = p_user_id)
    and (p_municipality is null or proposal.municipality = p_municipality);

  insert into public.ipcr_assignment_audit (
    period_id, entity_type, entity_id, action, actor_user_id, after_data
  ) values (
    p_period_id,
    'caseload_reset',
    coalesce(p_user_id::text, p_municipality),
    'reset',
    p_actor_id,
    jsonb_build_object(
      'staff_user_id', p_user_id,
      'municipality', p_municipality,
      'retired_rules', v_rules,
      'ended_assignments', v_assignments
    )
  );

  return greatest(v_rules, v_assignments);
end;
$$;


ALTER FUNCTION "public"."ipcr_reset_caseload"("p_period_id" "uuid", "p_actor_id" "uuid", "p_user_id" "uuid", "p_municipality" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_review_all_proposals"("p_period_id" "uuid", "p_decision" "text", "p_actor_id" "uuid") RETURNS TABLE("reviewed_count" integer, "rule_count" integer)
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_now timestamptz := now();
  v_reviewed integer := 0;
  v_rules integer := 0;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected';
  end if;

  if p_actor_id is null then
    raise exception 'Reviewer is required';
  end if;

  if not exists (
    select 1
    from public.ipcr_period p
    where p.id = p_period_id
      and p.status <> 'closed'
  ) then
    raise exception 'Assignment period not found or is already closed';
  end if;

  if p_decision = 'approved' then
    with latest_per_hhid as (
      select distinct on (
        upper(btrim(proposal.municipality)),
        upper(btrim(proposal.hh_id))
      )
        proposal.*
      from public.ipcr_assignment_proposal proposal
      where proposal.period_id = p_period_id
        and proposal.status = 'pending'
      order by
        upper(btrim(proposal.municipality)),
        upper(btrim(proposal.hh_id)),
        proposal.created_at desc,
        proposal.id desc
    )
    insert into public.ipcr_assignment_rule (
      period_id,
      scope_type,
      municipality,
      municipality_key,
      barangay,
      barangay_key,
      scope_value,
      scope_value_key,
      primary_worker_user_id,
      responsible_cm_user_id,
      status,
      created_by,
      approved_by,
      approved_at
    )
    select
      proposal.period_id,
      'hhid',
      proposal.municipality,
      upper(btrim(proposal.municipality)),
      null,
      '',
      proposal.hh_id,
      upper(btrim(proposal.hh_id)),
      proposal.requested_cm_user_id,
      proposal.requested_cm_user_id,
      'draft',
      p_actor_id,
      null,
      null
    from latest_per_hhid proposal
    on conflict (
      period_id,
      scope_type,
      municipality_key,
      barangay_key,
      scope_value_key
    ) do update set
      municipality = excluded.municipality,
      scope_value = excluded.scope_value,
      primary_worker_user_id = excluded.primary_worker_user_id,
      responsible_cm_user_id = excluded.responsible_cm_user_id,
      status = 'draft',
      created_by = excluded.created_by,
      approved_by = null,
      approved_at = null,
      updated_at = v_now;

    get diagnostics v_rules = row_count;
  end if;

  update public.ipcr_assignment_proposal proposal
  set
    status = p_decision,
    reviewed_by = p_actor_id,
    reviewed_at = v_now,
    updated_at = v_now
  where proposal.period_id = p_period_id
    and proposal.status = 'pending';

  get diagnostics v_reviewed = row_count;

  return query select v_reviewed, v_rules;
end;
$$;


ALTER FUNCTION "public"."ipcr_review_all_proposals"("p_period_id" "uuid", "p_decision" "text", "p_actor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_search_households"("p_period_id" "uuid", "p_municipality" "text" DEFAULT NULL::"text", "p_barangay" "text" DEFAULT NULL::"text", "p_set_group" "text" DEFAULT NULL::"text", "p_query" "text" DEFAULT NULL::"text", "p_assignment" "text" DEFAULT 'all'::"text", "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_monitoring" "text" DEFAULT 'all'::"text", "p_client_status" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 40, "p_offset" integer DEFAULT 0) RETURNS TABLE("hh_id" "text", "grantee_name" "text", "municipality" "text", "barangay" "text", "client_status" "text", "set_group" "text", "primary_worker_user_id" "uuid", "responsible_cm_user_id" "uuid", "source_rule_id" "uuid", "monitor_count" bigint, "total_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with period_settings as materialized (
    select period.eligible_client_statuses
    from public.ipcr_period period
    where period.id = p_period_id
  ), assignment_candidates as materialized (
    select
      r.scope_value as hh_id,
      r.primary_worker_user_id,
      r.responsible_cm_user_id,
      r.id as source_rule_id,
      2 as priority
    from public.ipcr_assignment_rule r
    where r.period_id = p_period_id
      and r.scope_type = 'hhid'
      and r.barangay_key = ''
      and r.status in ('draft', 'published')
    union all
    select
      a.hh_id,
      a.primary_worker_user_id,
      a.responsible_cm_user_id,
      a.source_rule_id,
      1 as priority
    from public.ipcr_household_assignment a
    where a.period_id = p_period_id
      and a.effective_to is null
  ), effective_assignments as materialized (
    select distinct on (candidate.hh_id)
      candidate.hh_id,
      candidate.primary_worker_user_id,
      candidate.responsible_cm_user_id,
      candidate.source_rule_id
    from assignment_candidates candidate
    order by candidate.hh_id, candidate.priority desc
  ), monitor_counts as materialized (
    select mr.beneficiary_hh_id as hh_id, count(*)::bigint as monitor_count
    from public.monitor_row mr
    where mr.beneficiary_hh_id is not null
    group by mr.beneficiary_hh_id
  )
  select
    g.hh_id,
    g.grantee_name,
    g.municipality,
    g.barangay,
    g.status as client_status,
    g.set_group,
    assignment.primary_worker_user_id,
    assignment.responsible_cm_user_id,
    assignment.source_rule_id,
    coalesce(monitors.monitor_count, 0)::bigint,
    count(*) over () as total_count
  from public.grantee_list g
  cross join period_settings settings
  left join effective_assignments assignment on assignment.hh_id = g.hh_id
  left join monitor_counts monitors on monitors.hh_id = g.hh_id
  where (
      p_municipality is null
      or g.municipality = any(string_to_array(p_municipality, chr(31)))
    )
    and (
      p_barangay is null
      or g.barangay = any(string_to_array(p_barangay, chr(31)))
    )
    and (
      p_set_group is null
      or btrim(g.set_group) = any(string_to_array(p_set_group, chr(31)))
    )
    and (p_client_status is null or g.status = p_client_status)
    and (
      -- Existing assignments remain visible in My Caseload even if the
      -- household later changes to a status excluded from new assignments.
      p_assignment = 'mine'
      or cardinality(settings.eligible_client_statuses) = 0
      or g.status = any(settings.eligible_client_statuses)
    )
    and (
      p_query is null or p_query = ''
      or g.hh_id ilike '%' || p_query || '%'
      or g.grantee_name ilike '%' || p_query || '%'
    )
    and case p_assignment
      when 'assigned' then assignment.hh_id is not null
      when 'unassigned' then assignment.hh_id is null
      when 'mine' then
        assignment.responsible_cm_user_id = p_user_id
        or exists (
          select 1
          from public.ipcr_supervision sp
          where sp.period_id = p_period_id
            and sp.municipality = g.municipality
            and sp.case_manager_user_id = assignment.responsible_cm_user_id
            and sp.swa_user_id = p_user_id
            and sp.status = 'approved'
        )
      else true
    end
    and case p_monitoring
      when 'with' then monitors.hh_id is not null
      when 'without' then monitors.hh_id is null
      else true
    end
  order by g.municipality, g.barangay, g.grantee_name, g.hh_id
  limit least(greatest(p_limit, 1), 100)
  offset greatest(p_offset, 0);
$$;


ALTER FUNCTION "public"."ipcr_search_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangay" "text", "p_set_group" "text", "p_query" "text", "p_assignment" "text", "p_user_id" "uuid", "p_monitoring" "text", "p_client_status" "text", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."ipcr_search_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangay" "text", "p_set_group" "text", "p_query" "text", "p_assignment" "text", "p_user_id" "uuid", "p_monitoring" "text", "p_client_status" "text", "p_limit" integer, "p_offset" integer) IS 'Searches Caseload Inventory households by one or more municipalities with period eligibility, Client Status, ownership, and monitoring filters.';



CREATE OR REPLACE FUNCTION "public"."ipcr_set_group_options"() RETURNS TABLE("set_group" "text")
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select distinct btrim(g.set_group) as set_group
  from public.grantee_list g
  where g.set_group is not null
    and btrim(g.set_group) <> ''
  order by 1;
$$;


ALTER FUNCTION "public"."ipcr_set_group_options"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ipcr_working_assignment_count"("p_period_id" "uuid", "p_municipalities" "text"[] DEFAULT NULL::"text"[], "p_client_statuses" "text"[] DEFAULT NULL::"text"[]) RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with effective_assignments as materialized (
    select upper(btrim(r.scope_value)) as hh_key
    from public.ipcr_assignment_rule r
    where r.period_id = p_period_id
      and r.scope_type = 'hhid'
      and r.barangay_key = ''
      and r.status in ('draft', 'published')
      and (p_municipalities is null or r.municipality = any(p_municipalities))
    union
    select upper(btrim(a.hh_id)) as hh_key
    from public.ipcr_household_assignment a
    where a.period_id = p_period_id
      and a.effective_to is null
      and (p_municipalities is null or a.municipality = any(p_municipalities))
  )
  select count(*)::bigint
  from effective_assignments assignment
  join public.grantee_list g on upper(btrim(g.hh_id)) = assignment.hh_key
  where p_client_statuses is null
     or cardinality(p_client_statuses) = 0
     or g.status = any(p_client_statuses);
$$;


ALTER FUNCTION "public"."ipcr_working_assignment_count"("p_period_id" "uuid", "p_municipalities" "text"[], "p_client_statuses" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."monitor_caller_can_edit_muni"("target_muni" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case
    when target_muni is null then false
    else exists (
      select 1 from public.staff_municipality
      where user_id = auth.uid()
        and municipality = target_muni
    )
  end;
$$;


ALTER FUNCTION "public"."monitor_caller_can_edit_muni"("target_muni" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."monitor_caller_is_editor"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.staff
    where user_id = auth.uid()
      and role in ('admin','provincial','swoIII','swoII')
  );
$$;


ALTER FUNCTION "public"."monitor_caller_is_editor"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."monitor_case_manager_options"("p_monitor_id" "uuid", "p_municipalities" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("user_id" "uuid", "full_name" "text", "target_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    monitoring_row.assigned_case_manager_user_id as user_id,
    coalesce(nullif(btrim(staff_member.full_name), ''), 'Unnamed Case Manager') as full_name,
    count(*)::bigint as target_count
  from public.monitor_row_with_assignment monitoring_row
  join public.staff staff_member
    on staff_member.user_id = monitoring_row.assigned_case_manager_user_id
  where monitoring_row.monitor_id = p_monitor_id
    and monitoring_row.assigned_case_manager_user_id is not null
    and staff_member.role = 'case_manager'
    and staff_member.is_active = true
    and (
      p_municipalities is null
      or monitoring_row.municipality = any(p_municipalities)
    )
  group by
    monitoring_row.assigned_case_manager_user_id,
    staff_member.full_name
  order by
    coalesce(nullif(btrim(staff_member.full_name), ''), 'Unnamed Case Manager'),
    monitoring_row.assigned_case_manager_user_id;
$$;


ALTER FUNCTION "public"."monitor_case_manager_options"("p_monitor_id" "uuid", "p_municipalities" "text"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."monitor_case_manager_options"("p_monitor_id" "uuid", "p_municipalities" "text"[]) IS 'Returns active Case Managers who own at least one target in a monitoring tool and optional municipality scope.';



CREATE OR REPLACE FUNCTION "public"."monitor_csv_replacement_preview"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    AS $$
declare
  monitor_config public.monitor%rowtype;
  raw_match_mode text := btrim(coalesce(p_match_mode, ''));
  normalized_match_mode text;
  match_column text;
  person_match boolean := false;
  replacement_items jsonb := '[]'::jsonb;
begin
  if (select auth.uid()) is null
     or not (select public.monitor_caller_is_editor()) then
    raise exception 'Editor access required';
  end if;

  select *
    into monitor_config
    from public.monitor
   where id = p_monitor_id
     and active = true;

  if not found then
    raise exception 'Monitoring tool not found';
  end if;
  if monitor_config.slug = 'for-concurrence' then
    raise exception 'Transfer of Residence uses its dedicated reconciliation workflow';
  end if;
  if not exists (
    select 1
      from pg_catalog.jsonb_array_elements(coalesce(monitor_config.fields, '[]'::jsonb)) as field_config
     where field_config ->> 'key' = p_field_key
  ) then
    raise exception 'The selected monitoring input field does not exist';
  end if;

  normalized_match_mode := lower(raw_match_mode);
  if normalized_match_mode = 'person_id' then
    person_match := true;
  elsif normalized_match_mode = 'hhid' then
    null;
  elsif left(raw_match_mode, 7) = 'column:' then
    match_column := substr(raw_match_mode, 8);
    if btrim(coalesce(match_column, '')) = ''
       or not exists (
         select 1
           from pg_catalog.jsonb_array_elements_text(
             coalesce(monitor_config.roster_columns, '[]'::jsonb)
           ) as configured(value)
          where configured.value = match_column
       ) then
      raise exception 'The selected monitoring match column does not exist';
    end if;
  else
    raise exception 'Select an existing monitoring table column to match';
  end if;

  if pg_catalog.jsonb_typeof(p_ids) <> 'array'
     or pg_catalog.jsonb_array_length(p_ids) = 0 then
    raise exception 'The CSV must contain at least one identifier';
  end if;
  if exists (
    select 1
      from pg_catalog.jsonb_array_elements(p_ids) as source(value)
     where pg_catalog.jsonb_typeof(source.value) <> 'string'
        or btrim(source.value #>> '{}') = ''
  ) then
    raise exception 'Blank or invalid CSV identifiers are not allowed';
  end if;

  create temporary table if not exists monitor_csv_replacement_source_ids (
    source_id text primary key
  ) on commit drop;
  truncate table pg_temp.monitor_csv_replacement_source_ids;

  insert into pg_temp.monitor_csv_replacement_source_ids(source_id)
  select distinct upper(regexp_replace(btrim(source.value), '[[:space:]]+', '', 'g'))
    from pg_catalog.jsonb_array_elements_text(p_ids) as source(value);

  if (select count(*) from pg_temp.monitor_csv_replacement_source_ids)
     <> pg_catalog.jsonb_array_length(p_ids) then
    raise exception 'Duplicate CSV identifiers are not allowed';
  end if;

  create temporary table if not exists monitor_csv_replacement_matches (
    source_id text not null,
    row_id uuid not null,
    primary key (source_id, row_id)
  ) on commit drop;
  truncate table pg_temp.monitor_csv_replacement_matches;

  if person_match then
    insert into pg_temp.monitor_csv_replacement_matches(source_id, row_id)
    select source.source_id, monitoring_row.id
      from pg_temp.monitor_csv_replacement_source_ids source
      join public.monitor_row monitoring_row
        on monitoring_row.monitor_id = p_monitor_id
       and monitoring_row.person_id = source.source_id;
  elsif normalized_match_mode = 'hhid' then
    insert into pg_temp.monitor_csv_replacement_matches(source_id, row_id)
    select source.source_id, monitoring_row.id
      from pg_temp.monitor_csv_replacement_source_ids source
      join public.monitor_row monitoring_row
        on monitoring_row.monitor_id = p_monitor_id
       and monitoring_row.beneficiary_hh_id = source.source_id;
  else
    insert into pg_temp.monitor_csv_replacement_matches(source_id, row_id)
    select source.source_id, monitoring_row.id
      from public.monitor_row monitoring_row
      join pg_temp.monitor_csv_replacement_source_ids source
        on source.source_id = upper(
          regexp_replace(
            btrim(coalesce(monitoring_row.data ->> match_column, '')),
            '[[:space:]]+',
            '',
            'g'
          )
        )
     where monitoring_row.monitor_id = p_monitor_id;
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', sample.source_id,
        'row_key', sample.row_key,
        'from', sample.current_value,
        'to', p_target_value
      )
      order by sample.source_id, sample.row_key
    ),
    '[]'::jsonb
  )
    into replacement_items
    from (
      select
        matched.source_id,
        monitoring_row.row_key,
        monitoring_row.values -> p_field_key as current_value
      from pg_temp.monitor_csv_replacement_matches matched
      join public.monitor_row monitoring_row on monitoring_row.id = matched.row_id
      where (
          person_match
          or not exists (
            select 1
              from pg_temp.monitor_csv_replacement_matches duplicate_match
             where duplicate_match.source_id = matched.source_id
             group by duplicate_match.source_id
            having count(*) > 1
          )
        )
        and btrim(coalesce(monitoring_row.values ->> p_field_key, '')) <> ''
        and monitoring_row.values -> p_field_key is distinct from p_target_value
      order by matched.source_id, monitoring_row.row_key
      limit 100
    ) sample;

  return pg_catalog.jsonb_build_object(
    'items', replacement_items,
    'sample_limit', 100
  );
end;
$$;


ALTER FUNCTION "public"."monitor_csv_replacement_preview"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."monitor_csv_replacement_preview"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb") IS 'Returns up to 100 existing monitoring values that an editor CSV update preview would replace.';



CREATE OR REPLACE FUNCTION "public"."next_transfer_referral_id"() RETURNS "text"
    LANGUAGE "sql"
    AS $$
  select 'CAV-TOR-' || lpad(nextval('public.transfer_referral_seq')::text, 5, '0');
$$;


ALTER FUNCTION "public"."next_transfer_referral_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reconcile_concurrence_snapshot"("filename" "text", "rows" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  select private.reconcile_concurrence_snapshot_impl(filename, rows);
$$;


ALTER FUNCTION "public"."reconcile_concurrence_snapshot"("filename" "text", "rows" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."reconcile_concurrence_snapshot"("filename" "text", "rows" "jsonb") IS 'Editor-only atomic Concurrence episode import, Grantee match, and cancellation archive reconciliation.';



CREATE OR REPLACE FUNCTION "public"."refresh_grantee_lhf"() RETURNS "void"
    LANGUAGE "sql"
    AS $$
  with latest as (
    select distinct on (hh_id)
           hh_id, swdi_score
      from public.swdi_score
     where hh_id is not null
     order by hh_id, date_of_interview desc nulls last, created_at desc
  )
  update public.grantee_list g
     set lhf = case
                 when latest.swdi_score is null then null
                 else (round(latest.swdi_score::numeric, 5) between 2.5 and 2.83)
               end
    from latest
   where g.hh_id = latest.hh_id;
$$;


ALTER FUNCTION "public"."refresh_grantee_lhf"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_concurrence_row"("archive_id" "uuid") RETURNS "uuid"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  select private.restore_concurrence_row_impl(archive_id);
$$;


ALTER FUNCTION "public"."restore_concurrence_row"("archive_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."restore_concurrence_row"("archive_id" "uuid") IS 'Editor-only restoration of one archived Concurrence episode when its exact case ID is absent.';



CREATE OR REPLACE FUNCTION "public"."set_system_resend_config"("p_api_key" "text", "p_from_addr" "text", "p_reply_to" "text", "p_enabled" boolean, "p_updated_by" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_secret_id uuid;
begin
  select c.api_key_secret_id
    into v_secret_id
  from public.system_resend_config c
  where c.id = 1;

  if nullif(btrim(p_api_key), '') is not null then
    if v_secret_id is null then
      select vault.create_secret(
        btrim(p_api_key),
        null,
        'Cavite BDMS system Resend API key'
      ) into v_secret_id;
    else
      perform vault.update_secret(v_secret_id, btrim(p_api_key));
    end if;
  end if;

  insert into public.system_resend_config (
    id,
    api_key_secret_id,
    from_addr,
    reply_to,
    enabled,
    updated_at,
    updated_by
  ) values (
    1,
    v_secret_id,
    nullif(btrim(p_from_addr), ''),
    nullif(btrim(p_reply_to), ''),
    coalesce(p_enabled, false),
    now(),
    p_updated_by
  )
  on conflict (id) do update set
    api_key_secret_id = excluded.api_key_secret_id,
    from_addr = excluded.from_addr,
    reply_to = excluded.reply_to,
    enabled = excluded.enabled,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;
end;
$$;


ALTER FUNCTION "public"."set_system_resend_config"("p_api_key" "text", "p_from_addr" "text", "p_reply_to" "text", "p_enabled" boolean, "p_updated_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_user_smtp_config"("p_user_id" "uuid", "p_host" "text", "p_port" integer, "p_username" "text", "p_password" "text", "p_from_addr" "text", "p_enabled" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_secret_id uuid;
begin
  if p_user_id is null then
    raise exception 'A user ID is required';
  end if;

  select c.password_secret_id
    into v_secret_id
  from public.user_smtp_config c
  where c.user_id = p_user_id;

  if nullif(p_password, '') is not null then
    if v_secret_id is null then
      select vault.create_secret(p_password) into v_secret_id;
    else
      perform vault.update_secret(v_secret_id, p_password);
    end if;
  end if;

  insert into public.user_smtp_config (
    user_id,
    host,
    port,
    username,
    password_secret_id,
    from_addr,
    enabled,
    updated_at
  ) values (
    p_user_id,
    nullif(btrim(p_host), ''),
    p_port,
    nullif(btrim(p_username), ''),
    v_secret_id,
    nullif(btrim(p_from_addr), ''),
    coalesce(p_enabled, false),
    now()
  )
  on conflict (user_id) do update set
    host = excluded.host,
    port = excluded.port,
    username = excluded.username,
    password_secret_id = excluded.password_secret_id,
    from_addr = excluded.from_addr,
    enabled = excluded.enabled,
    updated_at = excluded.updated_at;
end;
$$;


ALTER FUNCTION "public"."set_user_smtp_config"("p_user_id" "uuid", "p_host" "text", "p_port" integer, "p_username" "text", "p_password" "text", "p_from_addr" "text", "p_enabled" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."staff_directory_compose_name"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.name := regexp_replace(
    btrim(
      coalesce(new.first_name, '') || ' ' ||
      coalesce(new.middle_name, '') || ' ' ||
      coalesce(new.last_name, '')
    ),
    '\s+', ' ', 'g'
  );
  return new;
end;
$$;


ALTER FUNCTION "public"."staff_directory_compose_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."staff_directory_touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."staff_directory_touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."swdi_gap_counts"("p_munis" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("key" "text", "lvl1" bigint, "lvl2" bigint, "assessed" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with s as (
    select
      sw.sa1, sw.sa2, sw.sa3, sw.sa4, sw.sa5,
      sw.es1, sw.es2, sw.es3, sw.es4,
      sw.hcs1, sw.hcs2,
      sw.nc1, sw.nc2,
      sw.wcs1, sw.wcs2, sw.wcs3,
      sw.hc1, sw.hc2, sw.hc3, sw.hc4,
      sw.ec1, sw.ec2,
      sw.rp1, sw.rp2, sw.rp3,
      sw.fa1, sw.fa2, sw.fa3
    from public.swdi_score sw
    join public.grantee_list g on g.hh_id = sw.hh_id
    where p_munis is null or g.municipality = any(p_munis)
  ),
  unp as (
    select t.key, t.v
    from s,
    lateral (values
      ('sa1', s.sa1), ('sa2', s.sa2), ('sa3', s.sa3), ('sa4', s.sa4), ('sa5', s.sa5),
      ('es1', s.es1), ('es2', s.es2), ('es3', s.es3), ('es4', s.es4),
      ('hcs1', s.hcs1), ('hcs2', s.hcs2),
      ('nc1', s.nc1), ('nc2', s.nc2),
      ('wcs1', s.wcs1), ('wcs2', s.wcs2), ('wcs3', s.wcs3),
      ('hc1', s.hc1), ('hc2', s.hc2), ('hc3', s.hc3), ('hc4', s.hc4),
      ('ec1', s.ec1), ('ec2', s.ec2),
      ('rp1', s.rp1), ('rp2', s.rp2), ('rp3', s.rp3),
      ('fa1', s.fa1), ('fa2', s.fa2), ('fa3', s.fa3)
    ) as t(key, v)
  )
  select
    key,
    count(*) filter (where v is not null and v > 0 and v < 1.5)::bigint as lvl1,
    count(*) filter (where v is not null and v >= 1.5 and v < 2.5)::bigint as lvl2,
    count(*) filter (where v is not null and v > 0)::bigint as assessed
  from unp
  group by key;
$$;


ALTER FUNCTION "public"."swdi_gap_counts"("p_munis" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_changed_grantees_to_monitors"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '45s'
    AS $_$
begin
  update public.monitor_row mr
     set municipality = g.municipality,
         data = mr.data
           || case when m.municipality_key is not null
                   then pg_catalog.jsonb_build_object(m.municipality_key, coalesce(g.municipality, ''))
                   else '{}'::jsonb end
           || case when m.barangay_key is not null
                   then pg_catalog.jsonb_build_object(m.barangay_key, coalesce(g.barangay, ''))
                   else '{}'::jsonb end
           || case when m.client_status_key is not null
                         and m.client_status_key <> mapping.beneficiary_key
                   then pg_catalog.jsonb_build_object(m.client_status_key, coalesce(g.status, ''))
                   else '{}'::jsonb end
           || case when m.slug = 'for-concurrence'
                   then pg_catalog.jsonb_build_object('__concurrence_grantee_match', true)
                   else '{}'::jsonb end,
         values = case
           when m.slug = 'for-concurrence'
                and concurrence.field_key is not null
                and coalesce(mr.data ->> '__concurrence_is_returning', 'false') <> 'true'
             then pg_catalog.jsonb_set(
               coalesce(mr.values, '{}'::jsonb),
               array[concurrence.field_key],
               pg_catalog.to_jsonb(concurrence.yes_value),
               true
             )
           else mr.values
         end
    from public.monitor m
    cross join lateral (
      select coalesce(
        m.beneficiary_key,
        case when m.slug = 'for-concurrence' then 'Listahanan ID' end
      ) as beneficiary_key
    ) mapping
    left join lateral (
      select
        field ->> 'key' as field_key,
        coalesce(
          (
            select option_value
              from pg_catalog.jsonb_array_elements_text(coalesce(field -> 'options', '[]'::jsonb)) option_value
             where option_value ~* '^(yes|true|concurred)$'
             limit 1
          ),
          'Yes'
        ) as yes_value
        from pg_catalog.jsonb_array_elements(coalesce(m.fields, '[]'::jsonb)) field
       where pg_catalog.regexp_replace(
         lower(coalesce(field ->> 'label', '')),
         '[^a-z0-9]+',
         ' ',
         'g'
       ) = 'is concurred'
       limit 1
    ) concurrence on true,
    changed_grantees g
   where mr.monitor_id = m.id
     and mapping.beneficiary_key is not null
     and g.hh_id = mr.beneficiary_hh_id
     and (
       mr.municipality is distinct from g.municipality
       or (
         m.municipality_key is not null
         and (mr.data ->> m.municipality_key) is distinct from coalesce(g.municipality, '')
       )
       or (
         m.barangay_key is not null
         and (mr.data ->> m.barangay_key) is distinct from coalesce(g.barangay, '')
       )
       or (
         m.client_status_key is not null
         and m.client_status_key <> mapping.beneficiary_key
         and (mr.data ->> m.client_status_key) is distinct from coalesce(g.status, '')
       )
       or (
         m.slug = 'for-concurrence'
         and (mr.data ->> '__concurrence_grantee_match') is distinct from 'true'
       )
       or (
         m.slug = 'for-concurrence'
         and concurrence.field_key is not null
         and coalesce(mr.data ->> '__concurrence_is_returning', 'false') <> 'true'
         and (mr.values ->> concurrence.field_key) is distinct from concurrence.yes_value
       )
     );

  return null;
end;
$_$;


ALTER FUNCTION "public"."sync_changed_grantees_to_monitors"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_monitor_grantee_profiles"("p_monitor_id" "uuid" DEFAULT NULL::"uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '45s'
    AS $_$
declare
  affected bigint := 0;
  unmatched bigint := 0;
begin
  if (select auth.uid()) is not null
     and not (select public.monitor_caller_is_editor()) then
    raise exception 'Editor access required';
  end if;

  update public.monitor_row mr
     set data = pg_catalog.jsonb_set(
       coalesce(mr.data, '{}'::jsonb),
       array['__concurrence_grantee_match'],
       'false'::jsonb,
       true
     )
    from public.monitor m
   where mr.monitor_id = m.id
     and m.slug = 'for-concurrence'
     and (p_monitor_id is null or m.id = p_monitor_id)
     and (mr.data ->> '__concurrence_grantee_match') is distinct from 'false'
     and not exists (
       select 1
         from public.grantee_list missing_match
        where missing_match.hh_id = mr.beneficiary_hh_id
     );
  get diagnostics unmatched = row_count;

  update public.monitor_row mr
     set beneficiary_hh_id = g.hh_id,
         municipality = g.municipality,
         data = mr.data
           || case when m.municipality_key is not null
                   then pg_catalog.jsonb_build_object(m.municipality_key, coalesce(g.municipality, ''))
                   else '{}'::jsonb end
           || case when m.barangay_key is not null
                   then pg_catalog.jsonb_build_object(m.barangay_key, coalesce(g.barangay, ''))
                   else '{}'::jsonb end
           || case when m.client_status_key is not null
                         and m.client_status_key <> mapping.beneficiary_key
                   then pg_catalog.jsonb_build_object(m.client_status_key, coalesce(g.status, ''))
                   else '{}'::jsonb end
           || case when m.slug = 'for-concurrence'
                   then pg_catalog.jsonb_build_object('__concurrence_grantee_match', true)
                   else '{}'::jsonb end,
         values = case
           when m.slug = 'for-concurrence'
                and concurrence.field_key is not null
                and coalesce(mr.data ->> '__concurrence_is_returning', 'false') <> 'true'
             then pg_catalog.jsonb_set(
               coalesce(mr.values, '{}'::jsonb),
               array[concurrence.field_key],
               pg_catalog.to_jsonb(concurrence.yes_value),
               true
             )
           else mr.values
         end
    from public.monitor m
    cross join lateral (
      select coalesce(
        m.beneficiary_key,
        case when m.slug = 'for-concurrence' then 'Listahanan ID' end
      ) as beneficiary_key
    ) mapping
    left join lateral (
      select
        field ->> 'key' as field_key,
        coalesce(
          (
            select option_value
              from pg_catalog.jsonb_array_elements_text(coalesce(field -> 'options', '[]'::jsonb)) option_value
             where option_value ~* '^(yes|true|concurred)$'
             limit 1
          ),
          'Yes'
        ) as yes_value
        from pg_catalog.jsonb_array_elements(coalesce(m.fields, '[]'::jsonb)) field
       where pg_catalog.regexp_replace(
         lower(coalesce(field ->> 'label', '')),
         '[^a-z0-9]+',
         ' ',
         'g'
       ) = 'is concurred'
       limit 1
    ) concurrence on true
    join public.grantee_list g on true
   where mr.monitor_id = m.id
     and mapping.beneficiary_key is not null
     and (p_monitor_id is null or m.id = p_monitor_id)
     and g.hh_id = coalesce(
       nullif(btrim(mr.beneficiary_hh_id), ''),
       nullif(btrim(mr.data ->> mapping.beneficiary_key), '')
     )
     and (
       mr.beneficiary_hh_id is distinct from g.hh_id
       or mr.municipality is distinct from g.municipality
       or (
         m.municipality_key is not null
         and (mr.data ->> m.municipality_key) is distinct from coalesce(g.municipality, '')
       )
       or (
         m.barangay_key is not null
         and (mr.data ->> m.barangay_key) is distinct from coalesce(g.barangay, '')
       )
       or (
         m.client_status_key is not null
         and m.client_status_key <> mapping.beneficiary_key
         and (mr.data ->> m.client_status_key) is distinct from coalesce(g.status, '')
       )
       or (
         m.slug = 'for-concurrence'
         and (mr.data ->> '__concurrence_grantee_match') is distinct from 'true'
       )
       or (
         m.slug = 'for-concurrence'
         and concurrence.field_key is not null
         and coalesce(mr.data ->> '__concurrence_is_returning', 'false') <> 'true'
         and (mr.values ->> concurrence.field_key) is distinct from concurrence.yes_value
       )
     );

  get diagnostics affected = row_count;
  return affected + unmatched;
end;
$_$;


ALTER FUNCTION "public"."sync_monitor_grantee_profiles"("p_monitor_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."auth_throttle" (
    "id" bigint NOT NULL,
    "ip" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "auth_throttle_kind_check" CHECK (("kind" = ANY (ARRAY['login'::"text", 'register'::"text"])))
);


ALTER TABLE "public"."auth_throttle" OWNER TO "postgres";


ALTER TABLE "public"."auth_throttle" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."auth_throttle_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."grantee_list" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "hh_id" "text" NOT NULL,
    "grantee_name" "text",
    "municipality" "text",
    "barangay" "text",
    "status" "text",
    "target_tag" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "region" "text",
    "province" "text",
    "entry_id" "text",
    "set_group" "text",
    "birthday" "date",
    "sex" "text",
    "ip_affiliation" "text",
    "mothers_maiden_name" "text",
    "date_tagged_v2" timestamp with time zone,
    "date_tagged_v3" timestamp with time zone,
    "registered" "text",
    "l3_consolidated" "text",
    "assigned_cml" "text",
    "lhf" boolean,
    "target_group" "text"[],
    "previous_case_manager" "text",
    "case_manager_unassigned_at" timestamp with time zone
);


ALTER TABLE "public"."grantee_list" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."barangay_options" AS
 SELECT DISTINCT "municipality",
    "barangay"
   FROM "public"."grantee_list"
  WHERE (("barangay" IS NOT NULL) AND ("municipality" IS NOT NULL));


ALTER VIEW "public"."barangay_options" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."case_list" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "record_no" "text",
    "hh_id" "text" NOT NULL,
    "typology" "text",
    "reason" "text",
    "status" "text",
    "is_manual_entry" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "entry_id" "text",
    "case_type_old" "text",
    "typology_category" "text",
    "typology_name" "text",
    "reason_nas" "text",
    "reason_sub_nas" "text",
    "region" "text",
    "province" "text",
    "municipality" "text",
    "barangay" "text",
    "date_encoded" timestamp with time zone,
    "assigned_case_manager" "text",
    "risk_level" "text",
    "client_name" "text",
    "date_reported" timestamp with time zone,
    "date_modified" timestamp with time zone,
    "sex" "text",
    "age" integer,
    "hh_set" "text",
    "approval_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "approval_remarks" "text",
    "scsr_reviewed" boolean DEFAULT false NOT NULL,
    "scsr_reviewed_by" "text",
    "scsr_reviewed_at" timestamp with time zone,
    CONSTRAINT "case_list_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'disapproved'::"text"])))
);


ALTER TABLE "public"."case_list" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."case_cml_options" AS
 SELECT DISTINCT "assigned_case_manager" AS "name"
   FROM "public"."case_list"
  WHERE ("assigned_case_manager" IS NOT NULL);


ALTER VIEW "public"."case_cml_options" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."case_risk_options" AS
 SELECT DISTINCT "risk_level" AS "name"
   FROM "public"."case_list"
  WHERE (("risk_level" IS NOT NULL) AND ("btrim"("risk_level") <> ''::"text"))
  ORDER BY "risk_level";


ALTER VIEW "public"."case_risk_options" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."case_status_options" AS
 SELECT DISTINCT "status" AS "name"
   FROM "public"."case_list"
  WHERE (("status" IS NOT NULL) AND ("btrim"("status") <> ''::"text"))
  ORDER BY "status";


ALTER VIEW "public"."case_status_options" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."case_typology_category_options" AS
 SELECT DISTINCT "typology_category" AS "name"
   FROM "public"."case_list"
  WHERE (("typology_category" IS NOT NULL) AND ("btrim"("typology_category") <> ''::"text"))
  ORDER BY "typology_category";


ALTER VIEW "public"."case_typology_category_options" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."case_typology_options" AS
 SELECT DISTINCT "typology_name" AS "name"
   FROM "public"."case_list"
  WHERE (("typology_name" IS NOT NULL) AND ("btrim"("typology_name") <> ''::"text"))
  ORDER BY "typology_name";


ALTER VIEW "public"."case_typology_options" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cluster" (
    "id" integer NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."cluster" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."concurrence_import_batch" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "monitor_id" "uuid" NOT NULL,
    "filename" "text" NOT NULL,
    "source_rows" integer NOT NULL,
    "cavite_episodes" integer NOT NULL,
    "duplicate_episode_keys" integer DEFAULT 0 NOT NULL,
    "added_count" integer DEFAULT 0 NOT NULL,
    "retained_count" integer DEFAULT 0 NOT NULL,
    "returning_count" integer DEFAULT 0 NOT NULL,
    "grantee_matched_count" integer DEFAULT 0 NOT NULL,
    "protected_history_count" integer DEFAULT 0 NOT NULL,
    "archived_count" integer DEFAULT 0 NOT NULL,
    "unresolved_count" integer DEFAULT 0 NOT NULL,
    "imported_by" "uuid",
    "imported_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "concurrence_import_batch_added_count_check" CHECK (("added_count" >= 0)),
    CONSTRAINT "concurrence_import_batch_archived_count_check" CHECK (("archived_count" >= 0)),
    CONSTRAINT "concurrence_import_batch_cavite_episodes_check" CHECK (("cavite_episodes" > 0)),
    CONSTRAINT "concurrence_import_batch_duplicate_episode_keys_check" CHECK (("duplicate_episode_keys" >= 0)),
    CONSTRAINT "concurrence_import_batch_grantee_matched_count_check" CHECK (("grantee_matched_count" >= 0)),
    CONSTRAINT "concurrence_import_batch_protected_history_count_check" CHECK (("protected_history_count" >= 0)),
    CONSTRAINT "concurrence_import_batch_retained_count_check" CHECK (("retained_count" >= 0)),
    CONSTRAINT "concurrence_import_batch_returning_count_check" CHECK (("returning_count" >= 0)),
    CONSTRAINT "concurrence_import_batch_source_rows_check" CHECK (("source_rows" > 0)),
    CONSTRAINT "concurrence_import_batch_unresolved_count_check" CHECK (("unresolved_count" >= 0))
);


ALTER TABLE "public"."concurrence_import_batch" OWNER TO "postgres";


COMMENT ON TABLE "public"."concurrence_import_batch" IS 'Atomic import results for the specialized for-concurrence CSV reconciliation workflow.';



CREATE TABLE IF NOT EXISTS "public"."concurrence_row_archive" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "monitor_id" "uuid" NOT NULL,
    "original_row_id" "uuid" NOT NULL,
    "concurrence_case_id" "text" NOT NULL,
    "beneficiary_hh_id" "text",
    "row_snapshot" "jsonb" NOT NULL,
    "reason" "text" DEFAULT 'Absent from latest Cavite snapshot and Grantee List'::"text" NOT NULL,
    "archived_by" "uuid",
    "archived_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "restored_by" "uuid",
    "restored_at" timestamp with time zone
);


ALTER TABLE "public"."concurrence_row_archive" OWNER TO "postgres";


COMMENT ON TABLE "public"."concurrence_row_archive" IS 'Recoverable cancellation candidates removed from the active Concurrence monitor by snapshot reconciliation.';



CREATE TABLE IF NOT EXISTS "public"."email_directory" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "label" "text",
    "email" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."email_directory" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."grantee_import_batch" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "imported_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "imported_by" "uuid",
    "filename" "text",
    "total_rows" integer,
    "transfer_in_count" integer DEFAULT 0 NOT NULL,
    "transfer_out_count" integer DEFAULT 0 NOT NULL,
    "intra_cavite_count" integer DEFAULT 0 NOT NULL,
    "name_change_count" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."grantee_import_batch" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."grantee_status_options" AS
 SELECT DISTINCT "status"
   FROM "public"."grantee_list"
  WHERE ("status" IS NOT NULL);


ALTER VIEW "public"."grantee_status_options" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."grantee_transfer" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "hh_id" "text" NOT NULL,
    "grantee_name" "text",
    "kind" "text" NOT NULL,
    "old_municipality" "text",
    "old_barangay" "text",
    "new_municipality" "text",
    "new_barangay" "text",
    "detected_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "old_grantee_name" "text",
    CONSTRAINT "grantee_transfer_kind_check" CHECK (("kind" = ANY (ARRAY['in'::"text", 'out'::"text", 'intra'::"text", 'name_change'::"text"])))
);


ALTER TABLE "public"."grantee_transfer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."import_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kind" "text" NOT NULL,
    "imported_by" "uuid",
    "imported_by_name" "text",
    "imported_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "filename" "text",
    "row_count" integer
);


ALTER TABLE "public"."import_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ipcr_assignment_alert" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "period_id" "uuid" NOT NULL,
    "hh_id" "text" NOT NULL,
    "alert_type" "text" DEFAULT 'profile_changed'::"text" NOT NULL,
    "before_data" "jsonb",
    "after_data" "jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ipcr_assignment_alert_alert_type_check" CHECK (("alert_type" = ANY (ARRAY['profile_changed'::"text", 'missing_hhid'::"text"]))),
    CONSTRAINT "ipcr_assignment_alert_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."ipcr_assignment_alert" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ipcr_assignment_audit" (
    "id" bigint NOT NULL,
    "period_id" "uuid",
    "entity_type" "text" NOT NULL,
    "entity_id" "text" NOT NULL,
    "action" "text" NOT NULL,
    "actor_user_id" "uuid",
    "before_data" "jsonb",
    "after_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ipcr_assignment_audit" OWNER TO "postgres";


ALTER TABLE "public"."ipcr_assignment_audit" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ipcr_assignment_audit_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."ipcr_assignment_proposal" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "period_id" "uuid" NOT NULL,
    "hh_id" "text" NOT NULL,
    "municipality" "text" NOT NULL,
    "requested_worker_user_id" "uuid" NOT NULL,
    "requested_cm_user_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "proposed_by" "uuid" NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ipcr_assignment_proposal_case_manager_owner" CHECK (("requested_worker_user_id" = "requested_cm_user_id")),
    CONSTRAINT "ipcr_assignment_proposal_hh_id_check" CHECK (("btrim"("hh_id") <> ''::"text")),
    CONSTRAINT "ipcr_assignment_proposal_reason_check" CHECK (("btrim"("reason") <> ''::"text")),
    CONSTRAINT "ipcr_assignment_proposal_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."ipcr_assignment_proposal" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ipcr_assignment_rule" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "period_id" "uuid" NOT NULL,
    "scope_type" "text" NOT NULL,
    "municipality" "text" NOT NULL,
    "municipality_key" "text" NOT NULL,
    "barangay" "text",
    "barangay_key" "text" DEFAULT ''::"text" NOT NULL,
    "scope_value" "text",
    "scope_value_key" "text" DEFAULT ''::"text" NOT NULL,
    "primary_worker_user_id" "uuid" NOT NULL,
    "responsible_cm_user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_by" "uuid",
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ipcr_assignment_rule_case_manager_owner" CHECK (("primary_worker_user_id" = "responsible_cm_user_id")),
    CONSTRAINT "ipcr_assignment_rule_check" CHECK (((("scope_type" = 'municipality'::"text") AND ("barangay" IS NULL) AND ("scope_value" IS NULL)) OR (("scope_type" = 'barangay'::"text") AND ("barangay" IS NOT NULL) AND ("scope_value" IS NULL)) OR (("scope_type" = ANY (ARRAY['classification'::"text", 'set_group'::"text"])) AND ("scope_value" IS NOT NULL)) OR (("scope_type" = 'hhid'::"text") AND ("scope_value" IS NOT NULL)))),
    CONSTRAINT "ipcr_assignment_rule_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['municipality'::"text", 'barangay'::"text", 'classification'::"text", 'set_group'::"text", 'hhid'::"text"]))),
    CONSTRAINT "ipcr_assignment_rule_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'retired'::"text"])))
);


ALTER TABLE "public"."ipcr_assignment_rule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ipcr_household_assignment" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "period_id" "uuid" NOT NULL,
    "hh_id" "text" NOT NULL,
    "municipality" "text",
    "barangay" "text",
    "set_group" "text",
    "grantee_name" "text",
    "primary_worker_user_id" "uuid" NOT NULL,
    "responsible_cm_user_id" "uuid" NOT NULL,
    "source_rule_id" "uuid",
    "effective_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "effective_to" timestamp with time zone,
    "assigned_by" "uuid",
    "assignment_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ipcr_household_assignment_case_manager_owner" CHECK (("primary_worker_user_id" = "responsible_cm_user_id")),
    CONSTRAINT "ipcr_household_assignment_check" CHECK ((("effective_to" IS NULL) OR ("effective_to" >= "effective_from"))),
    CONSTRAINT "ipcr_household_assignment_hh_id_check" CHECK (("btrim"("hh_id") <> ''::"text"))
);


ALTER TABLE "public"."ipcr_household_assignment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ipcr_period" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "period_kind" "text" DEFAULT 'semester'::"text" NOT NULL,
    "starts_on" "date" NOT NULL,
    "ends_on" "date" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "household_count" integer DEFAULT 0 NOT NULL,
    "assigned_count" integer DEFAULT 0 NOT NULL,
    "unassigned_count" integer DEFAULT 0 NOT NULL,
    "conflict_count" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "published_by" "uuid",
    "published_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "eligible_client_statuses" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    CONSTRAINT "ipcr_period_assigned_count_check" CHECK (("assigned_count" >= 0)),
    CONSTRAINT "ipcr_period_check" CHECK (("ends_on" >= "starts_on")),
    CONSTRAINT "ipcr_period_conflict_count_check" CHECK (("conflict_count" >= 0)),
    CONSTRAINT "ipcr_period_household_count_check" CHECK (("household_count" >= 0)),
    CONSTRAINT "ipcr_period_period_kind_check" CHECK (("period_kind" = ANY (ARRAY['semester'::"text", 'custom'::"text"]))),
    CONSTRAINT "ipcr_period_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'closed'::"text"]))),
    CONSTRAINT "ipcr_period_unassigned_count_check" CHECK (("unassigned_count" >= 0))
);


ALTER TABLE "public"."ipcr_period" OWNER TO "postgres";


COMMENT ON COLUMN "public"."ipcr_period"."eligible_client_statuses" IS 'Client Status values eligible for new household assignment. An empty array means all statuses.';



CREATE TABLE IF NOT EXISTS "public"."ipcr_set_group_classification" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "set_group_code" "text" NOT NULL,
    "code_key" "text" NOT NULL,
    "classification" "text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ipcr_set_group_classification_classification_check" CHECK (("btrim"("classification") <> ''::"text")),
    CONSTRAINT "ipcr_set_group_classification_code_key_check" CHECK (("btrim"("code_key") <> ''::"text")),
    CONSTRAINT "ipcr_set_group_classification_set_group_code_check" CHECK (("btrim"("set_group_code") <> ''::"text"))
);


ALTER TABLE "public"."ipcr_set_group_classification" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ipcr_supervision" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "period_id" "uuid" NOT NULL,
    "municipality" "text" NOT NULL,
    "swa_user_id" "uuid" NOT NULL,
    "case_manager_user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "proposed_by" "uuid",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ipcr_supervision_check" CHECK (("swa_user_id" <> "case_manager_user_id")),
    CONSTRAINT "ipcr_supervision_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."ipcr_supervision" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."monitor" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "roster_columns" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "municipality_key" "text",
    "row_key" "text",
    "fields" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "kpis" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sidebar_group" "text",
    "sidebar_icon" "text",
    "gsheet_id" "text",
    "gsheet_tab" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "allow_manual_add" boolean DEFAULT false NOT NULL,
    "sort_order" integer,
    "column_labels" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "beneficiary_key" "text",
    "barangay_key" "text",
    "client_status_key" "text",
    "filter_columns" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    CONSTRAINT "monitor_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'sealed'::"text", 'hidden'::"text"])))
);


ALTER TABLE "public"."monitor" OWNER TO "postgres";


COMMENT ON COLUMN "public"."monitor"."filter_columns" IS 'Roster column names exposed as dropdown filters on the monitor table.';



CREATE TABLE IF NOT EXISTS "public"."monitor_row" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "monitor_id" "uuid" NOT NULL,
    "row_key" "text",
    "municipality" "text",
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "values" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "encoded_by" "uuid",
    "encoded_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "beneficiary_hh_id" "text",
    "person_id" "text"
);


ALTER TABLE "public"."monitor_row" OWNER TO "postgres";


COMMENT ON COLUMN "public"."monitor_row"."person_id" IS 'Canonical normalized PERSON_ID used for indexed monitoring CSV match updates.';



CREATE OR REPLACE VIEW "public"."monitor_row_with_assignment" WITH ("security_invoker"='true') AS
 WITH "current_period" AS (
         SELECT "selected_period"."id"
           FROM "public"."ipcr_period" "selected_period"
          ORDER BY
                CASE
                    WHEN ("selected_period"."status" = 'published'::"text") THEN 0
                    ELSE 1
                END, "selected_period"."starts_on" DESC, "selected_period"."created_at" DESC
         LIMIT 1
        ), "working_rules" AS (
         SELECT DISTINCT ON ("assignment_rule"."scope_value_key") "assignment_rule"."scope_value_key" AS "hh_id_key",
            "assignment_rule"."responsible_cm_user_id",
            "assignment_rule"."updated_at"
           FROM ("public"."ipcr_assignment_rule" "assignment_rule"
             JOIN "current_period" "selected_period" ON (("selected_period"."id" = "assignment_rule"."period_id")))
          WHERE (("assignment_rule"."scope_type" = 'hhid'::"text") AND ("assignment_rule"."status" = ANY (ARRAY['draft'::"text", 'published'::"text"])) AND ("assignment_rule"."scope_value_key" <> ''::"text"))
          ORDER BY "assignment_rule"."scope_value_key", "assignment_rule"."updated_at" DESC
        ), "applied_assignments" AS (
         SELECT "upper"("btrim"("assignment_1"."hh_id")) AS "hh_id_key",
            "assignment_1"."responsible_cm_user_id"
           FROM ("public"."ipcr_household_assignment" "assignment_1"
             JOIN "current_period" "selected_period" ON (("selected_period"."id" = "assignment_1"."period_id")))
          WHERE ("assignment_1"."effective_to" IS NULL)
        ), "effective_assignments" AS (
         SELECT COALESCE("working"."hh_id_key", "assignment_1"."hh_id_key") AS "hh_id_key",
            COALESCE("working"."responsible_cm_user_id", "assignment_1"."responsible_cm_user_id") AS "responsible_cm_user_id"
           FROM ("applied_assignments" "assignment_1"
             FULL JOIN "working_rules" "working" USING ("hh_id_key"))
        )
 SELECT "monitoring_row"."id",
    "monitoring_row"."monitor_id",
    "monitoring_row"."row_key",
    "monitoring_row"."municipality",
    "monitoring_row"."beneficiary_hh_id",
    "monitoring_row"."data",
    "monitoring_row"."values",
    "monitoring_row"."encoded_by",
    "monitoring_row"."encoded_at",
    "monitoring_row"."created_at",
    "monitoring_row"."updated_at",
    "assignment"."responsible_cm_user_id" AS "assigned_case_manager_user_id"
   FROM ("public"."monitor_row" "monitoring_row"
     LEFT JOIN "effective_assignments" "assignment" ON (("assignment"."hh_id_key" = "upper"("btrim"("monitoring_row"."beneficiary_hh_id")))));


ALTER VIEW "public"."monitor_row_with_assignment" OWNER TO "postgres";


COMMENT ON VIEW "public"."monitor_row_with_assignment" IS 'RLS-aware monitoring rows with the current Caseload Inventory Case Manager resolved by HHID.';



CREATE TABLE IF NOT EXISTS "public"."municipality" (
    "name" "text" NOT NULL,
    "cluster_id" integer NOT NULL
);


ALTER TABLE "public"."municipality" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_clear" (
    "user_id" "uuid" NOT NULL,
    "cleared_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notification_clear" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."registration_request" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "middle_name" "text",
    "last_name" "text" NOT NULL,
    "municipality" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "designation" "text",
    "employee_no" "text",
    "cluster_id" integer,
    "email" "text",
    CONSTRAINT "registration_request_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."registration_request" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."smtp_config" (
    "id" integer DEFAULT 1 NOT NULL,
    "host" "text",
    "port" integer,
    "username" "text",
    "password" "text",
    "from_addr" "text",
    "enabled" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone,
    "updated_by" "uuid",
    CONSTRAINT "smtp_config_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."smtp_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."staff" (
    "user_id" "uuid" NOT NULL,
    "full_name" "text",
    "role" "text" NOT NULL,
    "cluster_id" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "supervisor_user_id" "uuid",
    "employee_no" "text",
    "last_seen_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true NOT NULL,
    "deactivated_at" timestamp with time zone,
    "deactivation_reason" "text",
    "reactivated_at" timestamp with time zone,
    CONSTRAINT "staff_deactivation_reason_check" CHECK ((("deactivation_reason" IS NULL) OR ("deactivation_reason" = ANY (ARRAY['inactive_30_days'::"text", 'admin'::"text"])))),
    CONSTRAINT "staff_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'provincial'::"text", 'swoIII'::"text", 'swoII'::"text", 'case_manager'::"text", 'social_welfare_assistant'::"text", 'poo_staff'::"text"])))
);


ALTER TABLE "public"."staff" OWNER TO "postgres";


COMMENT ON COLUMN "public"."staff"."is_active" IS 'Application access gate. Inactive accounts must be reactivated by an administrator.';



COMMENT ON COLUMN "public"."staff"."deactivated_at" IS 'When the account was most recently deactivated.';



COMMENT ON COLUMN "public"."staff"."deactivation_reason" IS 'Reason for deactivation: inactive_30_days or admin.';



COMMENT ON COLUMN "public"."staff"."reactivated_at" IS 'When an administrator most recently reactivated the account.';



CREATE TABLE IF NOT EXISTS "public"."staff_directory" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "municipality" "text" NOT NULL,
    "position" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "first_name" "text" NOT NULL,
    "middle_name" "text",
    "last_name" "text" NOT NULL,
    "employee_no" "text",
    "email" "text"
);


ALTER TABLE "public"."staff_directory" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."staff_municipality" (
    "user_id" "uuid" NOT NULL,
    "municipality" "text" NOT NULL
);


ALTER TABLE "public"."staff_municipality" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."swdi_encoding" (
    "transaction_no" "text" NOT NULL,
    "hh_id" "text",
    "grantee_name" "text",
    "region" "text",
    "province" "text",
    "municipality" "text",
    "barangay" "text",
    "encoder" "text",
    "encoder_region" "text",
    "date_encoded" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."swdi_encoding" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."swdi_score" (
    "transaction_no" "text" NOT NULL,
    "hh_id" "text",
    "swdi_score" numeric,
    "lowb" "text",
    "es1" numeric,
    "es2" numeric,
    "es3" numeric,
    "es4" numeric,
    "c1" numeric,
    "c2" numeric,
    "c3" numeric,
    "c4" numeric,
    "total_income" numeric,
    "family_size" integer,
    "per_capita_income" numeric,
    "monthly_per_capita_income" numeric,
    "monthly_prov_per_capita_poverty" numeric,
    "monthly_prov_per_capita_food" numeric,
    "econ_suff" numeric,
    "hcs1" numeric,
    "hcs2" numeric,
    "hcs" numeric,
    "nc1" numeric,
    "nc2" numeric,
    "nc" numeric,
    "wcs1" numeric,
    "wcs2" numeric,
    "wcs3" numeric,
    "wcs" numeric,
    "sa1" numeric,
    "sa2" numeric,
    "sa3" numeric,
    "sa4" numeric,
    "sa5" numeric,
    "hc1" numeric,
    "hc2" numeric,
    "hc3" numeric,
    "hc4" numeric,
    "ec1" numeric,
    "ec2" numeric,
    "rp1" numeric,
    "rp2" numeric,
    "rp3" numeric,
    "fa1" numeric,
    "fa2" numeric,
    "fa3" numeric,
    "soc_adeq" numeric,
    "region_nick" "text",
    "prov_name" "text",
    "city_name" "text",
    "brgy_name" "text",
    "grantee_first" "text",
    "grantee_middle" "text",
    "grantee_last" "text",
    "total_children" integer,
    "ip" "text",
    "date_of_interview" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."swdi_score" OWNER TO "postgres";


COMMENT ON COLUMN "public"."swdi_score"."es1" IS 'Employable Skills';



COMMENT ON COLUMN "public"."swdi_score"."es2" IS 'Employment';



COMMENT ON COLUMN "public"."swdi_score"."es3" IS 'Income';



COMMENT ON COLUMN "public"."swdi_score"."es4" IS 'Social Security and Access to Financial Institutions';



COMMENT ON COLUMN "public"."swdi_score"."hcs1" IS 'Availment of family members of accessible health services in the past six months';



COMMENT ON COLUMN "public"."swdi_score"."hcs2" IS 'Health condition of family members in the past six months';



COMMENT ON COLUMN "public"."swdi_score"."nc1" IS 'Number of meals the family had in a day';



COMMENT ON COLUMN "public"."swdi_score"."nc2" IS 'Nutritional status of children aged 5 years or below';



COMMENT ON COLUMN "public"."swdi_score"."wcs1" IS 'Family''s access to safe drinking water';



COMMENT ON COLUMN "public"."swdi_score"."wcs2" IS 'Family''s access to sanitary toilet facilities';



COMMENT ON COLUMN "public"."swdi_score"."wcs3" IS 'Most common family practice of garbage disposal';



COMMENT ON COLUMN "public"."swdi_score"."hc1" IS 'Construction materials of the roof';



COMMENT ON COLUMN "public"."swdi_score"."hc2" IS 'Construction materials of the outer walls';



COMMENT ON COLUMN "public"."swdi_score"."hc3" IS 'Tenure status of housing unit';



COMMENT ON COLUMN "public"."swdi_score"."hc4" IS 'Lighting facility of the house';



COMMENT ON COLUMN "public"."swdi_score"."ec1" IS 'Functional literacy of family members aged 10 years or over';



COMMENT ON COLUMN "public"."swdi_score"."ec2" IS 'School enrolment / attendance of children aged 3-17 years (formal/informal)';



COMMENT ON COLUMN "public"."swdi_score"."rp1" IS 'Involvement of family members in family activities';



COMMENT ON COLUMN "public"."swdi_score"."rp2" IS 'Ability of parents and/or guardians to discern problems in the family and arrive at solutions';



COMMENT ON COLUMN "public"."swdi_score"."rp3" IS 'Participation of family members in legitimate or widely-recognized people''s organizations, associations, or support groups in the past six months';



COMMENT ON COLUMN "public"."swdi_score"."fa1" IS 'Awareness of the rights of children';



COMMENT ON COLUMN "public"."swdi_score"."fa2" IS 'Awareness of gender-based violence';



COMMENT ON COLUMN "public"."swdi_score"."fa3" IS 'Awareness of disaster risk reduction and management';



CREATE TABLE IF NOT EXISTS "public"."system_resend_config" (
    "id" smallint DEFAULT 1 NOT NULL,
    "api_key_secret_id" "uuid",
    "from_addr" "text",
    "reply_to" "text",
    "enabled" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    CONSTRAINT "system_resend_config_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."system_resend_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transfer_ack" (
    "user_id" "uuid" NOT NULL,
    "transfer_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."transfer_ack" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."transfer_referral_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."transfer_referral_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transfer_request" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "hh_id" "text" NOT NULL,
    "grantee_name" "text",
    "old_municipality" "text",
    "old_barangay" "text",
    "old_address" "text",
    "dest_region" "text",
    "dest_province" "text",
    "dest_municipality" "text",
    "dest_barangay" "text",
    "mobile" "text",
    "request_type" "text" DEFAULT 'TOR'::"text" NOT NULL,
    "remarks" "text",
    "referral_id" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "recipient_email" "text",
    "requested_by" "uuid",
    "requested_by_name" "text",
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_by_name" "text",
    "reviewed_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "attachment_urls" "text"[],
    "dest_street" "text",
    "client_status" "text",
    "cc_emails" "text",
    "bcc_emails" "text",
    CONSTRAINT "transfer_request_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'sent'::"text"])))
);


ALTER TABLE "public"."transfer_request" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_smtp_config" (
    "user_id" "uuid" NOT NULL,
    "host" "text",
    "port" integer,
    "username" "text",
    "password_secret_id" "uuid",
    "from_addr" "text",
    "enabled" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_smtp_config_port_check" CHECK ((("port" IS NULL) OR (("port" >= 1) AND ("port" <= 65535))))
);


ALTER TABLE "public"."user_smtp_config" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_grantee_list" WITH ("security_invoker"='on') AS
 SELECT "id",
    "hh_id",
    "grantee_name",
    "municipality",
    "barangay",
    "status",
    "target_tag",
    "created_at",
    "region",
    "province",
    "entry_id",
    "set_group",
    "birthday",
    "sex",
    "ip_affiliation",
    "mothers_maiden_name",
    "date_tagged_v2",
    "date_tagged_v3",
    "registered",
    "l3_consolidated",
    "assigned_cml",
    "lhf",
    "target_group",
    "previous_case_manager",
    "case_manager_unassigned_at",
    (EXISTS ( SELECT 1
           FROM "public"."case_list" "c"
          WHERE (("c"."hh_id" = "g"."hh_id") AND ("c"."is_manual_entry" = false) AND ("c"."record_no" IS NOT NULL)))) AS "has_verified_record_no"
   FROM "public"."grantee_list" "g";


ALTER VIEW "public"."v_grantee_list" OWNER TO "postgres";


ALTER TABLE ONLY "public"."auth_throttle"
    ADD CONSTRAINT "auth_throttle_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_record_no_key" UNIQUE ("record_no");



ALTER TABLE ONLY "public"."cluster"
    ADD CONSTRAINT "cluster_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."cluster"
    ADD CONSTRAINT "cluster_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."concurrence_import_batch"
    ADD CONSTRAINT "concurrence_import_batch_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."concurrence_row_archive"
    ADD CONSTRAINT "concurrence_row_archive_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_directory"
    ADD CONSTRAINT "email_directory_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grantee_import_batch"
    ADD CONSTRAINT "grantee_import_batch_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grantee_list"
    ADD CONSTRAINT "grantee_list_hh_id_key" UNIQUE ("hh_id");



ALTER TABLE ONLY "public"."grantee_list"
    ADD CONSTRAINT "grantee_list_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grantee_transfer"
    ADD CONSTRAINT "grantee_transfer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."import_log"
    ADD CONSTRAINT "import_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_assignment_alert"
    ADD CONSTRAINT "ipcr_assignment_alert_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_assignment_audit"
    ADD CONSTRAINT "ipcr_assignment_audit_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_assignment_proposal"
    ADD CONSTRAINT "ipcr_assignment_proposal_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_period_id_scope_type_municipality_key__key" UNIQUE ("period_id", "scope_type", "municipality_key", "barangay_key", "scope_value_key");



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_household_assignment"
    ADD CONSTRAINT "ipcr_household_assignment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_period"
    ADD CONSTRAINT "ipcr_period_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_set_group_classification"
    ADD CONSTRAINT "ipcr_set_group_classification_code_key_key" UNIQUE ("code_key");



ALTER TABLE ONLY "public"."ipcr_set_group_classification"
    ADD CONSTRAINT "ipcr_set_group_classification_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_period_id_municipality_swa_user_id_case_ma_key" UNIQUE ("period_id", "municipality", "swa_user_id", "case_manager_user_id");



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."monitor"
    ADD CONSTRAINT "monitor_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."monitor_row"
    ADD CONSTRAINT "monitor_row_monitor_id_row_key_key" UNIQUE ("monitor_id", "row_key");



ALTER TABLE ONLY "public"."monitor_row"
    ADD CONSTRAINT "monitor_row_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."monitor"
    ADD CONSTRAINT "monitor_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."municipality"
    ADD CONSTRAINT "municipality_pkey" PRIMARY KEY ("name");



ALTER TABLE ONLY "public"."notification_clear"
    ADD CONSTRAINT "notification_clear_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."registration_request"
    ADD CONSTRAINT "registration_request_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."smtp_config"
    ADD CONSTRAINT "smtp_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_directory"
    ADD CONSTRAINT "staff_directory_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_municipality"
    ADD CONSTRAINT "staff_municipality_pkey" PRIMARY KEY ("user_id", "municipality");



ALTER TABLE ONLY "public"."staff"
    ADD CONSTRAINT "staff_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."swdi_encoding"
    ADD CONSTRAINT "swdi_encoding_pkey" PRIMARY KEY ("transaction_no");



ALTER TABLE ONLY "public"."swdi_score"
    ADD CONSTRAINT "swdi_score_pkey" PRIMARY KEY ("transaction_no");



ALTER TABLE ONLY "public"."system_resend_config"
    ADD CONSTRAINT "system_resend_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transfer_ack"
    ADD CONSTRAINT "transfer_ack_pkey" PRIMARY KEY ("user_id", "transfer_id");



ALTER TABLE ONLY "public"."transfer_request"
    ADD CONSTRAINT "transfer_request_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_smtp_config"
    ADD CONSTRAINT "user_smtp_config_pkey" PRIMARY KEY ("user_id");



CREATE INDEX "auth_throttle_lookup_idx" ON "public"."auth_throttle" USING "btree" ("ip", "kind", "created_at" DESC);



CREATE INDEX "case_list_approval_status_idx" ON "public"."case_list" USING "btree" ("approval_status");



CREATE INDEX "case_list_assigned_case_manager_idx" ON "public"."case_list" USING "btree" ("assigned_case_manager") WHERE ("assigned_case_manager" IS NOT NULL);



CREATE INDEX "case_list_assigned_case_manager_trgm_idx" ON "public"."case_list" USING "gin" ("assigned_case_manager" "public"."gin_trgm_ops");



CREATE INDEX "case_list_client_name_trgm_idx" ON "public"."case_list" USING "gin" ("client_name" "public"."gin_trgm_ops");



CREATE INDEX "case_list_date_encoded_idx" ON "public"."case_list" USING "btree" ("date_encoded");



CREATE INDEX "case_list_hh_id_idx" ON "public"."case_list" USING "btree" ("hh_id");



CREATE INDEX "case_list_hh_id_trgm_idx" ON "public"."case_list" USING "gin" ("hh_id" "public"."gin_trgm_ops");



CREATE INDEX "case_list_hh_id_verified_idx" ON "public"."case_list" USING "btree" ("hh_id") WHERE (("is_manual_entry" = false) AND ("record_no" IS NOT NULL));



CREATE INDEX "case_list_is_manual_entry_idx" ON "public"."case_list" USING "btree" ("is_manual_entry");



CREATE INDEX "case_list_muni_date_idx" ON "public"."case_list" USING "btree" ("municipality", "date_encoded");



CREATE INDEX "case_list_record_no_trgm_idx" ON "public"."case_list" USING "gin" ("record_no" "public"."gin_trgm_ops");



CREATE INDEX "case_list_risk_level_idx" ON "public"."case_list" USING "btree" ("risk_level");



CREATE INDEX "case_list_scsr_reviewed_idx" ON "public"."case_list" USING "btree" ("scsr_reviewed") WHERE ("scsr_reviewed" = true);



CREATE INDEX "case_list_status_idx" ON "public"."case_list" USING "btree" ("status");



CREATE INDEX "case_list_typology_category_idx" ON "public"."case_list" USING "btree" ("typology_category");



CREATE INDEX "case_list_typology_name_idx" ON "public"."case_list" USING "btree" ("typology_name");



CREATE INDEX "case_list_typology_name_trgm_idx" ON "public"."case_list" USING "gin" ("typology_name" "public"."gin_trgm_ops");



CREATE INDEX "concurrence_import_batch_monitor_date_idx" ON "public"."concurrence_import_batch" USING "btree" ("monitor_id", "imported_at" DESC);



CREATE INDEX "concurrence_row_archive_active_idx" ON "public"."concurrence_row_archive" USING "btree" ("monitor_id", "archived_at" DESC) WHERE ("restored_at" IS NULL);



CREATE INDEX "concurrence_row_archive_batch_idx" ON "public"."concurrence_row_archive" USING "btree" ("batch_id");



CREATE INDEX "concurrence_row_archive_hhid_idx" ON "public"."concurrence_row_archive" USING "btree" ("monitor_id", "beneficiary_hh_id") WHERE (("restored_at" IS NULL) AND ("beneficiary_hh_id" IS NOT NULL));



CREATE INDEX "email_directory_label_idx" ON "public"."email_directory" USING "btree" ("label");



CREATE INDEX "grantee_import_batch_imported_at_idx" ON "public"."grantee_import_batch" USING "btree" ("imported_at" DESC);



CREATE INDEX "grantee_list_assigned_cml_idx" ON "public"."grantee_list" USING "btree" ("assigned_cml");



CREATE INDEX "grantee_list_barangay_idx" ON "public"."grantee_list" USING "btree" ("barangay");



CREATE INDEX "grantee_list_barangay_trgm_idx" ON "public"."grantee_list" USING "gin" ("barangay" "public"."gin_trgm_ops");



CREATE INDEX "grantee_list_birthday_idx" ON "public"."grantee_list" USING "btree" ("birthday");



CREATE INDEX "grantee_list_entry_id_idx" ON "public"."grantee_list" USING "btree" ("entry_id");



CREATE INDEX "grantee_list_grantee_name_trgm_idx" ON "public"."grantee_list" USING "gin" ("grantee_name" "public"."gin_trgm_ops");



CREATE INDEX "grantee_list_hh_id_trgm_idx" ON "public"."grantee_list" USING "gin" ("hh_id" "public"."gin_trgm_ops");



CREATE INDEX "grantee_list_ip_affiliation_present_idx" ON "public"."grantee_list" USING "btree" ("municipality", "ip_affiliation") INCLUDE ("status") WHERE (("ip_affiliation" IS NOT NULL) AND ("ip_affiliation" <> ''::"text"));



CREATE INDEX "grantee_list_lhf_idx" ON "public"."grantee_list" USING "btree" ("lhf");



CREATE INDEX "grantee_list_muni_barangay_idx" ON "public"."grantee_list" USING "btree" ("municipality", "barangay") WHERE (("barangay" IS NOT NULL) AND ("municipality" IS NOT NULL));



CREATE INDEX "grantee_list_muni_barangay_set_group_idx" ON "public"."grantee_list" USING "btree" ("municipality", "barangay", "set_group", "hh_id");



CREATE INDEX "grantee_list_muni_status_idx" ON "public"."grantee_list" USING "btree" ("municipality", "status");



CREATE INDEX "grantee_list_municipality_trgm_idx" ON "public"."grantee_list" USING "gin" ("municipality" "public"."gin_trgm_ops");



CREATE INDEX "grantee_list_set_group_filter_idx" ON "public"."grantee_list" USING "btree" ("btrim"("set_group")) WHERE (("set_group" IS NOT NULL) AND ("btrim"("set_group") <> ''::"text"));



CREATE INDEX "grantee_list_status_idx" ON "public"."grantee_list" USING "btree" ("status");



CREATE INDEX "grantee_list_status_muni_barangay_hhid_idx" ON "public"."grantee_list" USING "btree" ("status", "municipality", "barangay", "hh_id");



CREATE INDEX "grantee_list_target_group_gin_idx" ON "public"."grantee_list" USING "gin" ("target_group");



CREATE INDEX "grantee_list_target_tag_idx" ON "public"."grantee_list" USING "btree" ("target_tag");



CREATE INDEX "grantee_transfer_batch_kind_idx" ON "public"."grantee_transfer" USING "btree" ("batch_id", "kind");



CREATE INDEX "grantee_transfer_hh_id_idx" ON "public"."grantee_transfer" USING "btree" ("hh_id");



CREATE INDEX "import_log_imported_at_idx" ON "public"."import_log" USING "btree" ("imported_at" DESC);



CREATE INDEX "ipcr_alert_period_status_idx" ON "public"."ipcr_assignment_alert" USING "btree" ("period_id", "status", "created_at" DESC);



CREATE UNIQUE INDEX "ipcr_assignment_alert_pending_key" ON "public"."ipcr_assignment_alert" USING "btree" ("period_id", "hh_id") WHERE ("status" = 'pending'::"text");



CREATE INDEX "ipcr_assignment_cm_active_idx" ON "public"."ipcr_household_assignment" USING "btree" ("responsible_cm_user_id", "period_id") WHERE ("effective_to" IS NULL);



CREATE INDEX "ipcr_assignment_current_period_hhid_idx" ON "public"."ipcr_household_assignment" USING "btree" ("period_id", "hh_id") WHERE ("effective_to" IS NULL);



CREATE INDEX "ipcr_assignment_hhid_idx" ON "public"."ipcr_household_assignment" USING "btree" ("hh_id", "period_id");



CREATE INDEX "ipcr_assignment_muni_active_idx" ON "public"."ipcr_household_assignment" USING "btree" ("municipality", "period_id") WHERE ("effective_to" IS NULL);



CREATE INDEX "ipcr_assignment_worker_active_idx" ON "public"."ipcr_household_assignment" USING "btree" ("primary_worker_user_id", "period_id") WHERE ("effective_to" IS NULL);



CREATE INDEX "ipcr_audit_period_created_idx" ON "public"."ipcr_assignment_audit" USING "btree" ("period_id", "created_at" DESC);



CREATE UNIQUE INDEX "ipcr_household_assignment_active_key" ON "public"."ipcr_household_assignment" USING "btree" ("period_id", "hh_id") WHERE ("effective_to" IS NULL);



CREATE UNIQUE INDEX "ipcr_one_published_period_idx" ON "public"."ipcr_period" USING "btree" ("status") WHERE ("status" = 'published'::"text");



CREATE INDEX "ipcr_proposal_period_status_idx" ON "public"."ipcr_assignment_proposal" USING "btree" ("period_id", "status");



CREATE INDEX "ipcr_proposal_proposed_by_idx" ON "public"."ipcr_assignment_proposal" USING "btree" ("proposed_by", "status");



CREATE INDEX "ipcr_rule_cm_idx" ON "public"."ipcr_assignment_rule" USING "btree" ("responsible_cm_user_id", "period_id");



CREATE INDEX "ipcr_rule_current_hhid_lookup_idx" ON "public"."ipcr_assignment_rule" USING "btree" ("period_id", "scope_value_key", "updated_at" DESC) WHERE (("scope_type" = 'hhid'::"text") AND ("status" = ANY (ARRAY['draft'::"text", 'published'::"text"])));



CREATE INDEX "ipcr_rule_period_status_idx" ON "public"."ipcr_assignment_rule" USING "btree" ("period_id", "status");



CREATE INDEX "ipcr_rule_worker_idx" ON "public"."ipcr_assignment_rule" USING "btree" ("primary_worker_user_id", "period_id");



CREATE INDEX "ipcr_supervision_cm_idx" ON "public"."ipcr_supervision" USING "btree" ("case_manager_user_id", "period_id");



CREATE INDEX "ipcr_supervision_period_status_idx" ON "public"."ipcr_supervision" USING "btree" ("period_id", "status");



CREATE INDEX "ipcr_supervision_swa_idx" ON "public"."ipcr_supervision" USING "btree" ("swa_user_id", "period_id");



CREATE INDEX "monitor_row_beneficiary_hh_idx" ON "public"."monitor_row" USING "btree" ("beneficiary_hh_id") WHERE ("beneficiary_hh_id" IS NOT NULL);



CREATE INDEX "monitor_row_monitor_beneficiary_idx" ON "public"."monitor_row" USING "btree" ("monitor_id", "beneficiary_hh_id") WHERE ("beneficiary_hh_id" IS NOT NULL);



CREATE INDEX "monitor_row_monitor_idx" ON "public"."monitor_row" USING "btree" ("monitor_id");



CREATE INDEX "monitor_row_monitor_muni_row_key_idx" ON "public"."monitor_row" USING "btree" ("monitor_id", "municipality", "row_key");



CREATE INDEX "monitor_row_monitor_person_id_idx" ON "public"."monitor_row" USING "btree" ("monitor_id", "person_id") WHERE ("person_id" IS NOT NULL);



CREATE INDEX "monitor_row_muni_idx" ON "public"."monitor_row" USING "btree" ("municipality");



CREATE INDEX "municipality_cluster_id_idx" ON "public"."municipality" USING "btree" ("cluster_id");



CREATE UNIQUE INDEX "registration_request_employee_no_key" ON "public"."registration_request" USING "btree" ("lower"("btrim"("employee_no"))) WHERE (("employee_no" IS NOT NULL) AND ("btrim"("employee_no") <> ''::"text"));



CREATE INDEX "registration_request_status_idx" ON "public"."registration_request" USING "btree" ("status");



CREATE INDEX "staff_active_last_seen_idx" ON "public"."staff" USING "btree" ("last_seen_at") WHERE (("is_active" = true) AND ("role" <> 'admin'::"text"));



CREATE UNIQUE INDEX "staff_directory_email_key" ON "public"."staff_directory" USING "btree" ("lower"("email")) WHERE ("email" IS NOT NULL);



CREATE INDEX "staff_directory_municipality_idx" ON "public"."staff_directory" USING "btree" ("municipality");



CREATE UNIQUE INDEX "staff_directory_name_muni_idx" ON "public"."staff_directory" USING "btree" ("lower"("name"), "municipality");



CREATE UNIQUE INDEX "staff_employee_no_key" ON "public"."staff" USING "btree" ("lower"("btrim"("employee_no"))) WHERE (("employee_no" IS NOT NULL) AND ("btrim"("employee_no") <> ''::"text"));



CREATE INDEX "staff_supervisor_user_id_idx" ON "public"."staff" USING "btree" ("supervisor_user_id");



CREATE INDEX "swdi_encoding_encoder_idx" ON "public"."swdi_encoding" USING "btree" ("encoder");



CREATE INDEX "swdi_encoding_hh_id_idx" ON "public"."swdi_encoding" USING "btree" ("hh_id");



CREATE INDEX "swdi_encoding_municipality_idx" ON "public"."swdi_encoding" USING "btree" ("municipality");



CREATE INDEX "swdi_score_city_name_idx" ON "public"."swdi_score" USING "btree" ("city_name");



CREATE INDEX "swdi_score_hh_id_date_idx" ON "public"."swdi_score" USING "btree" ("hh_id", "date_of_interview" DESC NULLS LAST, "created_at" DESC);



CREATE INDEX "swdi_score_hh_id_idx" ON "public"."swdi_score" USING "btree" ("hh_id");



CREATE INDEX "transfer_ack_user_idx" ON "public"."transfer_ack" USING "btree" ("user_id");



CREATE INDEX "transfer_request_hh_idx" ON "public"."transfer_request" USING "btree" ("hh_id");



CREATE INDEX "transfer_request_old_muni_idx" ON "public"."transfer_request" USING "btree" ("old_municipality");



CREATE INDEX "transfer_request_status_idx" ON "public"."transfer_request" USING "btree" ("status", "requested_at" DESC);



CREATE OR REPLACE TRIGGER "case_list_set_updated_at" BEFORE UPDATE ON "public"."case_list" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "grantee_monitor_sync_insert" AFTER INSERT ON "public"."grantee_list" REFERENCING NEW TABLE AS "changed_grantees" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_changed_grantees_to_monitors"();



CREATE OR REPLACE TRIGGER "grantee_monitor_sync_update" AFTER UPDATE ON "public"."grantee_list" REFERENCING NEW TABLE AS "changed_grantees" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_changed_grantees_to_monitors"();



CREATE OR REPLACE TRIGGER "ipcr_alert_set_updated_at" BEFORE UPDATE ON "public"."ipcr_assignment_alert" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "ipcr_classification_set_updated_at" BEFORE UPDATE ON "public"."ipcr_set_group_classification" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "ipcr_grantee_profile_change" AFTER UPDATE OF "municipality", "barangay", "set_group", "status" ON "public"."grantee_list" FOR EACH ROW WHEN ((("old"."municipality" IS DISTINCT FROM "new"."municipality") OR ("old"."barangay" IS DISTINCT FROM "new"."barangay") OR ("old"."set_group" IS DISTINCT FROM "new"."set_group") OR ("old"."status" IS DISTINCT FROM "new"."status"))) EXECUTE FUNCTION "private"."ipcr_flag_household_profile_change"();



CREATE OR REPLACE TRIGGER "ipcr_period_set_updated_at" BEFORE UPDATE ON "public"."ipcr_period" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "ipcr_proposal_set_updated_at" BEFORE UPDATE ON "public"."ipcr_assignment_proposal" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "ipcr_rule_set_updated_at" BEFORE UPDATE ON "public"."ipcr_assignment_rule" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "ipcr_supervision_set_updated_at" BEFORE UPDATE ON "public"."ipcr_supervision" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "monitor_row_set_updated_at" BEFORE UPDATE ON "public"."monitor_row" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "monitor_set_updated_at" BEFORE UPDATE ON "public"."monitor" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "registration_request_unique_employee_number" BEFORE INSERT OR UPDATE OF "employee_no", "user_id" ON "public"."registration_request" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_unique_account_employee_number"();



CREATE OR REPLACE TRIGGER "staff_directory_compose_name" BEFORE INSERT OR UPDATE OF "first_name", "middle_name", "last_name" ON "public"."staff_directory" FOR EACH ROW EXECUTE FUNCTION "public"."staff_directory_compose_name"();



CREATE OR REPLACE TRIGGER "staff_directory_set_updated_at" BEFORE UPDATE ON "public"."staff_directory" FOR EACH ROW EXECUTE FUNCTION "public"."staff_directory_touch_updated_at"();



CREATE OR REPLACE TRIGGER "staff_set_updated_at" BEFORE UPDATE ON "public"."staff" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "staff_unique_employee_number" BEFORE INSERT OR UPDATE OF "employee_no", "user_id" ON "public"."staff" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_unique_account_employee_number"();



CREATE OR REPLACE TRIGGER "system_resend_config_delete_secret" AFTER DELETE ON "public"."system_resend_config" FOR EACH ROW EXECUTE FUNCTION "public"."delete_system_resend_secret"();



CREATE OR REPLACE TRIGGER "user_smtp_config_delete_secret" AFTER DELETE ON "public"."user_smtp_config" FOR EACH ROW EXECUTE FUNCTION "public"."delete_user_smtp_secret"();



ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."staff"("user_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_hh_id_fkey" FOREIGN KEY ("hh_id") REFERENCES "public"."grantee_list"("hh_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."concurrence_import_batch"
    ADD CONSTRAINT "concurrence_import_batch_imported_by_fkey" FOREIGN KEY ("imported_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."concurrence_import_batch"
    ADD CONSTRAINT "concurrence_import_batch_monitor_id_fkey" FOREIGN KEY ("monitor_id") REFERENCES "public"."monitor"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."concurrence_row_archive"
    ADD CONSTRAINT "concurrence_row_archive_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."concurrence_row_archive"
    ADD CONSTRAINT "concurrence_row_archive_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."concurrence_import_batch"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."concurrence_row_archive"
    ADD CONSTRAINT "concurrence_row_archive_monitor_id_fkey" FOREIGN KEY ("monitor_id") REFERENCES "public"."monitor"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."concurrence_row_archive"
    ADD CONSTRAINT "concurrence_row_archive_restored_by_fkey" FOREIGN KEY ("restored_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."grantee_import_batch"
    ADD CONSTRAINT "grantee_import_batch_imported_by_fkey" FOREIGN KEY ("imported_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."grantee_transfer"
    ADD CONSTRAINT "grantee_transfer_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."grantee_import_batch"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."import_log"
    ADD CONSTRAINT "import_log_imported_by_fkey" FOREIGN KEY ("imported_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_assignment_alert"
    ADD CONSTRAINT "ipcr_assignment_alert_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."ipcr_period"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_assignment_alert"
    ADD CONSTRAINT "ipcr_assignment_alert_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_assignment_audit"
    ADD CONSTRAINT "ipcr_assignment_audit_actor_user_id_fkey" FOREIGN KEY ("actor_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_assignment_audit"
    ADD CONSTRAINT "ipcr_assignment_audit_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."ipcr_period"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_assignment_proposal"
    ADD CONSTRAINT "ipcr_assignment_proposal_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."ipcr_period"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_assignment_proposal"
    ADD CONSTRAINT "ipcr_assignment_proposal_proposed_by_fkey" FOREIGN KEY ("proposed_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_assignment_proposal"
    ADD CONSTRAINT "ipcr_assignment_proposal_requested_cm_user_id_fkey" FOREIGN KEY ("requested_cm_user_id") REFERENCES "public"."staff"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_assignment_proposal"
    ADD CONSTRAINT "ipcr_assignment_proposal_requested_worker_user_id_fkey" FOREIGN KEY ("requested_worker_user_id") REFERENCES "public"."staff"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_assignment_proposal"
    ADD CONSTRAINT "ipcr_assignment_proposal_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_municipality_fkey" FOREIGN KEY ("municipality") REFERENCES "public"."municipality"("name") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."ipcr_period"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_primary_worker_user_id_fkey" FOREIGN KEY ("primary_worker_user_id") REFERENCES "public"."staff"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."ipcr_assignment_rule"
    ADD CONSTRAINT "ipcr_assignment_rule_responsible_cm_user_id_fkey" FOREIGN KEY ("responsible_cm_user_id") REFERENCES "public"."staff"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."ipcr_household_assignment"
    ADD CONSTRAINT "ipcr_household_assignment_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_household_assignment"
    ADD CONSTRAINT "ipcr_household_assignment_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."ipcr_period"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_household_assignment"
    ADD CONSTRAINT "ipcr_household_assignment_primary_worker_user_id_fkey" FOREIGN KEY ("primary_worker_user_id") REFERENCES "public"."staff"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."ipcr_household_assignment"
    ADD CONSTRAINT "ipcr_household_assignment_responsible_cm_user_id_fkey" FOREIGN KEY ("responsible_cm_user_id") REFERENCES "public"."staff"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."ipcr_household_assignment"
    ADD CONSTRAINT "ipcr_household_assignment_source_rule_id_fkey" FOREIGN KEY ("source_rule_id") REFERENCES "public"."ipcr_assignment_rule"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_period"
    ADD CONSTRAINT "ipcr_period_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_period"
    ADD CONSTRAINT "ipcr_period_published_by_fkey" FOREIGN KEY ("published_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_set_group_classification"
    ADD CONSTRAINT "ipcr_set_group_classification_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_case_manager_user_id_fkey" FOREIGN KEY ("case_manager_user_id") REFERENCES "public"."staff"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_municipality_fkey" FOREIGN KEY ("municipality") REFERENCES "public"."municipality"("name") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_period_id_fkey" FOREIGN KEY ("period_id") REFERENCES "public"."ipcr_period"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_proposed_by_fkey" FOREIGN KEY ("proposed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ipcr_supervision"
    ADD CONSTRAINT "ipcr_supervision_swa_user_id_fkey" FOREIGN KEY ("swa_user_id") REFERENCES "public"."staff"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."monitor"
    ADD CONSTRAINT "monitor_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."monitor_row"
    ADD CONSTRAINT "monitor_row_encoded_by_fkey" FOREIGN KEY ("encoded_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."monitor_row"
    ADD CONSTRAINT "monitor_row_monitor_id_fkey" FOREIGN KEY ("monitor_id") REFERENCES "public"."monitor"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."municipality"
    ADD CONSTRAINT "municipality_cluster_id_fkey" FOREIGN KEY ("cluster_id") REFERENCES "public"."cluster"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."notification_clear"
    ADD CONSTRAINT "notification_clear_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."registration_request"
    ADD CONSTRAINT "registration_request_cluster_id_fkey" FOREIGN KEY ("cluster_id") REFERENCES "public"."cluster"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."registration_request"
    ADD CONSTRAINT "registration_request_municipality_fkey" FOREIGN KEY ("municipality") REFERENCES "public"."municipality"("name") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."registration_request"
    ADD CONSTRAINT "registration_request_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."registration_request"
    ADD CONSTRAINT "registration_request_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."smtp_config"
    ADD CONSTRAINT "smtp_config_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."staff"
    ADD CONSTRAINT "staff_cluster_id_fkey" FOREIGN KEY ("cluster_id") REFERENCES "public"."cluster"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."staff_directory"
    ADD CONSTRAINT "staff_directory_municipality_fkey" FOREIGN KEY ("municipality") REFERENCES "public"."municipality"("name") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."staff_municipality"
    ADD CONSTRAINT "staff_municipality_municipality_fkey" FOREIGN KEY ("municipality") REFERENCES "public"."municipality"("name") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."staff_municipality"
    ADD CONSTRAINT "staff_municipality_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."staff"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."staff"
    ADD CONSTRAINT "staff_supervisor_user_id_fkey" FOREIGN KEY ("supervisor_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."staff"
    ADD CONSTRAINT "staff_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."swdi_encoding"
    ADD CONSTRAINT "swdi_encoding_hh_id_fkey" FOREIGN KEY ("hh_id") REFERENCES "public"."grantee_list"("hh_id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."swdi_score"
    ADD CONSTRAINT "swdi_score_hh_id_fkey" FOREIGN KEY ("hh_id") REFERENCES "public"."grantee_list"("hh_id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."system_resend_config"
    ADD CONSTRAINT "system_resend_config_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transfer_ack"
    ADD CONSTRAINT "transfer_ack_transfer_id_fkey" FOREIGN KEY ("transfer_id") REFERENCES "public"."grantee_transfer"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transfer_ack"
    ADD CONSTRAINT "transfer_ack_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transfer_request"
    ADD CONSTRAINT "transfer_request_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."transfer_request"
    ADD CONSTRAINT "transfer_request_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_smtp_config"
    ADD CONSTRAINT "user_smtp_config_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE "public"."auth_throttle" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."case_list" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "case_list scoped read" ON "public"."case_list" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality"))))) OR (("cs"."role" = 'case_manager'::"text") AND ("public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality") = ANY ("cs"."munis")))))));



CREATE POLICY "case_list scoped write" ON "public"."case_list" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality"))))) OR (("cs"."role" = 'case_manager'::"text") AND ("public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality") = ANY ("cs"."munis"))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality"))))) OR (("cs"."role" = 'case_manager'::"text") AND ("public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality") = ANY ("cs"."munis")))))));



ALTER TABLE "public"."cluster" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cluster read" ON "public"."cluster" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "concurrence_archive_editor_read" ON "public"."concurrence_row_archive" FOR SELECT TO "authenticated" USING (( SELECT "public"."monitor_caller_is_editor"() AS "monitor_caller_is_editor"));



CREATE POLICY "concurrence_batch_editor_read" ON "public"."concurrence_import_batch" FOR SELECT TO "authenticated" USING (( SELECT "public"."monitor_caller_is_editor"() AS "monitor_caller_is_editor"));



ALTER TABLE "public"."concurrence_import_batch" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."concurrence_row_archive" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_directory" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "email_directory authenticated read" ON "public"."email_directory" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."grantee_import_batch" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "grantee_import_batch authenticated all" ON "public"."grantee_import_batch" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."grantee_list" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "grantee_list scoped read" ON "public"."grantee_list" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text", 'poo_staff'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "grantee_list"."municipality")))) OR (("cs"."role" = ANY (ARRAY['case_manager'::"text", 'social_welfare_assistant'::"text"])) AND ("grantee_list"."municipality" = ANY ("cs"."munis")))))));



CREATE POLICY "grantee_list scoped write" ON "public"."grantee_list" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "grantee_list"."municipality")))) OR (("cs"."role" = ANY (ARRAY['case_manager'::"text", 'social_welfare_assistant'::"text"])) AND ("grantee_list"."municipality" = ANY ("cs"."munis"))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "grantee_list"."municipality")))) OR (("cs"."role" = ANY (ARRAY['case_manager'::"text", 'social_welfare_assistant'::"text"])) AND ("grantee_list"."municipality" = ANY ("cs"."munis")))))));



ALTER TABLE "public"."grantee_transfer" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "grantee_transfer authenticated all" ON "public"."grantee_transfer" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."import_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "import_log authenticated insert" ON "public"."import_log" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "import_log authenticated read" ON "public"."import_log" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ipcr_alert_read" ON "public"."ipcr_assignment_alert" FOR SELECT TO "authenticated" USING (( SELECT "private"."ipcr_is_editor"() AS "ipcr_is_editor"));



ALTER TABLE "public"."ipcr_assignment_alert" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ipcr_assignment_audit" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ipcr_assignment_proposal" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ipcr_assignment_read" ON "public"."ipcr_household_assignment" FOR SELECT TO "authenticated" USING (( SELECT "private"."ipcr_can_view_municipality"("ipcr_household_assignment"."municipality") AS "ipcr_can_view_municipality"));



ALTER TABLE "public"."ipcr_assignment_rule" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ipcr_audit_editor_read" ON "public"."ipcr_assignment_audit" FOR SELECT TO "authenticated" USING (( SELECT "private"."ipcr_is_editor"() AS "ipcr_is_editor"));



CREATE POLICY "ipcr_classification_read" ON "public"."ipcr_set_group_classification" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."ipcr_household_assignment" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ipcr_period" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ipcr_period_read" ON "public"."ipcr_period" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ipcr_proposal_read" ON "public"."ipcr_assignment_proposal" FOR SELECT TO "authenticated" USING ((( SELECT "private"."ipcr_is_editor"() AS "ipcr_is_editor") OR ("proposed_by" = ( SELECT "auth"."uid"() AS "uid")) OR ("requested_worker_user_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("requested_cm_user_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "ipcr_rule_read" ON "public"."ipcr_assignment_rule" FOR SELECT TO "authenticated" USING ((( SELECT "private"."ipcr_is_editor"() AS "ipcr_is_editor") OR (("status" = ANY (ARRAY['draft'::"text", 'published'::"text"])) AND ( SELECT "private"."ipcr_can_view_municipality"("ipcr_assignment_rule"."municipality") AS "ipcr_can_view_municipality"))));



ALTER TABLE "public"."ipcr_set_group_classification" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ipcr_supervision" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ipcr_supervision_read" ON "public"."ipcr_supervision" FOR SELECT TO "authenticated" USING ((( SELECT "private"."ipcr_is_editor"() AS "ipcr_is_editor") OR ("swa_user_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("case_manager_user_id" = ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."monitor" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "monitor_delete" ON "public"."monitor" FOR DELETE TO "authenticated" USING ("public"."monitor_caller_is_editor"());



CREATE POLICY "monitor_insert" ON "public"."monitor" FOR INSERT TO "authenticated" WITH CHECK ("public"."monitor_caller_is_editor"());



ALTER TABLE "public"."monitor_row" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "monitor_row_delete" ON "public"."monitor_row" FOR DELETE TO "authenticated" USING ("public"."monitor_caller_is_editor"());



CREATE POLICY "monitor_row_insert" ON "public"."monitor_row" FOR INSERT TO "authenticated" WITH CHECK ("public"."monitor_caller_is_editor"());



CREATE POLICY "monitor_row_select" ON "public"."monitor_row" FOR SELECT TO "authenticated" USING ((( SELECT "private"."ipcr_can_view_all_monitor_rows"() AS "ipcr_can_view_all_monitor_rows") OR (( SELECT "private"."ipcr_visible_municipalities"() AS "ipcr_visible_municipalities") @> ARRAY["municipality"])));



CREATE POLICY "monitor_row_update" ON "public"."monitor_row" FOR UPDATE TO "authenticated" USING (( SELECT "private"."ipcr_can_edit_monitor_row"("monitor_row"."beneficiary_hh_id", "monitor_row"."municipality") AS "ipcr_can_edit_monitor_row")) WITH CHECK (( SELECT "private"."ipcr_can_edit_monitor_row"("monitor_row"."beneficiary_hh_id", "monitor_row"."municipality") AS "ipcr_can_edit_monitor_row"));



CREATE POLICY "monitor_select" ON "public"."monitor" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "monitor_update" ON "public"."monitor" FOR UPDATE TO "authenticated" USING ("public"."monitor_caller_is_editor"()) WITH CHECK ("public"."monitor_caller_is_editor"());



ALTER TABLE "public"."municipality" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "municipality read" ON "public"."municipality" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."notification_clear" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notification_clear self read" ON "public"."notification_clear" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "notification_clear self write" ON "public"."notification_clear" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."registration_request" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."smtp_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."staff" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff admin write" ON "public"."staff" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."staff" "me"
  WHERE (("me"."user_id" = "auth"."uid"()) AND ("me"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."staff" "me"
  WHERE (("me"."user_id" = "auth"."uid"()) AND ("me"."role" = 'admin'::"text")))));



CREATE POLICY "staff self read" ON "public"."staff" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."staff" "me"
  WHERE (("me"."user_id" = "auth"."uid"()) AND ("me"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])))))));



ALTER TABLE "public"."staff_directory" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_directory_read" ON "public"."staff_directory" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "staff_muni admin write" ON "public"."staff_municipality" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."staff" "me"
  WHERE (("me"."user_id" = "auth"."uid"()) AND ("me"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."staff" "me"
  WHERE (("me"."user_id" = "auth"."uid"()) AND ("me"."role" = 'admin'::"text")))));



CREATE POLICY "staff_muni read" ON "public"."staff_municipality" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."staff" "me"
  WHERE (("me"."user_id" = "auth"."uid"()) AND ("me"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])))))));



ALTER TABLE "public"."staff_municipality" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."swdi_encoding" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "swdi_encoding scoped read" ON "public"."swdi_encoding" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text", 'poo_staff'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "swdi_encoding"."municipality")))) OR (("cs"."role" = ANY (ARRAY['case_manager'::"text", 'social_welfare_assistant'::"text"])) AND ("swdi_encoding"."municipality" = ANY ("cs"."munis")))))));



CREATE POLICY "swdi_encoding scoped write" ON "public"."swdi_encoding" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"]))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])))));



ALTER TABLE "public"."swdi_score" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "swdi_score scoped read" ON "public"."swdi_score" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text", 'poo_staff'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "swdi_score"."city_name")))) OR (("cs"."role" = ANY (ARRAY['case_manager'::"text", 'social_welfare_assistant'::"text"])) AND ("swdi_score"."city_name" = ANY ("cs"."munis")))))));



CREATE POLICY "swdi_score scoped write" ON "public"."swdi_score" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"]))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])))));



ALTER TABLE "public"."system_resend_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transfer_ack" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transfer_ack self read" ON "public"."transfer_ack" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "transfer_ack self write" ON "public"."transfer_ack" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."transfer_request" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transfer_request authenticated insert" ON "public"."transfer_request" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "transfer_request authenticated read" ON "public"."transfer_request" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."user_smtp_config" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."case_list";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."grantee_transfer";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."monitor_row";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."registration_request";



GRANT USAGE ON SCHEMA "private" TO "authenticated";
GRANT USAGE ON SCHEMA "private" TO "service_role";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";






















































































































































REVOKE ALL ON FUNCTION "private"."concurrence_case_id"("p_hhid" "text", "p_episode_at" timestamp without time zone) FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."concurrence_normalize_hhid"("p_value" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."concurrence_parse_timestamp"("p_value" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."ipcr_can_edit_monitor_row"("target_hh_id" "text", "target_municipality" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ipcr_can_edit_monitor_row"("target_hh_id" "text", "target_municipality" "text") TO "authenticated";
GRANT ALL ON FUNCTION "private"."ipcr_can_edit_monitor_row"("target_hh_id" "text", "target_municipality" "text") TO "service_role";



REVOKE ALL ON FUNCTION "private"."ipcr_can_view_all_monitor_rows"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ipcr_can_view_all_monitor_rows"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."ipcr_can_view_all_monitor_rows"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."ipcr_can_view_municipality"("target_municipality" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ipcr_can_view_municipality"("target_municipality" "text") TO "authenticated";
GRANT ALL ON FUNCTION "private"."ipcr_can_view_municipality"("target_municipality" "text") TO "service_role";



REVOKE ALL ON FUNCTION "private"."ipcr_flag_household_profile_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ipcr_flag_household_profile_change"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."ipcr_is_editor"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ipcr_is_editor"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."ipcr_is_editor"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."ipcr_monitor_kpi_matches"("p_kpi" "jsonb", "p_data" "jsonb", "p_values" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ipcr_monitor_kpi_matches"("p_kpi" "jsonb", "p_data" "jsonb", "p_values" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "private"."ipcr_visible_municipalities"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ipcr_visible_municipalities"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."ipcr_visible_municipalities"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."monitor_csv_field_is_visible"("p_field_key" "text", "p_values" "jsonb", "p_data" "jsonb", "p_fields" "jsonb", "p_visiting" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."monitor_csv_field_is_visible"("p_field_key" "text", "p_values" "jsonb", "p_data" "jsonb", "p_fields" "jsonb", "p_visiting" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "private"."monitor_csv_field_is_visible"("p_field_key" "text", "p_values" "jsonb", "p_data" "jsonb", "p_fields" "jsonb", "p_visiting" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "private"."reconcile_concurrence_snapshot_impl"("p_filename" "text", "p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."reconcile_concurrence_snapshot_impl"("p_filename" "text", "p_rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "private"."reconcile_concurrence_snapshot_impl"("p_filename" "text", "p_rows" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "private"."restore_concurrence_row_impl"("p_archive_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."restore_concurrence_row_impl"("p_archive_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "private"."restore_concurrence_row_impl"("p_archive_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."bulk_update_monitor_rows_from_csv"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_apply" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."bulk_update_monitor_rows_from_csv"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_apply" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_update_monitor_rows_from_csv"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_apply" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."bulk_update_monitor_rows_from_csv_v2"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_overwrite_existing" boolean, "p_apply" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."bulk_update_monitor_rows_from_csv_v2"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_overwrite_existing" boolean, "p_apply" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_update_monitor_rows_from_csv_v2"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb", "p_overwrite_existing" boolean, "p_apply" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."case_list_municipality"("p_hh_id" "text", "p_muni" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."case_list_municipality"("p_hh_id" "text", "p_muni" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."case_list_municipality"("p_hh_id" "text", "p_muni" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."case_risk_counts"("p_cluster" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."case_risk_counts"("p_cluster" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."case_risk_counts"("p_cluster" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."case_typology_counts"("p_cluster" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."case_typology_counts"("p_cluster" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."case_typology_counts"("p_cluster" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."current_scope"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_scope"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_scope"() TO "service_role";



GRANT ALL ON FUNCTION "public"."dashboard_municipality_metrics"("p_cluster" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."dashboard_municipality_metrics"("p_cluster" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."dashboard_municipality_metrics"("p_cluster" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_system_resend_secret"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_system_resend_secret"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_user_smtp_secret"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_user_smtp_secret"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_unique_account_employee_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_unique_account_employee_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_unique_account_employee_number"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_system_resend_config"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_system_resend_config"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_user_smtp_config"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_user_smtp_config"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."grantee_active_demographics"("p_cluster" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."grantee_active_demographics"("p_cluster" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."grantee_active_demographics"("p_cluster" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."grantee_municipality_counts"("p_cluster" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."grantee_municipality_counts"("p_cluster" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."grantee_municipality_counts"("p_cluster" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."grantee_status_counts"("p_cluster" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."grantee_status_counts"("p_cluster" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."grantee_status_counts"("p_cluster" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_admin_caseload_summary"("p_period_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_admin_caseload_summary"("p_period_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_assign_filtered_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangays" "text"[], "p_set_groups" "text"[], "p_query" "text", "p_assignment" "text", "p_user_id" "uuid", "p_monitoring" "text", "p_client_status" "text", "p_excluded_hhids" "text"[], "p_cm_id" "uuid", "p_actor_id" "uuid", "p_as_proposal" boolean, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_assign_filtered_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangays" "text"[], "p_set_groups" "text"[], "p_query" "text", "p_assignment" "text", "p_user_id" "uuid", "p_monitoring" "text", "p_client_status" "text", "p_excluded_hhids" "text"[], "p_cm_id" "uuid", "p_actor_id" "uuid", "p_as_proposal" boolean, "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_assignment_summary"("p_period_id" "uuid", "p_municipalities" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_assignment_summary"("p_period_id" "uuid", "p_municipalities" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_client_status_options"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_client_status_options"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_my_caseload_scorecard"("p_period_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_my_caseload_scorecard"("p_period_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_publish_period"("p_period_id" "uuid", "p_actor_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_publish_period"("p_period_id" "uuid", "p_actor_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_remove_household_assignment"("p_period_id" "uuid", "p_hh_id" "text", "p_actor_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_remove_household_assignment"("p_period_id" "uuid", "p_hh_id" "text", "p_actor_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_reset_caseload"("p_period_id" "uuid", "p_actor_id" "uuid", "p_user_id" "uuid", "p_municipality" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_reset_caseload"("p_period_id" "uuid", "p_actor_id" "uuid", "p_user_id" "uuid", "p_municipality" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_review_all_proposals"("p_period_id" "uuid", "p_decision" "text", "p_actor_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_review_all_proposals"("p_period_id" "uuid", "p_decision" "text", "p_actor_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_search_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangay" "text", "p_set_group" "text", "p_query" "text", "p_assignment" "text", "p_user_id" "uuid", "p_monitoring" "text", "p_client_status" "text", "p_limit" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_search_households"("p_period_id" "uuid", "p_municipality" "text", "p_barangay" "text", "p_set_group" "text", "p_query" "text", "p_assignment" "text", "p_user_id" "uuid", "p_monitoring" "text", "p_client_status" "text", "p_limit" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_set_group_options"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_set_group_options"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."ipcr_working_assignment_count"("p_period_id" "uuid", "p_municipalities" "text"[], "p_client_statuses" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ipcr_working_assignment_count"("p_period_id" "uuid", "p_municipalities" "text"[], "p_client_statuses" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."monitor_caller_can_edit_muni"("target_muni" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."monitor_caller_can_edit_muni"("target_muni" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."monitor_caller_can_edit_muni"("target_muni" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."monitor_caller_is_editor"() TO "anon";
GRANT ALL ON FUNCTION "public"."monitor_caller_is_editor"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."monitor_caller_is_editor"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."monitor_case_manager_options"("p_monitor_id" "uuid", "p_municipalities" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."monitor_case_manager_options"("p_monitor_id" "uuid", "p_municipalities" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."monitor_csv_replacement_preview"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."monitor_csv_replacement_preview"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."monitor_csv_replacement_preview"("p_monitor_id" "uuid", "p_match_mode" "text", "p_ids" "jsonb", "p_field_key" "text", "p_target_value" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."next_transfer_referral_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_transfer_referral_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_transfer_referral_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."reconcile_concurrence_snapshot"("filename" "text", "rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reconcile_concurrence_snapshot"("filename" "text", "rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reconcile_concurrence_snapshot"("filename" "text", "rows" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_grantee_lhf"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_grantee_lhf"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_grantee_lhf"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."restore_concurrence_row"("archive_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_concurrence_row"("archive_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restore_concurrence_row"("archive_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_system_resend_config"("p_api_key" "text", "p_from_addr" "text", "p_reply_to" "text", "p_enabled" boolean, "p_updated_by" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_system_resend_config"("p_api_key" "text", "p_from_addr" "text", "p_reply_to" "text", "p_enabled" boolean, "p_updated_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_user_smtp_config"("p_user_id" "uuid", "p_host" "text", "p_port" integer, "p_username" "text", "p_password" "text", "p_from_addr" "text", "p_enabled" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_user_smtp_config"("p_user_id" "uuid", "p_host" "text", "p_port" integer, "p_username" "text", "p_password" "text", "p_from_addr" "text", "p_enabled" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."staff_directory_compose_name"() TO "anon";
GRANT ALL ON FUNCTION "public"."staff_directory_compose_name"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."staff_directory_compose_name"() TO "service_role";



GRANT ALL ON FUNCTION "public"."staff_directory_touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."staff_directory_touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."staff_directory_touch_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."swdi_gap_counts"("p_munis" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."swdi_gap_counts"("p_munis" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."swdi_gap_counts"("p_munis" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_changed_grantees_to_monitors"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_changed_grantees_to_monitors"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_monitor_grantee_profiles"("p_monitor_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_monitor_grantee_profiles"("p_monitor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_monitor_grantee_profiles"("p_monitor_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";


















GRANT ALL ON TABLE "public"."auth_throttle" TO "anon";
GRANT ALL ON TABLE "public"."auth_throttle" TO "authenticated";
GRANT ALL ON TABLE "public"."auth_throttle" TO "service_role";



GRANT ALL ON SEQUENCE "public"."auth_throttle_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."auth_throttle_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."auth_throttle_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."grantee_list" TO "anon";
GRANT ALL ON TABLE "public"."grantee_list" TO "authenticated";
GRANT ALL ON TABLE "public"."grantee_list" TO "service_role";



GRANT ALL ON TABLE "public"."barangay_options" TO "anon";
GRANT ALL ON TABLE "public"."barangay_options" TO "authenticated";
GRANT ALL ON TABLE "public"."barangay_options" TO "service_role";



GRANT ALL ON TABLE "public"."case_list" TO "anon";
GRANT ALL ON TABLE "public"."case_list" TO "authenticated";
GRANT ALL ON TABLE "public"."case_list" TO "service_role";



GRANT ALL ON TABLE "public"."case_cml_options" TO "anon";
GRANT ALL ON TABLE "public"."case_cml_options" TO "authenticated";
GRANT ALL ON TABLE "public"."case_cml_options" TO "service_role";



GRANT ALL ON TABLE "public"."case_risk_options" TO "anon";
GRANT ALL ON TABLE "public"."case_risk_options" TO "authenticated";
GRANT ALL ON TABLE "public"."case_risk_options" TO "service_role";



GRANT ALL ON TABLE "public"."case_status_options" TO "anon";
GRANT ALL ON TABLE "public"."case_status_options" TO "authenticated";
GRANT ALL ON TABLE "public"."case_status_options" TO "service_role";



GRANT ALL ON TABLE "public"."case_typology_category_options" TO "anon";
GRANT ALL ON TABLE "public"."case_typology_category_options" TO "authenticated";
GRANT ALL ON TABLE "public"."case_typology_category_options" TO "service_role";



GRANT ALL ON TABLE "public"."case_typology_options" TO "anon";
GRANT ALL ON TABLE "public"."case_typology_options" TO "authenticated";
GRANT ALL ON TABLE "public"."case_typology_options" TO "service_role";



GRANT ALL ON TABLE "public"."cluster" TO "anon";
GRANT ALL ON TABLE "public"."cluster" TO "authenticated";
GRANT ALL ON TABLE "public"."cluster" TO "service_role";



GRANT ALL ON TABLE "public"."concurrence_import_batch" TO "service_role";
GRANT SELECT ON TABLE "public"."concurrence_import_batch" TO "authenticated";



GRANT ALL ON TABLE "public"."concurrence_row_archive" TO "service_role";
GRANT SELECT ON TABLE "public"."concurrence_row_archive" TO "authenticated";



GRANT ALL ON TABLE "public"."email_directory" TO "anon";
GRANT ALL ON TABLE "public"."email_directory" TO "authenticated";
GRANT ALL ON TABLE "public"."email_directory" TO "service_role";



GRANT ALL ON TABLE "public"."grantee_import_batch" TO "anon";
GRANT ALL ON TABLE "public"."grantee_import_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."grantee_import_batch" TO "service_role";



GRANT ALL ON TABLE "public"."grantee_status_options" TO "anon";
GRANT ALL ON TABLE "public"."grantee_status_options" TO "authenticated";
GRANT ALL ON TABLE "public"."grantee_status_options" TO "service_role";



GRANT ALL ON TABLE "public"."grantee_transfer" TO "anon";
GRANT ALL ON TABLE "public"."grantee_transfer" TO "authenticated";
GRANT ALL ON TABLE "public"."grantee_transfer" TO "service_role";



GRANT ALL ON TABLE "public"."import_log" TO "anon";
GRANT ALL ON TABLE "public"."import_log" TO "authenticated";
GRANT ALL ON TABLE "public"."import_log" TO "service_role";



GRANT ALL ON TABLE "public"."ipcr_assignment_alert" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_assignment_alert" TO "authenticated";



GRANT ALL ON TABLE "public"."ipcr_assignment_audit" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_assignment_audit" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."ipcr_assignment_audit_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ipcr_assignment_audit_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ipcr_assignment_audit_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ipcr_assignment_proposal" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_assignment_proposal" TO "authenticated";



GRANT ALL ON TABLE "public"."ipcr_assignment_rule" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_assignment_rule" TO "authenticated";



GRANT ALL ON TABLE "public"."ipcr_household_assignment" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_household_assignment" TO "authenticated";



GRANT ALL ON TABLE "public"."ipcr_period" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_period" TO "authenticated";



GRANT ALL ON TABLE "public"."ipcr_set_group_classification" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_set_group_classification" TO "authenticated";



GRANT ALL ON TABLE "public"."ipcr_supervision" TO "service_role";
GRANT SELECT ON TABLE "public"."ipcr_supervision" TO "authenticated";



GRANT ALL ON TABLE "public"."monitor" TO "anon";
GRANT ALL ON TABLE "public"."monitor" TO "authenticated";
GRANT ALL ON TABLE "public"."monitor" TO "service_role";



GRANT ALL ON TABLE "public"."monitor_row" TO "anon";
GRANT ALL ON TABLE "public"."monitor_row" TO "authenticated";
GRANT ALL ON TABLE "public"."monitor_row" TO "service_role";



GRANT ALL ON TABLE "public"."monitor_row_with_assignment" TO "authenticated";
GRANT ALL ON TABLE "public"."monitor_row_with_assignment" TO "service_role";



GRANT ALL ON TABLE "public"."municipality" TO "anon";
GRANT ALL ON TABLE "public"."municipality" TO "authenticated";
GRANT ALL ON TABLE "public"."municipality" TO "service_role";



GRANT ALL ON TABLE "public"."notification_clear" TO "anon";
GRANT ALL ON TABLE "public"."notification_clear" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_clear" TO "service_role";



GRANT ALL ON TABLE "public"."registration_request" TO "anon";
GRANT ALL ON TABLE "public"."registration_request" TO "authenticated";
GRANT ALL ON TABLE "public"."registration_request" TO "service_role";



GRANT ALL ON TABLE "public"."smtp_config" TO "anon";
GRANT ALL ON TABLE "public"."smtp_config" TO "authenticated";
GRANT ALL ON TABLE "public"."smtp_config" TO "service_role";



GRANT ALL ON TABLE "public"."staff" TO "anon";
GRANT ALL ON TABLE "public"."staff" TO "authenticated";
GRANT ALL ON TABLE "public"."staff" TO "service_role";



GRANT ALL ON TABLE "public"."staff_directory" TO "anon";
GRANT ALL ON TABLE "public"."staff_directory" TO "authenticated";
GRANT ALL ON TABLE "public"."staff_directory" TO "service_role";



GRANT ALL ON TABLE "public"."staff_municipality" TO "anon";
GRANT ALL ON TABLE "public"."staff_municipality" TO "authenticated";
GRANT ALL ON TABLE "public"."staff_municipality" TO "service_role";



GRANT ALL ON TABLE "public"."swdi_encoding" TO "anon";
GRANT ALL ON TABLE "public"."swdi_encoding" TO "authenticated";
GRANT ALL ON TABLE "public"."swdi_encoding" TO "service_role";



GRANT ALL ON TABLE "public"."swdi_score" TO "anon";
GRANT ALL ON TABLE "public"."swdi_score" TO "authenticated";
GRANT ALL ON TABLE "public"."swdi_score" TO "service_role";



GRANT ALL ON TABLE "public"."system_resend_config" TO "service_role";



GRANT ALL ON TABLE "public"."transfer_ack" TO "anon";
GRANT ALL ON TABLE "public"."transfer_ack" TO "authenticated";
GRANT ALL ON TABLE "public"."transfer_ack" TO "service_role";



GRANT ALL ON SEQUENCE "public"."transfer_referral_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."transfer_referral_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transfer_referral_seq" TO "service_role";



GRANT ALL ON TABLE "public"."transfer_request" TO "anon";
GRANT ALL ON TABLE "public"."transfer_request" TO "authenticated";
GRANT ALL ON TABLE "public"."transfer_request" TO "service_role";



GRANT ALL ON TABLE "public"."user_smtp_config" TO "service_role";



GRANT ALL ON TABLE "public"."v_grantee_list" TO "anon";
GRANT ALL ON TABLE "public"."v_grantee_list" TO "authenticated";
GRANT ALL ON TABLE "public"."v_grantee_list" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































