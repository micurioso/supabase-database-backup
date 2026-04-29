


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


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






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


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


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

SET default_tablespace = '';

SET default_table_access_method = "heap";


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
    "lhf" boolean
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


CREATE TABLE IF NOT EXISTS "public"."grantee_import_batch" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "imported_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "imported_by" "uuid",
    "filename" "text",
    "total_rows" integer,
    "transfer_in_count" integer DEFAULT 0 NOT NULL,
    "transfer_out_count" integer DEFAULT 0 NOT NULL,
    "intra_cavite_count" integer DEFAULT 0 NOT NULL
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
    CONSTRAINT "grantee_transfer_kind_check" CHECK (("kind" = ANY (ARRAY['in'::"text", 'out'::"text", 'intra'::"text"])))
);


ALTER TABLE "public"."grantee_transfer" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."municipality" (
    "name" "text" NOT NULL,
    "cluster_id" integer NOT NULL
);


ALTER TABLE "public"."municipality" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."staff" (
    "user_id" "uuid" NOT NULL,
    "full_name" "text",
    "role" "text" NOT NULL,
    "cluster_id" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'provincial'::"text", 'swoIII'::"text", 'swoII'::"text", 'field_staff'::"text"])))
);


ALTER TABLE "public"."staff" OWNER TO "postgres";


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
    "last_name" "text" NOT NULL
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
    (EXISTS ( SELECT 1
           FROM "public"."case_list" "c"
          WHERE (("c"."hh_id" = "g"."hh_id") AND ("c"."is_manual_entry" = false) AND ("c"."record_no" IS NOT NULL)))) AS "has_verified_record_no"
   FROM "public"."grantee_list" "g";


ALTER VIEW "public"."v_grantee_list" OWNER TO "postgres";


ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_record_no_key" UNIQUE ("record_no");



ALTER TABLE ONLY "public"."cluster"
    ADD CONSTRAINT "cluster_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."cluster"
    ADD CONSTRAINT "cluster_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grantee_import_batch"
    ADD CONSTRAINT "grantee_import_batch_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grantee_list"
    ADD CONSTRAINT "grantee_list_hh_id_key" UNIQUE ("hh_id");



ALTER TABLE ONLY "public"."grantee_list"
    ADD CONSTRAINT "grantee_list_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grantee_transfer"
    ADD CONSTRAINT "grantee_transfer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."municipality"
    ADD CONSTRAINT "municipality_pkey" PRIMARY KEY ("name");



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



CREATE INDEX "case_list_approval_status_idx" ON "public"."case_list" USING "btree" ("approval_status");



CREATE INDEX "case_list_hh_id_idx" ON "public"."case_list" USING "btree" ("hh_id");



CREATE INDEX "case_list_hh_id_verified_idx" ON "public"."case_list" USING "btree" ("hh_id") WHERE (("is_manual_entry" = false) AND ("record_no" IS NOT NULL));



CREATE INDEX "case_list_municipality_idx" ON "public"."case_list" USING "btree" ("municipality");



CREATE INDEX "case_list_risk_level_idx" ON "public"."case_list" USING "btree" ("risk_level");



CREATE INDEX "case_list_status_trgm_idx" ON "public"."case_list" USING "gin" ("status" "public"."gin_trgm_ops");



CREATE INDEX "case_list_typology_category_idx" ON "public"."case_list" USING "btree" ("typology_category");



CREATE INDEX "case_list_typology_name_idx" ON "public"."case_list" USING "btree" ("typology_name");



CREATE INDEX "grantee_import_batch_imported_at_idx" ON "public"."grantee_import_batch" USING "btree" ("imported_at" DESC);



CREATE INDEX "grantee_list_assigned_cml_idx" ON "public"."grantee_list" USING "btree" ("assigned_cml");



CREATE INDEX "grantee_list_barangay_idx" ON "public"."grantee_list" USING "btree" ("barangay");



CREATE INDEX "grantee_list_entry_id_idx" ON "public"."grantee_list" USING "btree" ("entry_id");



CREATE INDEX "grantee_list_lhf_idx" ON "public"."grantee_list" USING "btree" ("lhf");



CREATE INDEX "grantee_list_municipality_idx" ON "public"."grantee_list" USING "btree" ("municipality");



CREATE INDEX "grantee_list_status_idx" ON "public"."grantee_list" USING "btree" ("status");



CREATE INDEX "grantee_list_status_trgm_idx" ON "public"."grantee_list" USING "gin" ("status" "public"."gin_trgm_ops");



CREATE INDEX "grantee_list_target_tag_idx" ON "public"."grantee_list" USING "btree" ("target_tag");



CREATE INDEX "grantee_transfer_batch_kind_idx" ON "public"."grantee_transfer" USING "btree" ("batch_id", "kind");



CREATE INDEX "grantee_transfer_hh_id_idx" ON "public"."grantee_transfer" USING "btree" ("hh_id");



CREATE INDEX "staff_directory_municipality_idx" ON "public"."staff_directory" USING "btree" ("municipality");



CREATE UNIQUE INDEX "staff_directory_name_muni_idx" ON "public"."staff_directory" USING "btree" ("lower"("name"), "municipality");



CREATE INDEX "swdi_encoding_encoder_idx" ON "public"."swdi_encoding" USING "btree" ("encoder");



CREATE INDEX "swdi_encoding_hh_id_idx" ON "public"."swdi_encoding" USING "btree" ("hh_id");



CREATE INDEX "swdi_encoding_municipality_idx" ON "public"."swdi_encoding" USING "btree" ("municipality");



CREATE INDEX "swdi_score_city_name_idx" ON "public"."swdi_score" USING "btree" ("city_name");



CREATE INDEX "swdi_score_hh_id_idx" ON "public"."swdi_score" USING "btree" ("hh_id");



CREATE OR REPLACE TRIGGER "case_list_set_updated_at" BEFORE UPDATE ON "public"."case_list" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "staff_directory_compose_name" BEFORE INSERT OR UPDATE OF "first_name", "middle_name", "last_name" ON "public"."staff_directory" FOR EACH ROW EXECUTE FUNCTION "public"."staff_directory_compose_name"();



CREATE OR REPLACE TRIGGER "staff_directory_set_updated_at" BEFORE UPDATE ON "public"."staff_directory" FOR EACH ROW EXECUTE FUNCTION "public"."staff_directory_touch_updated_at"();



CREATE OR REPLACE TRIGGER "staff_set_updated_at" BEFORE UPDATE ON "public"."staff" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."staff"("user_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."case_list"
    ADD CONSTRAINT "case_list_hh_id_fkey" FOREIGN KEY ("hh_id") REFERENCES "public"."grantee_list"("hh_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grantee_import_batch"
    ADD CONSTRAINT "grantee_import_batch_imported_by_fkey" FOREIGN KEY ("imported_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."grantee_transfer"
    ADD CONSTRAINT "grantee_transfer_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."grantee_import_batch"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."municipality"
    ADD CONSTRAINT "municipality_cluster_id_fkey" FOREIGN KEY ("cluster_id") REFERENCES "public"."cluster"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."staff"
    ADD CONSTRAINT "staff_cluster_id_fkey" FOREIGN KEY ("cluster_id") REFERENCES "public"."cluster"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."staff_directory"
    ADD CONSTRAINT "staff_directory_municipality_fkey" FOREIGN KEY ("municipality") REFERENCES "public"."municipality"("name") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."staff_municipality"
    ADD CONSTRAINT "staff_municipality_municipality_fkey" FOREIGN KEY ("municipality") REFERENCES "public"."municipality"("name") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."staff_municipality"
    ADD CONSTRAINT "staff_municipality_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."staff"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."staff"
    ADD CONSTRAINT "staff_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."swdi_encoding"
    ADD CONSTRAINT "swdi_encoding_hh_id_fkey" FOREIGN KEY ("hh_id") REFERENCES "public"."grantee_list"("hh_id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."swdi_score"
    ADD CONSTRAINT "swdi_score_hh_id_fkey" FOREIGN KEY ("hh_id") REFERENCES "public"."grantee_list"("hh_id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE "public"."case_list" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "case_list scoped read" ON "public"."case_list" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality"))))) OR (("cs"."role" = 'field_staff'::"text") AND ("public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality") = ANY ("cs"."munis")))))));



CREATE POLICY "case_list scoped write" ON "public"."case_list" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality"))))) OR (("cs"."role" = 'field_staff'::"text") AND ("public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality") = ANY ("cs"."munis"))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality"))))) OR (("cs"."role" = 'field_staff'::"text") AND ("public"."case_list_municipality"("case_list"."hh_id", "case_list"."municipality") = ANY ("cs"."munis")))))));



ALTER TABLE "public"."cluster" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cluster read" ON "public"."cluster" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."grantee_import_batch" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "grantee_import_batch authenticated all" ON "public"."grantee_import_batch" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."grantee_list" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "grantee_list scoped read" ON "public"."grantee_list" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "grantee_list"."municipality")))) OR (("cs"."role" = 'field_staff'::"text") AND ("grantee_list"."municipality" = ANY ("cs"."munis")))))));



CREATE POLICY "grantee_list scoped write" ON "public"."grantee_list" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "grantee_list"."municipality")))) OR (("cs"."role" = 'field_staff'::"text") AND ("grantee_list"."municipality" = ANY ("cs"."munis"))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "grantee_list"."municipality")))) OR (("cs"."role" = 'field_staff'::"text") AND ("grantee_list"."municipality" = ANY ("cs"."munis")))))));



ALTER TABLE "public"."grantee_transfer" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "grantee_transfer authenticated all" ON "public"."grantee_transfer" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."municipality" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "municipality read" ON "public"."municipality" FOR SELECT TO "authenticated" USING (true);



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
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "swdi_encoding"."municipality")))) OR (("cs"."role" = 'field_staff'::"text") AND ("swdi_encoding"."municipality" = ANY ("cs"."munis")))))));



CREATE POLICY "swdi_encoding scoped write" ON "public"."swdi_encoding" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"]))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])))));



ALTER TABLE "public"."swdi_score" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "swdi_score scoped read" ON "public"."swdi_score" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE (("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])) OR (("cs"."role" = ANY (ARRAY['swoIII'::"text", 'swoII'::"text"])) AND ("cs"."cluster_id" = ( SELECT "m"."cluster_id"
           FROM "public"."municipality" "m"
          WHERE ("m"."name" = "swdi_score"."city_name")))) OR (("cs"."role" = 'field_staff'::"text") AND ("swdi_score"."city_name" = ANY ("cs"."munis")))))));



CREATE POLICY "swdi_score scoped write" ON "public"."swdi_score" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"]))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."current_scope"() "cs"("role", "cluster_id", "munis")
  WHERE ("cs"."role" = ANY (ARRAY['admin'::"text", 'provincial'::"text"])))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


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



GRANT ALL ON FUNCTION "public"."refresh_grantee_lhf"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_grantee_lhf"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_grantee_lhf"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



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



GRANT ALL ON TABLE "public"."grantee_import_batch" TO "anon";
GRANT ALL ON TABLE "public"."grantee_import_batch" TO "authenticated";
GRANT ALL ON TABLE "public"."grantee_import_batch" TO "service_role";



GRANT ALL ON TABLE "public"."grantee_status_options" TO "anon";
GRANT ALL ON TABLE "public"."grantee_status_options" TO "authenticated";
GRANT ALL ON TABLE "public"."grantee_status_options" TO "service_role";



GRANT ALL ON TABLE "public"."grantee_transfer" TO "anon";
GRANT ALL ON TABLE "public"."grantee_transfer" TO "authenticated";
GRANT ALL ON TABLE "public"."grantee_transfer" TO "service_role";



GRANT ALL ON TABLE "public"."municipality" TO "anon";
GRANT ALL ON TABLE "public"."municipality" TO "authenticated";
GRANT ALL ON TABLE "public"."municipality" TO "service_role";



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































