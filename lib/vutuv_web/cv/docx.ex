defmodule VutuvWeb.CV.Docx do
  @moduledoc """
  The CV as a Word document (`.docx`) — the editable format recruiters and
  application portals still expect, so a member can tweak the CV for one
  specific application before sending it.

  A `.docx` is just a ZIP of WordprocessingML parts, so this builds a
  minimal, valid OOXML package with Erlang's `:zip` — no external binary,
  no library, nothing for an air-gapped install to configure. Word,
  LibreOffice and Pages all open it.

  The entry description is Markdown (issue #905), rendered through the
  shared `VutuvWeb.CV.MarkdownBlocks` floor (issue #920): one `<w:p>` per
  paragraph (line breaks as `<w:br/>`), list items as "•"/"1."-prefixed
  paragraphs (real Word lists would need a numbering part — not worth it
  for a description), inline markers stripped to their text.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.CV.MarkdownBlocks

  @word_ns "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

  def render(cv) do
    files = [
      {~c"[Content_Types].xml", content_types()},
      {~c"_rels/.rels", package_rels()},
      {~c"word/_rels/document.xml.rels", document_rels()},
      {~c"word/styles.xml", styles()},
      {~c"word/document.xml", document(cv)}
    ]

    {:ok, {_name, binary}} = :zip.create(~c"cv.docx", files, [:memory])
    binary
  end

  defp content_types do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    </Types>
    """
  end

  defp package_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """
  end

  defp document_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
  end

  # Calibri 11pt base, a big bold Title, small-caps-ish slate Heading1 —
  # enough structure that restyling in Word means editing two styles.
  defp styles do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="#{@word_ns}">
    <w:docDefaults>
    <w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr><w:spacing w:after="120"/></w:pPr></w:pPrDefault>
    </w:docDefaults>
    <w:style w:type="paragraph" w:styleId="Title">
    <w:name w:val="Title"/>
    <w:pPr><w:spacing w:after="40"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="48"/></w:rPr>
    </w:style>
    <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
    <w:pPr><w:spacing w:before="280" w:after="80"/></w:pPr>
    <w:rPr><w:b/><w:caps/><w:sz w:val="20"/><w:color w:val="475569"/></w:rPr>
    </w:style>
    </w:styles>
    """
  end

  defp document(cv) do
    body =
      [
        cv.name && paragraph(cv.name, style: "Title"),
        cv.headline && paragraph(cv.headline),
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
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="#{@word_ns}">
    <w:body>
    #{body}
    <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1417" w:right="1417" w:bottom="1417" w:left="1417"/></w:sectPr>
    </w:body>
    </w:document>
    """
  end

  defp contact(cv) do
    line =
      [cv.email, cv.phone, cv.profile_url]
      |> Enum.filter(& &1)
      |> Enum.join(" | ")

    if line != "", do: paragraph(line, muted: true)
  end

  defp address(%{address_lines: []}), do: nil
  defp address(cv), do: paragraph(Enum.join(cv.address_lines, ", "), muted: true)

  defp details(cv) do
    line =
      [detail(gettext("Date of birth"), cv.birthdate), detail(gettext("Gender"), cv.gender)]
      |> Enum.filter(& &1)
      |> Enum.join(" | ")

    if line != "", do: paragraph(line, muted: true)
  end

  defp detail(_label, nil), do: nil
  defp detail(label, value), do: "#{label}: #{value}"

  defp section(%{heading: heading, entries: entries}) do
    [paragraph(heading, style: "Heading1") | Enum.map(entries, &entry/1)]
  end

  defp entry(entry) do
    [
      paragraph(entry.role, bold: true, after: 20),
      entry.period && paragraph(entry.period, muted: true),
      entry.description && description_paragraphs(entry.description)
    ]
  end

  defp description_paragraphs(markdown) do
    markdown
    |> MarkdownBlocks.blocks()
    |> Enum.map(fn
      {:p, text} -> paragraph(text)
      {:ul, items} -> Enum.map(items, &paragraph("• " <> &1, after: 40))
      {:ol, items} -> items |> Enum.with_index(1) |> Enum.map(&numbered_paragraph/1)
    end)
  end

  defp numbered_paragraph({item, index}), do: paragraph("#{index}. #{item}", after: 40)

  defp skills([]), do: nil

  defp skills(skills) do
    [
      paragraph(gettext("Tags"), style: "Heading1"),
      paragraph(Enum.map_join(skills, " | ", & &1.name))
    ]
  end

  defp qualifications([]), do: nil

  defp qualifications(qualifications) do
    [
      paragraph(gettext("Certificates & licenses"), style: "Heading1"),
      paragraph(Enum.map_join(qualifications, " | ", & &1.label))
    ]
  end

  defp languages([]), do: nil

  defp languages(languages) do
    [
      paragraph(gettext("Languages"), style: "Heading1"),
      paragraph(Enum.map_join(languages, " | ", &"#{&1.name} (#{&1.fluency})"))
    ]
  end

  defp links([]), do: nil

  defp links(links) do
    lines =
      for link <- links do
        text = if link.label, do: "#{link.label}: #{link.url}", else: link.url
        paragraph(text)
      end

    [paragraph(gettext("Links"), style: "Heading1") | lines]
  end

  defp social_media([]), do: nil

  defp social_media(accounts) do
    lines =
      for account <- accounts do
        paragraph("#{account.provider}: #{account.url || account.handle}")
      end

    [paragraph(gettext("Profiles"), style: "Heading1") | lines]
  end

  # One paragraph; newlines in the text become soft line breaks.
  defp paragraph(text, opts \\ []) do
    props =
      [
        opts[:style] && ~s(<w:pStyle w:val="#{opts[:style]}"/>),
        opts[:after] && ~s(<w:spacing w:after="#{opts[:after]}"/>)
      ]
      |> Enum.filter(& &1)
      |> Enum.join()

    p_props = if props == "", do: "", else: "<w:pPr>#{props}</w:pPr>"

    run_props =
      [
        opts[:bold] && "<w:b/>",
        opts[:muted] && ~s(<w:color w:val="64748B"/><w:sz w:val="20"/>)
      ]
      |> Enum.filter(& &1)
      |> Enum.join()

    r_props = if run_props == "", do: "", else: "<w:rPr>#{run_props}</w:rPr>"

    runs =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map_join("<w:br/>", fn line ->
        ~s(<w:t xml:space="preserve">#{esc(line)}</w:t>)
      end)

    "<w:p>#{p_props}<w:r>#{r_props}#{runs}</w:r></w:p>"
  end

  # The canonical XML text escape (also escapes " and ', harmless in element
  # text) — the one definition shared with the sitemap/feed/odt renderers.
  defp esc(text), do: VutuvWeb.Xml.escape(text)
end
