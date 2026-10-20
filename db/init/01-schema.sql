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
       ) AS doc
FROM issues i;

CREATE VIEW comment_doc AS
SELECT id, issue_number,
       json_build_object(
           'id', id, 'body', body,
           'created_at', iso(created_at), 'updated_at', iso(updated_at)
       ) AS doc
FROM comments;
