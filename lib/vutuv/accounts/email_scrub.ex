defmodule Vutuv.Accounts.EmailScrub do
  @moduledoc """
  One-shot repair of legacy email addresses that contain whitespace.

  The pre-v6 import left ~950 `emails.value` rows with whitespace in them
  (trailing spaces, `gmail. com`, plain garbage). The changeset has always
  rejected such values, so nothing new can enter; this scrub repairs the two
  unambiguous cases in the stock:

    * **edge whitespace** is trimmed (`"x@gmail.com "` is a real mailbox);
    * **whitespace in the domain part** is removed - a domain can never
      contain a space, so `gmail. com` can only mean `gmail.com`.

  Whitespace in the local part is left alone (the intent is unknowable), as is
  anything still invalid after the repair. A repair is skipped when its result
  already exists as another address (the unique index on `value`), or when two
  dirty rows would repair to the same value (the oldest row wins). `md5sum`
  stays in sync (`Email.fill_md5sum/1` hashes the stored value).

  Idempotent; run once by the `ScrubEmailWhitespace` data migration.
  """

  alias Vutuv.Repo

  @valid ~S"^[^\s@]+@[^\s@]+\.[^\s@]+$"

  @sql ~S"""
  WITH dirty AS (
    SELECT id, regexp_replace(value, '^\s+|\s+$', '', 'g') AS trimmed
    FROM emails
    WHERE value ~ '\s'
  ),
  candidates AS (
    SELECT id,
      CASE
        WHEN trimmed ~ $1 THEN trimmed
        WHEN trimmed ~ '^[^@]+@[^@]+$'
             AND split_part(trimmed, '@', 1) !~ '\s'
             AND regexp_replace(trimmed, '\s', '', 'g') ~ $1
          THEN regexp_replace(trimmed, '\s', '', 'g')
      END AS new_value
    FROM dirty
  ),
  fixable AS (
    SELECT c.id, c.new_value
    FROM candidates c
    WHERE c.new_value IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM emails e2 WHERE e2.value = c.new_value)
      AND c.id = (SELECT c2.id FROM candidates c2
                  WHERE c2.new_value = c.new_value
                  ORDER BY c2.id
                  LIMIT 1)
  )
  UPDATE emails e
  SET value = f.new_value,
      md5sum = md5(f.new_value),
      updated_at = date_trunc('second', now() AT TIME ZONE 'utc')
  FROM fixable f
  WHERE e.id = f.id
  """

  @doc "Repairs every fixable whitespace address; returns how many rows changed."
  def scrub_whitespace do
    %{num_rows: fixed} = Repo.query!(@sql, [@valid])
    fixed
  end
end
