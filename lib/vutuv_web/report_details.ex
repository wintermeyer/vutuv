defmodule VutuvWeb.ReportDetails do
  @moduledoc """
  Turns a `Vutuv.Reports.DailyReport`'s per-metric `details` sample into ordered,
  ready-to-render sections for the operator's daily report. The nightly email
  (HTML + text) and the admin reports page all render from `sections/1`, so the
  detail lines stay identical across the three surfaces.

  Each section is `%{key, label, count, more, entries}`:

    * `key`     — the metric atom (`:registrations`, `:posts`, …).
    * `label`   — the German section heading (the report email is German-only;
                  the admin page localizes its own heading from `key` instead).
    * `count`   — the true total for the day (the sample is capped, see
                  `Vutuv.Reports.DailyReport.detail_limit/0`).
    * `more`    — `count` minus the shown entries, `0` when nothing was dropped.
    * `entries` — normalized `%{primary, secondary, path}` lines: `primary` the
                  link / main text (never blank), `secondary` a muted suffix
                  (`@handle`, a bounce status, …) or `nil`, and `path` the
                  internal profile / post path to link `primary` to, or `nil`.

  Only metrics with at least one sampled entry get a section; a quiet day yields
  `[]`. This module builds *data* (locale-neutral apart from the German
  headings): it renders no HTML, so the email and the admin page each apply
  their own markup and link style (relative for the page, absolute for the mail).
  """

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias VutuvWeb.AgentDocs

  # Section order + German headings for the email; the admin page keys its own
  # gettext heading off `:key` and ignores `label`.
  @order [
    {:registrations, "Neue bestätigte Registrierungen (per PIN)"},
    {:posts, "Neue Beiträge"},
    {:reposts, "Reposts"},
    {:likes, "Likes"},
    {:bookmarks, "Lesezeichen"},
    {:fediverse_followers, "Neue Fediverse-Follower"},
    {:bounces, "Bounces"},
    {:deactivations, "Deaktivierte Adressen"},
    {:freezes, "Eingefrorene Konten"},
    {:thaws, "Aufgetaute Konten"},
    {:spam_removals, "Als Spam entfernte Konten"}
  ]

  @doc """
  The detail sections as a plain-text block for the text/plain mail part, each
  entry's internal `path` resolved against `url` (the absolute base, trailing
  slash). Returns `""` for a quiet day, so the caller can drop it cleanly. The
  URL rides on its own indented line (no dash, per the project copy rules).
  """
  def text_block(report, url) do
    case sections(report) do
      [] -> ""
      sections -> "Details\n=======\n\n" <> Enum.map_join(sections, "\n", &text_section(&1, url))
    end
  end

  defp text_section(section, url) do
    header = "#{section.label}: #{section.count}"
    lines = Enum.map(section.entries, &text_entry(&1, url))
    more = if section.more > 0, do: ["  … und #{section.more} weitere"], else: []
    Enum.join([header | lines] ++ more, "\n") <> "\n"
  end

  defp text_entry(entry, url) do
    head = "  - " <> entry.primary <> if(entry.secondary, do: " (#{entry.secondary})", else: "")

    case entry.path do
      nil -> head
      path -> head <> "\n    " <> url <> String.trim_leading(path, "/")
    end
  end

  @doc "The report's non-empty detail sections, in display order."
  def sections(report) do
    for {key, label} <- @order,
        entries = Enum.map(Map.get(report.details, key, []), &entry(key, &1)),
        entries != [] do
      count = Map.fetch!(report, key)

      %{
        key: key,
        label: label,
        count: count,
        more: max(count - length(entries), 0),
        entries: entries
      }
    end
  end

  defp entry(:registrations, user), do: person_entry(user)
  defp entry(:spam_removals, event), do: person_entry(event.case.owner)

  defp entry(:posts, post), do: post_entry(post, post.user)
  defp entry(:reposts, repost), do: post_entry(repost.post, repost.user)
  defp entry(:likes, like), do: post_entry(like.post, like.user)
  defp entry(:bookmarks, bookmark), do: post_entry(bookmark.post, bookmark.user)

  defp entry(:fediverse_followers, follower) do
    %{
      primary: follower_display(follower),
      secondary: "@" <> follower.user.username,
      path: "/" <> follower.user.username
    }
  end

  defp entry(:bounces, %{email: email, status: status}),
    do: %{primary: email, secondary: status, path: nil}

  defp entry(:deactivations, %{email: email}),
    do: %{primary: email, secondary: nil, path: nil}

  defp entry(kind, %{email: email, user: user}) when kind in [:freezes, :thaws] do
    if user, do: person_entry(user), else: %{primary: email, secondary: nil, path: nil}
  end

  defp person_entry(user) do
    %{primary: full_name(user), secondary: "@" <> user.username, path: "/" <> user.username}
  end

  # The post's first line links to its permalink; the actor (author / reposter /
  # liker / bookmarker) is the muted suffix. A text-less (photo-only) post has no
  # first line, so the actor's handle becomes the link text instead of a blank
  # line.
  defp post_entry(post, actor) do
    case AgentDocs.excerpt(post.body) do
      "" -> %{primary: "@" <> actor.username, secondary: nil, path: "/posts/" <> post.id}
      line -> %{primary: line, secondary: "@" <> actor.username, path: "/posts/" <> post.id}
    end
  end

  # The remote actor's own label, best first: its @handle, then its display
  # name, falling back to the raw actor URI (always present).
  defp follower_display(%{handle: handle}) when is_binary(handle) and handle != "", do: handle
  defp follower_display(%{name: name}) when is_binary(name) and name != "", do: name
  defp follower_display(%{actor_uri: uri}), do: uri
end
