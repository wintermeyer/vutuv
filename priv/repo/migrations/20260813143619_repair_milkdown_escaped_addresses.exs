defmodule Vutuv.Repo.Migrations.RepairMilkdownEscapedAddresses do
  use Ecto.Migration

  # One-off cleanup for the `user@host` corruption the Milkdown WYSIWYG editor
  # wrote into every Markdown body it touched — the third of its kind, after
  # RepairMilkdownEscapedUrls and RepairMilkdownEscapedMentions, and from the
  # same root: GFM's autolink-literal extension parses `user@host.tld` into a
  # link node with a `mailto:` url, and remark then serializes that node in one
  # of two shapes, neither of which vutuv stores:
  #
  #   * after a re-parse (a draft restore, a post edit, any re-seed) as an
  #     autolink `<php@tags.vutuv.de>` — and vutuv escapes `<` at render time
  #     (typed HTML must show as text), so the member's sentence read
  #     `@<php@tags.vutuv.de>` on the page; and
  #   * freshly typed, as escaped literal text `php\@tags.vutuv.de`
  #     (mdast-util-gfm-autolink-literal's "unsafe" rules), a visible backslash.
  #
  # It hit both a plain email address and — the reason it was reported — every
  # **fediverse handle**, which is the same shape. The second form is worse than
  # it looks there: `Vutuv.Mentions` reads the raw source, where the backslash
  # splits one handle into the two local handles `@php` and `@tags`, so the
  # mention-existence check refuses to save the body at all.
  #
  # The editor now stores the bare form (assets/js/markdown_editor.js
  # `canonicalizeAddresses`); this rewrites the rows already stored, over the
  # four surfaces that composer serves.
  #
  # Data-only, idempotent, and N-1 safe: a bare address renders at least as well
  # on the currently deployed release (it is what a member typing in source mode
  # has always stored). Raw SQL keeps `updated_at` untouched, so a silent repair
  # never marks a post "edited" or reorders a feed.

  def up do
    repair("posts", "body")
    repair("messages", "body")
    repair("organizations", "description")
    repair("job_postings", "description")
  end

  # Not reversible: we deliberately do not re-introduce the corruption.
  def down, do: :ok

  defp repair(table, column) do
    %{rows: rows} = repo().query!("SELECT id::text, #{column} FROM #{table}", [])

    for [id, body] <- rows, is_binary(body), (fixed = canonicalize(body)) != body do
      repo().query!("UPDATE #{table} SET #{column} = $1 WHERE id::text = $2", [fixed, id])
    end
  end

  # Fenced code blocks are left byte-for-byte alone: an address inside one is a
  # sample (a config line, a mail header), not something the renderer would ever
  # have linked, so there is nothing there to repair and plenty to break. The
  # split keeps the captures, so the parts rejoin to the exact original.
  @code ~r/(```[\s\S]*?```|~~~[\s\S]*?~~~)/

  defp canonicalize(body) do
    @code
    |> Regex.split(body, include_captures: true)
    |> Enum.with_index()
    |> Enum.map_join("", fn
      {chunk, index} when rem(index, 2) == 0 -> canonicalize_chunk(chunk)
      {fenced, _index} -> fenced
    end)
  end

  # Mirror of the editor's `canonicalizeAddresses`: drop the autolink brackets,
  # then drop the backslash escaping the `@`. Both are scoped to an
  # address-shaped run, so a `<tag>` in prose and a lone `\@` keep their
  # characters.
  defp canonicalize_chunk(chunk) do
    chunk
    |> then(
      &Regex.replace(~r{<([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)>}, &1, fn _, a -> a end)
    )
    |> then(
      &Regex.replace(
        ~r{([A-Za-z0-9._%+-]+)\\@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)},
        &1,
        fn _, local, host -> local <> "@" <> host end
      )
    )
  end
end
