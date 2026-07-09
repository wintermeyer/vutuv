defmodule VutuvWeb.CV.Odt do
  @moduledoc """
  The CV as an OpenDocument text (`.odt`) — the vendor-neutral editable
  alternative to `.docx` (LibreOffice, OpenOffice; Word opens it too).

  Like the Docx renderer this builds the ZIP package by hand with Erlang's
  `:zip`: per the ODF spec the uncompressed `mimetype` file leads the
  archive (only the `.xml` parts are deflated), which is what lets file
  managers sniff the type from the first bytes.

  The entry description is Markdown (issue #905), rendered through the
  shared `VutuvWeb.CV.MarkdownBlocks` floor like the Docx (issue #920):
  one paragraph per block, list items as "•"/"1."-prefixed paragraphs,
  inline markers stripped to their text.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.CV.MarkdownBlocks

  @mimetype "application/vnd.oasis.opendocument.text"

  def render(cv) do
    files = [
      {~c"mimetype", @mimetype},
      {~c"META-INF/manifest.xml", manifest()},
      {~c"styles.xml", styles()},
      {~c"content.xml", content(cv)}
    ]

    {:ok, {_name, binary}} =
      :zip.create(~c"cv.odt", files, [:memory, {:compress, [~c".xml"]}])

    binary
  end

  defp manifest do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
    <manifest:file-entry manifest:full-path="/" manifest:media-type="#{@mimetype}"/>
    <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
    <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
    </manifest:manifest>
    """
  end

  defp styles do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" office:version="1.2">
    <office:styles/>
    </office:document-styles>
    """
  end

  defp content(cv) do
    body =
      [
        cv.name && p(cv.name, "CVTitle"),
        cv.headline && p(cv.headline, "CVHeadline"),
        contact(cv),
        address(cv),
        details(cv),
        Enum.map(cv.sections, &section/1),
        skills(cv.skills),
        qualifications(cv.qualifications),
        languages(cv.languages),
        links(cv.links),
        social_media(cv.social_media)
      ]
      |> List.flatten()
      |> Enum.filter(& &1)
      |> Enum.join()

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.2">
    <office:automatic-styles>
    <style:style style:name="CVTitle" style:family="paragraph"><style:text-properties fo:font-size="22pt" fo:font-weight="bold"/></style:style>
    <style:style style:name="CVHeadline" style:family="paragraph"><style:text-properties fo:font-size="12pt" fo:color="#334155"/></style:style>
    <style:style style:name="CVHeading" style:family="paragraph"><style:paragraph-properties fo:margin-top="6mm" fo:margin-bottom="2mm"/><style:text-properties fo:font-size="10pt" fo:font-weight="bold" fo:color="#475569"/></style:style>
    <style:style style:name="CVMuted" style:family="paragraph"><style:text-properties fo:font-size="10pt" fo:color="#64748b"/></style:style>
    <style:style style:name="CVBold" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
    </office:automatic-styles>
    <office:body>
    <office:text>
    #{body}
    </office:text>
    </office:body>
    </office:document-content>
    """
  end

  defp contact(cv) do
    line =
      [cv.email, cv.phone, cv.profile_url]
      |> Enum.filter(& &1)
      |> Enum.join(" | ")

    if line != "", do: p(line, "CVMuted")
  end

  defp address(%{address_lines: []}), do: nil
  defp address(cv), do: p(Enum.join(cv.address_lines, ", "), "CVMuted")

  defp details(cv) do
    line =
      [detail(gettext("Date of birth"), cv.birthdate), detail(gettext("Gender"), cv.gender)]
      |> Enum.filter(& &1)
      |> Enum.join(" | ")

    if line != "", do: p(line, "CVMuted")
  end

  defp detail(_label, nil), do: nil
  defp detail(label, value), do: "#{label}: #{value}"

  defp section(%{heading: heading, entries: entries}) do
    [heading(heading) | Enum.map(entries, &entry/1)]
  end

  defp entry(entry) do
    role =
      [entry.title, entry.organization]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    role_p = ~s(<text:p><text:span text:style-name="CVBold">#{esc(role)}</text:span></text:p>)

    [
      role_p,
      entry.period && p(entry.period, "CVMuted"),
      entry.description && description_paragraphs(entry.description)
    ]
  end

  defp description_paragraphs(markdown) do
    markdown
    |> MarkdownBlocks.blocks()
    |> Enum.map(fn
      {:p, text} -> p(text)
      {:ul, items} -> Enum.map(items, &p("• " <> &1))
      {:ol, items} -> items |> Enum.with_index(1) |> Enum.map(&numbered_paragraph/1)
    end)
  end

  defp numbered_paragraph({item, index}), do: p("#{index}. #{item}")

  defp skills([]), do: nil
  defp skills(skills), do: [heading(gettext("Tags")), p(Enum.map_join(skills, " | ", & &1.name))]

  defp qualifications([]), do: nil

  defp qualifications(qualifications) do
    [
      heading(gettext("Certificates & licenses")),
      p(Enum.map_join(qualifications, " | ", & &1.label))
    ]
  end

  defp languages([]), do: nil

  defp languages(languages) do
    [
      heading(gettext("Languages")),
      p(Enum.map_join(languages, " | ", &"#{&1.name} (#{&1.fluency})"))
    ]
  end

  defp links([]), do: nil

  defp links(links) do
    lines =
      for link <- links do
        p(if(link.label, do: "#{link.label}: #{link.url}", else: link.url))
      end

    [heading(gettext("Links")) | lines]
  end

  defp social_media([]), do: nil

  defp social_media(accounts) do
    lines =
      for account <- accounts, do: p("#{account.provider}: #{account.url || account.handle}")

    [heading(gettext("Social Media")) | lines]
  end

  defp heading(text) do
    ~s(<text:h text:style-name="CVHeading" text:outline-level="1">#{esc(text)}</text:h>)
  end

  defp p(text, style \\ nil) do
    body =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map_join("<text:line-break/>", &esc/1)

    style_attr = if style, do: ~s( text:style-name="#{style}"), else: ""
    "<text:p#{style_attr}>#{body}</text:p>"
  end

  # The canonical XML text escape (also escapes " and ', harmless in element
  # text) — the one definition shared with the sitemap/feed/docx renderers.
  defp esc(text), do: VutuvWeb.Xml.escape(text)
end
