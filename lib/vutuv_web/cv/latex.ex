defmodule VutuvWeb.CV.Latex do
  @moduledoc """
  The CV as LaTeX source (`.tex`) — for members who typeset their
  applications themselves and want full control over the layout. Plain
  `article` class with stock packages only, so it compiles on any TeX
  distribution without extra installs.

  Every user value goes through `esc/1` (all ten TeX specials); URLs are
  percent-encoded where a raw character would break `\\url{}`.
  """

  use Gettext, backend: VutuvWeb.Gettext

  def render(cv) do
    """
    % #{esc(gettext("CV"))}: #{esc(cv.name)}
    % #{esc(gettext("Generated from your vutuv profile"))}: #{url(cv.profile_url)}
    \\documentclass[11pt,a4paper]{article}
    \\usepackage[T1]{fontenc}
    \\usepackage[utf8]{inputenc}
    \\usepackage[margin=25mm]{geometry}
    \\usepackage{hyperref}
    \\pagestyle{empty}
    \\setlength{\\parindent}{0pt}
    \\begin{document}

    {\\LARGE\\bfseries #{esc(cv.name)}}
    #{headline(cv)}
    #{contact(cv)}
    #{Enum.map_join(cv.sections, "\n", &section/1)}
    #{skills(cv.skills)}
    #{links(cv.links)}
    \\end{document}
    """
  end

  defp headline(%{headline: nil}), do: ""
  defp headline(%{headline: headline}), do: "\n\\medskip\n\n#{esc(headline)}\n"

  defp contact(cv) do
    line =
      [cv.email, cv.phone]
      |> Enum.filter(& &1)
      |> Enum.map(&esc/1)
      |> Kernel.++(["\\url{#{url(cv.profile_url)}}"])
      |> Enum.join(" \\textbar{} ")

    address =
      if cv.address_lines == [] do
        ""
      else
        "\n\n" <> Enum.map_join(cv.address_lines, ", ", &esc/1)
      end

    "\n\\medskip\n\n#{line}#{address}\n"
  end

  defp section(%{heading: heading, entries: entries}) do
    """
    \\section*{#{esc(heading)}}
    #{Enum.map_join(entries, "\n\\medskip\n\n", &entry/1)}
    """
  end

  defp entry(entry) do
    role =
      [entry.title, entry.organization]
      |> Enum.filter(& &1)
      |> Enum.map_join(", ", &esc/1)

    period =
      if entry.period do
        " \\hfill #{entry.period |> esc() |> String.replace(" - ", " -- ")}"
      else
        ""
      end

    description = if entry.description, do: "\n\n#{esc(entry.description)}", else: ""

    "\\textbf{#{role}}#{period}#{description}\n"
  end

  defp skills([]), do: ""

  defp skills(skills) do
    """
    \\section*{#{esc(gettext("Tags"))}}
    #{Enum.map_join(skills, " \\textbullet{} ", &esc/1)}
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
