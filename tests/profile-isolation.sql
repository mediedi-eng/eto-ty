-- Synthetic profiles in a disposable database. Roll back all test rows.
BEGIN;
INSERT INTO care.patient VALUES
('00000000-0000-0000-0000-000000000001','example-a'),
('00000000-0000-0000-0000-000000000002','example-b');
SET LOCAL ROLE etoty_runtime;
DO $checks$
DECLARE
    a uuid := '00000000-0000-0000-0000-000000000001';
    b uuid := '00000000-0000-0000-0000-000000000002';
    src uuid := '00000000-0000-0000-0000-000000000003';
    fact uuid := '00000000-0000-0000-0000-000000000004';
BEGIN
    IF EXISTS (SELECT FROM care.patient) THEN RAISE EXCEPTION 'missing context exposed a patient'; END IF;
    PERFORM set_config('etoty.patient_id', a::text, true);
    INSERT INTO care.source(patient_id,id,kind,sha256) VALUES (a,src,'document',repeat('a',64));
    INSERT INTO care.evidence VALUES (a,fact,src,1,'sample','2026-03-12','accepted');
    INSERT INTO care.region_link VALUES (a,fact,'kidney');
    BEGIN
        INSERT INTO care.source(patient_id,id,kind) VALUES (b,src,'diary');
        RAISE EXCEPTION 'cross-profile write allowed';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    PERFORM set_config('etoty.patient_id', b::text, true);
    IF EXISTS (SELECT FROM care.source) OR EXISTS (SELECT FROM care.evidence) OR EXISTS (SELECT FROM care.region_link)
        THEN RAISE EXCEPTION 'cross-profile read allowed'; END IF;
    BEGIN
        INSERT INTO care.evidence VALUES (b,fact,src,1,'sample',NULL,'candidate');
        RAISE EXCEPTION 'cross-profile reference allowed';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    PERFORM set_config('etoty.patient_id', a::text, true);
    DELETE FROM care.source WHERE id=src;
    IF EXISTS (SELECT FROM care.region_link) OR EXISTS (SELECT FROM care.evidence)
        THEN RAISE EXCEPTION 'orphaned evidence'; END IF;
END
$checks$;
ROLLBACK;
