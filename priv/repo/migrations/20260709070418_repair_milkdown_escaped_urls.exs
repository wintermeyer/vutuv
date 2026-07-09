defmodule Vutuv.Repo.Migrations.RepairMilkdownEscapedUrls do
  use Ecto.Migration

  # One-off cleanup for the URL corruption the Milkdown WYSIWYG editor (shipped
  # v7.72.0) wrote into post and message bodies. Milkdown serializes a URL in the
  # two forms remark produces, neither of which vutuv stores:
  #
  #   * a recognized link whose text is the URL as an autolink `<https://ex.com>`
  #     — and vutuv escapes `<` at render time, so `<…>` never becomes a link; and
  #   * a bare URL sitting in plain text as escaped literal text
  #     `https\://ex\.com/a\&b` (mdast-util-gfm-autolink-literal's "unsafe" rules),
  #     so it will not re-parse as an autolink.
  #
  # vutuv stores plain Markdown with bare, unescaped URLs and autolinks them at
  # render time. The leftover backslashes broke Earmark's link parser (a stray
  # ")", issue #918) and the `<…>` form showed literal angle brackets. The editor
  # now emits the canonical bare form (assets/js/markdown_editor.js
  # `canonicalizeUrls`); this rewrites the rows already stored so the renderer
  # needs no repair of its own.
  #
  # Data-only, idempotent, and N-1 safe: a bare URL renders correctly on the
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

    for [id, body] <- rows, (fixed = canonicalize(body)) != body do
      repo().query!("UPDATE #{table} SET body = $1 WHERE id::text = $2", [fixed, id])
    end
  end

  # Mirror of the editor's `canonicalizeUrls`: strip autolink brackets, then drop
  # every backslash inside a `scheme://…` run (a real URL never contains one, so
  # each `\` is a Markdown escape we undo). Leaves non-URL escapes — a prose
  # `oliver\_lietz`, an `example\[dot]com`, a `\`-newline hard break — untouched.
  defp canonicalize(body) do
    body
    |> then(&Regex.replace(~r{<(https?://[^>\s]+)>}i, &1, fn _, url -> url end))
    |> then(
      &Regex.replace(~r{[a-z][a-z0-9+.-]*\\?://[^\s<>]*}i, &1, fn token ->
        Regex.replace(~r{\\(.)}, token, "\\1")
      end)
    )
  end
end
