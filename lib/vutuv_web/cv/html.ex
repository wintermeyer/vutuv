defmodule VutuvWeb.CV.Html do
  @moduledoc """
  The CV as one self-contained, print-ready HTML document: inline styles,
  no external assets, an `@media print` A4 setup — so "PDF" is the browser's
  own print dialog (Save as PDF), with no server-side rendering dependency
  (the issue #841 v1 decision). Served inline as the preview and offered as
  the `.html` download.

  Deliberately a light **document**, not an app page: no shell, no dark
  mode (paper is white), every user value escaped through `esc/1`.
  """

  use Gettext, backend: VutuvWeb.Gettext

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
    <title>#{esc(gettext("CV"))}: #{esc(cv.name)}</title>
    <style>#{css()}</style>
    </head>
    <body>
    #{if Keyword.get(opts, :print_hint, false), do: hint()}
    <div class="sheet">
    #{header(cv)}
    #{Enum.map_join(cv.sections, &section/1)}
    #{skills(cv.skills)}
    #{links(cv.links)}
    </div>
    </body>
    </html>
    """
  end

  defp hint do
    """
    <div class="noprint">#{esc(gettext("This is the print view of this CV. Use your browser's print dialog (Ctrl+P or Cmd+P) and choose \"Save as PDF\" to get a PDF file."))}</div>
    """
  end

  defp header(cv) do
    photo =
      if cv.photo do
        ~s(<img class="photo" src="#{cv.photo}" alt=""/>)
      else
        ""
      end

    contact =
      [cv.email, cv.phone, cv.profile_url]
      |> Enum.filter(& &1)
      |> Enum.map_join(" &middot; ", &esc/1)

    address =
      if cv.address_lines == [] do
        ""
      else
        ~s(<p class="contact">#{Enum.map_join(cv.address_lines, ", ", &esc/1)}</p>)
      end

    """
    <header class="head">
    <div>
    <h1>#{esc(cv.name)}</h1>
    #{if cv.headline, do: ~s(<p class="headline">#{esc(cv.headline)}</p>), else: ""}
    <p class="contact">#{contact}</p>
    #{address}
    </div>
    #{photo}
    </header>
    """
  end

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
      if entry.description, do: ~s(<p class="desc">#{esc(entry.description)}</p>), else: ""

    """
    <article class="entry">
    <div class="entry-head"><span class="role"><strong>#{role}</strong></span>#{period}</div>
    #{description}
    </article>
    """
  end

  defp skills([]), do: ""

  defp skills(skills) do
    """
    <section>
    <h2>#{esc(gettext("Tags"))}</h2>
    <p class="skills">#{Enum.map_join(skills, " &middot; ", &esc/1)}</p>
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
    h2 { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: #64748b;
         border-bottom: 1px solid #e2e8f0; padding-bottom: 4px; margin: 28px 0 12px; }
    .entry { margin: 0 0 14px; break-inside: avoid; }
    .entry-head { display: flex; justify-content: space-between; gap: 16px; }
    .role { font-size: 14px; }
    .period { color: #64748b; font-size: 13px; white-space: nowrap; }
    .desc { margin: 4px 0 0; color: #334155; white-space: pre-line; overflow-wrap: anywhere; }
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
      .links a { color: inherit; text-decoration: none; }
    }
    """
  end

  defp esc(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
