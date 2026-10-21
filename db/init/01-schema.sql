-- Issues, labels and comments, adapted from skis to Postgres.
-- The *_doc views build each GitHub-shaped JSON document, so the
-- APL workers only ever hand a finished document back to the client.

CREATE TABLE issues (
    number       serial PRIMARY KEY,
    title        text NOT NULL CHECK (title <> ''),
    body         text,
    state        text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'closed')),
    state_reason text CHECK (state_reason IN ('completed', 'not_planned', 'duplicate', 'reopened')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    closed_at    timestamptz,
    CHECK ((state = 'open') = (closed_at IS NULL))
);

CREATE TABLE labels (
    id          serial PRIMARY KEY,
    name        text NOT NULL CHECK (name <> ''),
    description text,
    color       text NOT NULL DEFAULT 'ededed'
);
CREATE UNIQUE INDEX labels_name_ci ON labels (lower(name));

CREATE TABLE issue_labels (
    issue_number int NOT NULL REFERENCES issues ON DELETE CASCADE,
    label_id     int NOT NULL REFERENCES labels ON DELETE CASCADE,
    PRIMARY KEY (issue_number, label_id)
);

CREATE TABLE comments (
    id           serial PRIMARY KEY,
    issue_number int NOT NULL REFERENCES issues ON DELETE CASCADE,
    body         text NOT NULL CHECK (body <> ''),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX comments_issue ON comments (issue_number);

CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;
CREATE TRIGGER issues_touch   BEFORE UPDATE ON issues   FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER comments_touch BEFORE UPDATE ON comments FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- GitHub's rules for closing and reopening, kept by the database:
-- closing sets closed_at and defaults the reason to 'completed';
-- reopening clears closed_at and sets the reason to 'reopened'.
CREATE FUNCTION issue_state_rules() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.state = 'closed' AND OLD.state = 'open' THEN
        NEW.closed_at := now();
        IF NEW.state_reason IS NULL OR NEW.state_reason = 'reopened' THEN
            NEW.state_reason := 'completed';
        END IF;
    ELSIF NEW.state = 'open' AND OLD.state = 'closed' THEN
        NEW.closed_at := NULL;
        NEW.state_reason := 'reopened';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER issues_state BEFORE UPDATE ON issues FOR EACH ROW EXECUTE FUNCTION issue_state_rules();

-- Attach labels (a JSON array of names) to an issue, optionally replacing
-- the current set. If any name is unknown nothing changes, and the result
-- is the number of unknown names. Call with n NULL just to check names.
CREATE FUNCTION set_issue_labels(n int, names json, replace boolean) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE unknown int;
BEGIN
    SELECT count(*) INTO unknown FROM json_array_elements_text(names) x
     WHERE NOT EXISTS (SELECT 1 FROM labels WHERE lower(name) = lower(x));
    IF unknown > 0 OR n IS NULL THEN RETURN unknown; END IF;
    IF replace THEN DELETE FROM issue_labels WHERE issue_number = n; END IF;
    INSERT INTO issue_labels (issue_number, label_id)
        SELECT n, id FROM labels
         WHERE lower(name) IN (SELECT lower(x) FROM json_array_elements_text(names) x)
        ON CONFLICT DO NOTHING;
    RETURN 0;
END $$;

-- GitHub's timestamp format: 2026-10-20T14:03:12Z
CREATE FUNCTION iso(t timestamptz) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

CREATE VIEW label_doc AS
SELECT id, name,
       json_build_object(
           'id', id, 'name', name, 'description', description, 'color', color
       ) AS doc
FROM labels;

CREATE VIEW issue_doc AS
SELECT i.number, i.state, i.created_at,
       json_build_object(
           'number',       i.number,
           'title',        i.title,
           'body',         i.body,
           'state',        i.state,
           'state_reason', i.state_reason,
           'labels',       coalesce((SELECT json_agg(l.doc ORDER BY lower(l.name))
                                     FROM issue_labels il JOIN label_doc l ON l.id = il.label_id
                                     WHERE il.issue_number = i.number), '[]'::json),
           'comments',     (SELECT count(*) FROM comments c WHERE c.issue_number = i.number),
           'created_at',   iso(i.created_at),
           'updated_at',   iso(i.updated_at),
           'closed_at',    iso(i.closed_at)
       ) AS doc,
       i.updated_at
FROM issues i;

CREATE VIEW comment_doc AS
SELECT id, issue_number,
       json_build_object(
           'id', id, 'body', body,
           'created_at', iso(created_at), 'updated_at', iso(updated_at)
       ) AS doc
FROM comments;

-- One page of labels, sorted by name.
CREATE FUNCTION list_labels(lim int, off int) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT coalesce(json_agg(doc ORDER BY lower(name) COLLATE "C"), '[]')
    FROM (SELECT doc, name FROM label_doc
          ORDER BY lower(name) COLLATE "C" LIMIT lim OFFSET off) page
$$;

-- One page of issues, newest first. want_state is 'open', 'closed' or 'all';
-- want_labels is a comma-separated list of names that must all be present;
-- want_sort is 'updated' (most recently changed first) or anything else for 'created'.
CREATE FUNCTION list_issues(want_state text, want_labels text, want_sort text, lim int, off int) RETURNS json
LANGUAGE sql STABLE AS $$
    SELECT coalesce(json_agg(doc ORDER BY sort_key DESC, number DESC), '[]')
    FROM (SELECT doc, number,
                 CASE WHEN want_sort = 'updated' THEN updated_at ELSE created_at END AS sort_key
          FROM issue_doc d
          WHERE want_state IN ('all', d.state)
            AND NOT EXISTS (
                SELECT 1 FROM unnest(string_to_array(NULLIF(want_labels, ''), ',')) wanted
                WHERE NOT EXISTS (SELECT 1 FROM issue_labels il JOIN labels l ON l.id = il.label_id
                                  WHERE il.issue_number = d.number AND lower(l.name) = lower(wanted)))
          ORDER BY sort_key DESC, number DESC LIMIT lim OFFSET off) page
$$;

-- Change the given fields of an issue; '' means "leave as it is".
-- Returns 1 if the issue exists, 0 if not.
CREATE FUNCTION update_issue(n int, new_title text, new_body text, new_state text, new_reason text) RETURNS int
LANGUAGE sql AS $$
    WITH u AS (
        UPDATE issues SET title        = coalesce(NULLIF(new_title, ''), title),
                          body         = coalesce(NULLIF(new_body, ''), body),
                          state        = coalesce(NULLIF(new_state, ''), state),
                          state_reason = coalesce(NULLIF(new_reason, ''), state_reason)
        WHERE number = n RETURNING 1)
    SELECT CAST(count(*) AS int) FROM u
$$;

-- One page of an issue's comments, oldest first.
CREATE FUNCTION list_comments(n int, lim int, off int) RETURNS json LANGUAGE sql STABLE AS $$
    SELECT coalesce(json_agg(doc ORDER BY id), '[]')
    FROM (SELECT doc, id FROM comment_doc WHERE issue_number = n
          ORDER BY id LIMIT lim OFFSET off) page
$$;
