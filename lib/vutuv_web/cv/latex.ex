defmodule VutuvWeb.CV.Latex do
  @moduledoc """
  The CV as LaTeX source (`.tex`) — for members who typeset their
  applications themselves and want full control over the layout. Plain
  `article` class with stock packages only, so it compiles on any TeX
  distribution without extra installs.

  Every user value goes through `esc/1` (all ten TeX specials); URLs are
  percent-encoded where a raw character would break `\\url{}`. The entry
  description is Markdown (issue #905), rendered through the shared
  `VutuvWeb.CV.MarkdownBlocks` floor (issue #920): paragraphs with line
  breaks, real itemize/enumerate lists, inline markers stripped to text.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.CV.MarkdownBlocks

  def render(cv) do
    name = if cv.name, do: "{\\LARGE\\bfseries #{esc(cv.name)}}\n", else: ""

    """
    % #{esc(title(cv))}
    \\documentclass[11pt,a4paper]{article}
    \\usepackage[T1]{fontenc}
    \\usepackage[utf8]{inputenc}
    \\usepackage[margin=25mm]{geometry}
    \\usepackage{hyperref}
    \\pagestyle{empty}
    \\setlength{\\parindent}{0pt}
    \\begin{document}

    #{name}#{headline(cv)}
    #{contact(cv)}
    #{Enum.map_join(cv.sections, "\n", &section/1)}
    #{skills(cv.skills)}
    #{qualifications(cv.qualifications)}
    #{languages(cv.languages)}
    #{links(cv.links)}
    #{social_media(cv.social_media)}
    \\end{document}
    """
  end

  defp title(%{name: nil}), do: gettext("CV")
  defp title(%{name: name}), do: "#{gettext("CV")}: #{name}"

  defp headline(%{headline: nil}), do: ""
  defp headline(%{headline: headline}), do: "\n\\medskip\n\n#{esc(headline)}\n"

  defp contact(cv) do
    url_part = if cv.profile_url, do: ["\\url{#{url(cv.profile_url)}}"], else: []

    line =
      [cv.email, cv.phone]
      |> Enum.filter(& &1)
      |> Enum.map(&esc/1)
      |> Kernel.++(url_part)
      |> Enum.join(" \\textbar{} ")

    address =
      if cv.address_lines == [] do
        ""
      else
        "\n\n" <> Enum.map_join(cv.address_lines, ", ", &esc/1)
      end

    details =
      [detail(gettext("Date of birth"), cv.birthdate), detail(gettext("Gender"), cv.gender)]
      |> Enum.filter(& &1)
      |> Enum.join(" \\textbar{} ")

    details = if details == "", do: "", else: "\n\n" <> details

    if line == "" and address == "" and details == "",
      do: "",
      else: "\n\\medskip\n\n#{line}#{address}#{details}\n"
  end

  defp detail(_label, nil), do: nil
  defp detail(label, value), do: "#{esc(label)}: #{esc(value)}"

  defp section(%{heading: heading, entries: entries}) do
    """
    \\section*{#{esc(heading)}}
    #{Enum.map_join(entries, "\n\\medskip\n\n", &entry/1)}
    """
  end

  defp entry(entry) do
    role = esc(entry.role)

    period =
      if entry.period do
        " \\hfill #{entry.period |> esc() |> String.replace(" - ", " -- ")}"
      else
        ""
      end

    description =
      if entry.description, do: "\n\n#{description_blocks(entry.description)}", else: ""

    "\\textbf{#{role}}#{period}#{description}\n"
  end

  # The description Markdown as LaTeX blocks: paragraphs keep their line
  # breaks (`\\`), lists become itemize/enumerate. The extracted plain text
  # goes through the same `esc/1` as every other user value.
  defp description_blocks(markdown) do
    markdown
    |> MarkdownBlocks.blocks()
    |> Enum.map_join("\n\n", &latex_block/1)
  end

  defp latex_block({:p, text}), do: multiline(text)

  defp latex_block({:ul, items}) do
    "\\begin{itemize}\n#{Enum.map_join(items, "\n", &"\\item #{multiline(&1)}")}\n\\end{itemize}"
  end

  defp latex_block({:ol, items}) do
    "\\begin{enumerate}\n#{Enum.map_join(items, "\n", &"\\item #{multiline(&1)}")}\n\\end{enumerate}"
  end

  defp multiline(text), do: text |> esc() |> String.replace("\n", " \\\\\n")

  defp skills([]), do: ""

  defp skills(skills) do
    """
    \\section*{#{esc(gettext("Tags"))}}
    #{Enum.map_join(skills, " \\textbullet{} ", fn skill -> esc(skill.name) end)}
    """
  end

  defp qualifications([]), do: ""

  defp qualifications(qualifications) do
    """
    \\section*{#{esc(gettext("Certificates & licenses"))}}
    #{Enum.map_join(qualifications, " \\textbullet{} ", &esc(&1.label))}
    """
  end

  defp languages([]), do: ""

  defp languages(languages) do
    """
    \\section*{#{esc(gettext("Languages"))}}
    #{Enum.map_join(languages, " \\textbullet{} ", fn language -> esc("#{language.name} (#{language.fluency})") end)}
    """
  end

  defp links([]), do: ""

  defp links(links) do
    items =
      Enum.map_join(links, "\n\n", fn link ->
        label = if link.label, do: "#{esc(link.label)}: ", else: ""
        "#{label}\\url{#{url(link.url)}}"
      end)

    """
    \\section*{#{esc(gettext("Links"))}}
    #{items}
    """
  end

  defp social_media([]), do: ""

  defp social_media(accounts) do
    items =
      Enum.map_join(accounts, "\n\n", fn account ->
        target = if account.url, do: "\\url{#{url(account.url)}}", else: esc(account.handle)
        "#{esc(account.provider)}: #{target}"
      end)

    """
    \\section*{#{esc(gettext("Profiles"))}}
    #{items}
    """
  end

  @specials %{
    "\\" => "\\textbackslash{}",
    "{" => "\\{",
    "}" => "\\}",
    "$" => "\\$",
    "&" => "\\&",
    "#" => "\\#",
    "^" => "\\textasciicircum{}",
    "_" => "\\_",
    "%" => "\\%",
    "~" => "\\textasciitilde{}"
  }

  # Grapheme-wise, so an escape sequence is never re-escaped.
  defp esc(text) do
    text
    |> String.graphemes()
    |> Enum.map_join(&Map.get(@specials, &1, &1))
  end

  # Inside \\url{} most characters are safe verbatim; the ones that are not
  # (braces end the group, a backslash starts a command, spaces vanish) are
  # percent-encoded, which keeps the URL a valid URL.
  defp url(url) do
    url
    |> String.replace("\\", "%5C")
    |> String.replace("{", "%7B")
    |> String.replace("}", "%7D")
    |> String.replace(" ", "%20")
  end
end
