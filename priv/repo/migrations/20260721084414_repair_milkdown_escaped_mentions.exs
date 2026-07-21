defmodule Vutuv.Repo.Migrations.RepairMilkdownEscapedMentions do
  use Ecto.Migration

  # One-off cleanup for the mention corruption the Milkdown WYSIWYG editor
  # (shipped v7.72.0) wrote into post bodies. Milkdown serializes `@ulrich_wolf`
  # as `@ulrich\_wolf` (remark escapes the `_`, a Markdown emphasis char), and a
  # `#foo_bar` hashtag likewise. Earmark undoes that escape before the renderer
  # links the mention, so the post renders correctly — but Vutuv.Mentions reads
  # the raw Markdown source (mention-existence validation, availability, rename),
  # where the stray backslash truncates `@ulrich\_wolf` to `@ulrich`. That is
  # what made re-posting/editing such a body fail with "the handle @ulrich does
  # not exist". The editor now stores the bare handle (assets/js/markdown_editor.js
  # `canonicalizeMentions`) and Vutuv.Mentions sees through the escape; this
  # rewrites the rows already stored so the source is bare everywhere.
  #
  # Data-only, idempotent, and N-1 safe: a bare handle renders identically on the
  # currently deployed release too. Raw SQL keeps `updated_at` untouched, so a
  # silent repair never marks a post "edited" or reorders a feed.

  def up do
    repair("posts")
    repair("messages")
  end

  # Not reversible: we deliberately do not re-introduce the corruption.
  def down, do: :ok

  defp repair(table) do
    %{rows: rows} = repo().query!("SELECT id::text, body FROM #{table}", [])

    for [id, body] <- rows, is_binary(body), (fixed = canonicalize(body)) != body do
      repo().query!("UPDATE #{table} SET body = $1 WHERE id::text = $2", [fixed, id])
    end
  end

  # Mirror of the editor's `canonicalizeMentions`: inside a `@handle`/`#hashtag`
  # only, drop a backslash escaping an underscore. Scoped to the mention run, so
  # an intended-literal `foo\_bar` in free prose keeps its escape and never turns
  # into emphasis.
  defp canonicalize(body) do
    Regex.replace(~r{(?<![\w@#/&])([@#])((?:[A-Za-z0-9]|\\_)+)}, body, fn
      whole, sigil, handle ->
        if String.contains?(handle, "\\_"),
          do: sigil <> String.replace(handle, "\\_", "_"),
          else: whole
    end)
  end
end
