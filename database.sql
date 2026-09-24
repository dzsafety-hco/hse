-- PostgreSQL schema for the HSE School forms.
-- The frontend must submit data through a backend API; GitHub Pages cannot connect to SQL directly.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS visitor_registrations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name VARCHAR(160) NOT NULL,
    email VARCHAR(320) NOT NULL,
    address TEXT NOT NULL,
    visit_purpose VARCHAR(80) NOT NULL,
    visit_details TEXT,
    arrival_at TIMESTAMPTZ NOT NULL,
    planned_departure_at TIMESTAMPTZ NOT NULL,
    signature_data TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(20) NOT NULL DEFAULT 'registered',
    CONSTRAINT visitor_email_format CHECK (position('@' IN email) > 1),
    CONSTRAINT visitor_departure_after_arrival CHECK (planned_departure_at >= arrival_at),
    CONSTRAINT visitor_status_allowed CHECK (status IN ('registered', 'checked_in', 'checked_out', 'cancelled'))
);

CREATE TABLE IF NOT EXISTS ppe_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name VARCHAR(160) NOT NULL,
    company_name VARCHAR(200) NOT NULL,
    email VARCHAR(320) NOT NULL,
    pickup_date DATE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    CONSTRAINT ppe_email_format CHECK (position('@' IN email) > 1),
    CONSTRAINT ppe_status_allowed CHECK (status IN ('pending', 'prepared', 'collected', 'cancelled'))
);

CREATE TABLE IF NOT EXISTS ppe_request_items (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id UUID NOT NULL REFERENCES ppe_requests(id) ON DELETE CASCADE,
    item_code VARCHAR(40) NOT NULL,
    item_label VARCHAR(120) NOT NULL,
    size VARCHAR(10),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ppe_item_code_allowed CHECK (
        item_code IN ('helmet', 'shoes', 'vest', 'glasses', 'hearing_protection', 'dust_mask')
    ),
    CONSTRAINT ppe_size_required_for_sized_items CHECK (
        (item_code IN ('shoes', 'vest') AND size IS NOT NULL)
        OR (item_code NOT IN ('shoes', 'vest') AND size IS NULL)
    ),
    CONSTRAINT ppe_one_item_per_request CHECK (item_code <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS ppe_request_one_item_per_type
    ON ppe_request_items (request_id, item_code);

CREATE INDEX IF NOT EXISTS visitor_registrations_arrival_idx
    ON visitor_registrations (arrival_at);

CREATE INDEX IF NOT EXISTS visitor_registrations_email_idx
    ON visitor_registrations (email);

CREATE INDEX IF NOT EXISTS ppe_requests_pickup_date_idx
    ON ppe_requests (pickup_date);

CREATE INDEX IF NOT EXISTS ppe_requests_status_idx
    ON ppe_requests (status);

-- Secure public submission for the PPE form.
-- Run this section in Supabase SQL Editor after the tables exist.
DROP POLICY IF EXISTS "Public can register visitors" ON public.visitor_registrations;
DROP POLICY IF EXISTS "Public can submit PPE items" ON public.ppe_request_items;
DROP POLICY IF EXISTS "Public can submit PPE requests" ON public.ppe_requests;

REVOKE INSERT, SELECT, UPDATE, DELETE ON public.visitor_registrations FROM anon;
REVOKE INSERT, SELECT, UPDATE, DELETE ON public.ppe_request_items FROM anon;
REVOKE INSERT, SELECT, UPDATE, DELETE ON public.ppe_requests FROM anon;

CREATE OR REPLACE FUNCTION public.submit_visitor_registration(
    p_full_name VARCHAR,
    p_email VARCHAR,
    p_address TEXT,
    p_visit_purpose VARCHAR,
    p_visit_details TEXT,
    p_arrival_at TIMESTAMPTZ,
    p_planned_departure_at TIMESTAMPTZ,
    p_signature_data TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    registration_id UUID;
BEGIN
    INSERT INTO public.visitor_registrations (
        full_name,
        email,
        address,
        visit_purpose,
        visit_details,
        arrival_at,
        planned_departure_at,
        signature_data
    )
    VALUES (
        p_full_name,
        p_email,
        p_address,
        p_visit_purpose,
        p_visit_details,
        p_arrival_at,
        p_planned_departure_at,
        p_signature_data
    )
    RETURNING id INTO registration_id;

    RETURN registration_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_visitor_registration(
    VARCHAR, VARCHAR, TEXT, VARCHAR, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_visitor_registration(
    VARCHAR, VARCHAR, TEXT, VARCHAR, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT
) TO anon;

CREATE OR REPLACE FUNCTION public.submit_ppe_request(
    p_full_name VARCHAR,
    p_company_name VARCHAR,
    p_email VARCHAR,
    p_pickup_date DATE,
    p_items JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    request_id UUID;
BEGIN
    IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'At least one PPE item is required';
    END IF;

    INSERT INTO public.ppe_requests (full_name, company_name, email, pickup_date)
    VALUES (p_full_name, p_company_name, p_email, p_pickup_date)
    RETURNING id INTO request_id;

    INSERT INTO public.ppe_request_items (request_id, item_code, item_label, size)
    SELECT request_id, item_code, item_label, size
    FROM jsonb_to_recordset(p_items) AS item(
        item_code VARCHAR(40),
        item_label VARCHAR(120),
        size VARCHAR(10)
    );

    RETURN request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_ppe_request(VARCHAR, VARCHAR, VARCHAR, DATE, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_ppe_request(VARCHAR, VARCHAR, VARCHAR, DATE, JSONB) TO anon;
