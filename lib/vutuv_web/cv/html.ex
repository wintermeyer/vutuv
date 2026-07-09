defmodule VutuvWeb.CV.Html do
  @moduledoc """
  The CV as one self-contained, print-ready HTML document: inline styles,
  no external assets, an `@media print` A4 setup — so "PDF" is the browser's
  own print dialog (Save as PDF), with no server-side rendering dependency
  (the issue #841 v1 decision). Served inline as the preview and offered as
  the `.html` download.

  Deliberately a light **document**, not an app page: no shell, no dark
  mode (paper is white), every user value escaped through `esc/1`. The one
  exception is the entry description, which is Markdown (issue #905) and
  renders through the same sanitizing `VutuvWeb.Markdown` pipeline the
  profile uses (issue #920) — its relative `@handle`/`#hashtag` links are
  made absolute so they still work in a downloaded standalone file.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.Endpoint
  alias VutuvWeb.Markdown

  @doc """
  Options:

    * `:print_hint` — prepend the screen-only "print this to get a PDF"
      helper bar (the preview passes it; the download stays clean).
  """
  def render(cv, opts \\ []) do
    """
    <!DOCTYPE html>
    <html lang="#{Gettext.get_locale(VutuvWeb.Gettext)}">
    <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <meta name="robots" content="noindex"/>
    <title>#{esc(title(cv))}</title>
    <style>#{css()}</style>
    </head>
    <body>
    #{if Keyword.get(opts, :print_hint, false), do: hint()}
    <div class="sheet">
    #{header(cv)}
    #{Enum.map_join(cv.sections, &section/1)}
    #{skills(cv.skills)}
    #{qualifications(cv.qualifications)}
    #{languages(cv.languages)}
    #{links(cv.links)}
    #{social_media(cv.social_media)}
    </div>
    </body>
    </html>
    """
  end

  # The document title carries the name unless it has been hidden
  # (anonymized), then just "CV".
  defp title(%{name: nil}), do: gettext("CV")
  defp title(%{name: name}), do: "#{gettext("CV")}: #{name}"

  defp hint do
    """
    <div class="noprint">#{esc(gettext("This is the print view of this CV. Use your browser's print dialog (Ctrl+P or Cmd+P) and choose \"Save as PDF\" to get a PDF file."))}</div>
    """
  end

  defp header(cv) do
    photo = if cv.photo, do: ~s(<img class="photo" src="#{cv.photo}" alt=""/>), else: ""
    name = if cv.name, do: ~s(<h1>#{esc(cv.name)}</h1>), else: ""
    headline = if cv.headline, do: ~s(<p class="headline">#{esc(cv.headline)}</p>), else: ""

    # The profile link is a real clickable link (opens the vutuv profile);
    # the email/phone stay plain text.
    contact =
      contact_paragraph([
        cv.email && esc(cv.email),
        cv.phone && esc(cv.phone),
        cv.profile_url && ~s(<a href="#{esc(cv.profile_url)}">#{esc(cv.profile_url)}</a>)
      ])

    address = contact_paragraph(Enum.map(cv.address_lines, &esc/1), ", ")

    details =
      contact_paragraph([
        detail(gettext("Date of birth"), cv.birthdate),
        detail(gettext("Gender"), cv.gender)
      ])

    """
    <header class="head">
    <div>
    #{name}
    #{headline}
    #{contact}
    #{address}
    #{details}
    </div>
    #{photo}
    </header>
    """
  end

  # A `.contact` paragraph joining the present items (already-escaped HTML
  # fragments, or nil/false to drop) with `sep`, or "" when none are present.
  defp contact_paragraph(items, sep \\ " &middot; ") do
    case Enum.filter(items, & &1) do
      [] -> ""
      present -> ~s(<p class="contact">#{Enum.join(present, sep)}</p>)
    end
  end

  defp detail(_label, nil), do: nil
  defp detail(label, value), do: esc("#{label}: #{value}")

  defp section(%{heading: heading, entries: entries}) do
    """
    <section>
    <h2>#{esc(heading)}</h2>
    #{Enum.map_join(entries, &entry/1)}
    </section>
    """
  end

  defp entry(entry) do
    role =
      [entry.title, entry.organization]
      |> Enum.filter(& &1)
      |> Enum.map_join(", ", &esc/1)

    period = if entry.period, do: ~s(<span class="period">#{esc(entry.period)}</span>), else: ""

    description =
      if entry.description,
        do: ~s(<div class="desc">#{description_html(entry.description)}</div>),
        else: ""

    """
    <article class="entry">
    <div class="entry-head"><span class="role"><strong>#{role}</strong></span>#{period}</div>
    #{description}
    </article>
    """
  end

  # The description Markdown through the profile's sanitizing pipeline
  # (escaped raw HTML, stripped images, safe links). Its @handle/#hashtag
  # links come out relative; a downloaded file has no host to resolve them
  # against, so they are absolutized against this installation's URL.
  defp description_html(markdown) do
    markdown
    |> Markdown.render()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~s(href="/), ~s(href="#{Endpoint.url()}/))
  end

  defp skills([]), do: ""

  defp skills(skills) do
    """
    <section>
    <h2>#{esc(gettext("Tags"))}</h2>
    <p class="skills">#{Enum.map_join(skills, " &middot; ", fn skill -> esc(skill.name) end)}</p>
    </section>
    """
  end

  defp qualifications([]), do: ""

  defp qualifications(qualifications) do
    items = Enum.map_join(qualifications, " &middot; ", &esc(&1.label))

    """
    <section>
    <h2>#{esc(gettext("Certificates & licenses"))}</h2>
    <p class="skills">#{items}</p>
    </section>
    """
  end

  defp languages([]), do: ""

  defp languages(languages) do
    items =
      Enum.map_join(languages, " &middot; ", fn language ->
        esc("#{language.name} (#{language.fluency})")
      end)

    """
    <section>
    <h2>#{esc(gettext("Languages"))}</h2>
    <p class="skills">#{items}</p>
    </section>
    """
  end

  defp links([]), do: ""

  defp links(links) do
    items =
      Enum.map_join(links, fn link ->
        label = if link.label, do: "#{esc(link.label)}: ", else: ""
        ~s(<li>#{label}<a href="#{esc(link.url)}">#{esc(link.url)}</a></li>)
      end)

    """
    <section>
    <h2>#{esc(gettext("Links"))}</h2>
    <ul class="links">#{items}</ul>
    </section>
    """
  end

  defp social_media([]), do: ""

  defp social_media(accounts) do
    items =
      Enum.map_join(accounts, fn account ->
        target =
          if account.url,
            do: ~s(<a href="#{esc(account.url)}">#{esc(account.url)}</a>),
            else: esc(account.handle)

        ~s(<li>#{esc(account.provider)}: #{target}</li>)
      end)

    """
    <section>
    <h2>#{esc(gettext("Social Media"))}</h2>
    <ul class="links">#{items}</ul>
    </section>
    """
  end

  # Paper stays light on purpose (this is a document, not an app surface).
  defp css do
    """
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #f1f5f9; color: #0f172a;
           font: 14px/1.5 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; }
    .sheet { max-width: 760px; margin: 0 auto; padding: 48px 40px; background: #fff; min-height: 100vh; }
    .head { display: flex; justify-content: space-between; gap: 24px; align-items: flex-start; }
    .photo { width: 104px; height: 104px; object-fit: cover; border-radius: 8px; flex: none; }
    h1 { font-size: 28px; margin: 0; line-height: 1.2; }
    .headline { margin: 4px 0 0; font-size: 15px; color: #334155; }
    .contact { margin: 8px 0 0; font-size: 13px; color: #334155; overflow-wrap: anywhere; }
    .contact a { color: #1d4ed8; }
    h2 { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: #64748b;
         border-bottom: 1px solid #e2e8f0; padding-bottom: 4px; margin: 28px 0 12px; }
    .entry { margin: 0 0 14px; break-inside: avoid; }
    .entry-head { display: flex; justify-content: space-between; gap: 16px; }
    .role { font-size: 14px; }
    .period { color: #64748b; font-size: 13px; white-space: nowrap; }
    .desc { margin: 4px 0 0; color: #334155; overflow-wrap: anywhere; }
    .desc p, .desc ul, .desc ol, .desc blockquote, .desc pre { margin: 6px 0 0; }
    .desc > :first-child { margin-top: 0; }
    .desc ul, .desc ol { padding-left: 20px; }
    .desc li { margin: 0 0 2px; }
    .desc a { color: #1d4ed8; }
    .desc h1, .desc h2, .desc h3, .desc h4, .desc h5, .desc h6 {
      font-size: inherit; color: inherit; letter-spacing: normal; text-transform: none;
      border: 0; padding: 0; margin: 6px 0 0; font-weight: 600; }
    .desc code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
                 font-size: 12px; background: #f1f5f9; padding: 1px 4px; border-radius: 4px; }
    .desc pre { background: #f1f5f9; padding: 8px 10px; border-radius: 6px; overflow-x: auto; }
    .desc pre code { background: none; padding: 0; }
    .desc blockquote { border-left: 3px solid #e2e8f0; padding: 0 0 0 10px; color: #475569; }
    .skills { margin: 0; }
    .links { margin: 0; padding-left: 18px; }
    .links li { margin: 0 0 4px; overflow-wrap: anywhere; }
    .links a { color: #1d4ed8; }
    .noprint { max-width: 760px; margin: 16px auto 0; padding: 10px 16px; border-radius: 8px;
               background: #dbeafe; color: #1e3a8a; font: 13px/1.5 -apple-system, "Segoe UI",
               Helvetica, Arial, sans-serif; }
    @media print {
      @page { size: A4; margin: 18mm; }
      body { background: #fff; }
      .sheet { max-width: none; padding: 0; min-height: 0; }
      .noprint { display: none; }
      .links a, .desc a { color: inherit; text-decoration: none; }
    }
    """
  end

  defp esc(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
