defmodule VutuvWeb.CV.Docx do
  @moduledoc """
  The CV as a Word document (`.docx`) — the editable format recruiters and
  application portals still expect, so a member can tweak the CV for one
  specific application before sending it.

  A `.docx` is just a ZIP of WordprocessingML parts, so this builds a
  minimal, valid OOXML package with Erlang's `:zip` — no external binary,
  no library, nothing for an air-gapped install to configure. Word,
  LibreOffice and Pages all open it.
  """

  use Gettext, backend: VutuvWeb.Gettext

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
        Enum.map(cv.sections, &section/1),
        skills(cv.skills),
        links(cv.links)
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

  defp section(%{heading: heading, entries: entries}) do
    [paragraph(heading, style: "Heading1") | Enum.map(entries, &entry/1)]
  end

  defp entry(entry) do
    role =
      [entry.title, entry.organization]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    [
      paragraph(role, bold: true, after: 20),
      entry.period && paragraph(entry.period, muted: true),
      entry.description && paragraph(entry.description)
    ]
  end

  defp skills([]), do: nil

  defp skills(skills) do
    [
      paragraph(gettext("Tags"), style: "Heading1"),
      paragraph(Enum.map_join(skills, " | ", & &1.name))
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

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
