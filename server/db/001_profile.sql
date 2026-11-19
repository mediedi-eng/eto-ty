-- Run once as the migration owner in a fresh pilot database.
BEGIN;
CREATE ROLE etoty_runtime NOLOGIN NOBYPASSRLS;
CREATE SCHEMA care;
REVOKE ALL ON SCHEMA care FROM PUBLIC;
GRANT USAGE ON SCHEMA care TO etoty_runtime;

CREATE TABLE care.patient (
    id uuid PRIMARY KEY,
    account_subject text NOT NULL UNIQUE
);

CREATE TABLE care.source (
    patient_id uuid NOT NULL REFERENCES care.patient(id) ON DELETE CASCADE,
    id uuid NOT NULL,
    kind text NOT NULL CHECK (kind IN ('document', 'diary', 'device', 'message')),
    object_key text UNIQUE,
    sha256 text CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (patient_id, id),
    UNIQUE (patient_id, sha256)
);

CREATE TABLE care.evidence (
    patient_id uuid NOT NULL,
    id uuid NOT NULL,
    source_id uuid NOT NULL,
    page integer CHECK (page >= 1),
    excerpt text NOT NULL CHECK (length(trim(excerpt)) > 0),
    event_date date,
    verification text NOT NULL CHECK (verification IN ('candidate','accepted','withdrawn')),
    PRIMARY KEY (patient_id, id),
    FOREIGN KEY (patient_id, source_id) REFERENCES care.source(patient_id, id) ON DELETE CASCADE
);

CREATE TABLE care.region_link (
    patient_id uuid NOT NULL,
    evidence_id uuid NOT NULL,
    region_code text NOT NULL,
    PRIMARY KEY (patient_id, evidence_id, region_code),
    FOREIGN KEY (patient_id, evidence_id) REFERENCES care.evidence(patient_id, id) ON DELETE CASCADE
);

-- The trusted API sets this transaction-local value after resolving its session.
-- End-user devices never connect to Postgres or receive the runtime credential.
CREATE FUNCTION care.current_patient() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('etoty.patient_id', true), '')::uuid;
$$;

ALTER TABLE care.patient ENABLE ROW LEVEL SECURITY;
ALTER TABLE care.patient FORCE ROW LEVEL SECURITY;
CREATE POLICY own_profile ON care.patient USING (id = care.current_patient());
GRANT SELECT ON care.patient TO etoty_runtime;

DO $policies$
DECLARE
    item text;
BEGIN
    FOREACH item IN ARRAY ARRAY['source','evidence','region_link'] LOOP
        EXECUTE format('ALTER TABLE care.%I ENABLE ROW LEVEL SECURITY', item);
        EXECUTE format('ALTER TABLE care.%I FORCE ROW LEVEL SECURITY', item);
        EXECUTE format('CREATE POLICY own_rows ON care.%I USING (patient_id = care.current_patient()) WITH CHECK (patient_id = care.current_patient())', item);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON care.%I TO etoty_runtime', item);
    END LOOP;
END
$policies$;
COMMIT;
