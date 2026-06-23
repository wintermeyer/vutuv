defmodule Vutuv.Newsletters.Markdown do
  @moduledoc """
  Renders a newsletter's **trusted** (admin-authored) Markdown body to the
  inline-styled HTML email clients want, and substitutes the merge variables.

  The body is repo-equivalent trusted content (only admins compose newsletters),
  so Earmark runs directly here, like `VutuvWeb.DevDocMarkdown` and unlike the
  user-input `VutuvWeb.Markdown`. We deliberately do **not** run HtmlSanitizeEx:
  it strips the very `style` attributes we add. HTML email cannot use the web
  design system (`components.css` / `<style>` rules get dropped by many clients),
  so every block tag carries an inline `style` mirroring `VutuvWeb.EmailComponents`.

  Merge variables use a `{{name}}` syntax that survives Earmark untouched, so the
  body is rendered to HTML **once** and the per-recipient values are substituted
  into the finished HTML afterwards (`apply_vars/3`), HTML-escaped for the HTML
  body and raw for the plain-text body and the subject line.
  """

  # Mirrors the brand/slate palette + fonts in VutuvWeb.EmailComponents, kept
  # inline here (an HTML-email AST needs literal style strings, not a component).
  @font "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
  @mono "'SFMono-Regular',Menlo,Consolas,'Liberation Mono',monospace"

  @text "margin:0 0 16px;font-family:#{@font};font-size:16px;line-height:1.6;color:#334155;"
  @list "margin:0 0 16px;padding-left:20px;font-family:#{@font};font-size:16px;line-height:1.6;color:#334155;"

  @styles %{
    "p" => @text,
    "h1" =>
      "margin:24px 0 12px;font-family:#{@font};font-size:22px;line-height:1.3;font-weight:700;color:#0f172a;",
    "h2" =>
      "margin:24px 0 12px;font-family:#{@font};font-size:19px;line-height:1.3;font-weight:700;color:#0f172a;",
    "h3" =>
      "margin:20px 0 10px;font-family:#{@font};font-size:16px;line-height:1.4;font-weight:700;color:#0f172a;",
    "ul" => @list,
    "ol" => @list,
    "li" => "margin:0 0 6px;",
    "a" => "color:#1d4ed8;text-decoration:underline;",
    "blockquote" =>
      "margin:0 0 16px;padding:4px 16px;border-left:3px solid #dbeafe;font-family:#{@font};font-size:16px;line-height:1.6;color:#475569;",
    "code" =>
      "font-family:#{@mono};font-size:14px;background:#f1f5f9;padding:1px 5px;border-radius:4px;",
    "pre" =>
      "margin:0 0 16px;padding:14px;background:#0f172a;border-radius:8px;color:#e2e8f0;font-family:#{@mono};font-size:13px;line-height:1.5;overflow:auto;",
    "hr" => "border:0;border-top:1px solid #e2e8f0;margin:24px 0;",
    "img" => "max-width:100%;height:auto;border-radius:8px;"
  }

  @var_re ~r/\{\{\s*([a-zA-Z_]+)\s*\}\}/

  @doc """
  The merge variables a newsletter body / subject may use, with a short
  description, for the admin compose help and a substitution map.
  """
  def variables do
    [
      {"greeting", "Localized salutation, e.g. \"Hi Erika\""},
      {"first_name", "Recipient first name"},
      {"last_name", "Recipient last name"},
      {"name", "Recipient full name"},
      {"username", "Recipient @handle (without the @)"},
      {"email", "Recipient email address"}
    ]
  end

  @doc """
  Renders trusted Markdown to inline-styled HTML (merge tags left intact).

  `breaks: true` makes a single newline a `<br>` (like the chat composer and the
  plain-text email body), so an admin's multi-line signature stays multi-line
  instead of collapsing into one paragraph line.
  """
  def to_email_html(markdown) when is_binary(markdown) do
    {_status, ast, _messages} = Earmark.as_ast(markdown, breaks: true)

    ast
    |> style_nodes()
    |> Earmark.Transform.transform()
  end

  def to_email_html(_), do: ""

  @doc """
  Substitutes every `{{var}}` in `string` from `subs`. With `escape: true` the
  values are HTML-escaped (for the HTML body); otherwise inserted raw (the
  plain-text body and the subject). Unknown variables are left untouched.
  """
  def apply_vars(string, subs, opts \\ []) when is_binary(string) and is_map(subs) do
    escape? = Keyword.get(opts, :escape, false)
    Regex.replace(@var_re, string, fn whole, key -> substitute(whole, key, subs, escape?) end)
  end

  defp substitute(whole, key, subs, escape?) do
    case Map.fetch(subs, key) do
      {:ok, value} -> if escape?, do: html_escape(value), else: value
      :error -> whole
    end
  end

  defp html_escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp style_nodes(nodes) when is_list(nodes) do
    nodes |> Enum.map(&style_node/1) |> preserve_indent()
  end

  defp style_node({tag, attrs, content, meta}) do
    {tag, with_style(tag, attrs), style_nodes(content), meta}
  end

  # Text nodes (binaries) and anything else pass through unchanged.
  defp style_node(other), do: other

  # Make leading spaces on a line that follows a line break visible: HTML would
  # otherwise collapse them, so an indented signature line (e.g. two spaces
  # before the name under "Viele Grüße") loses its indent. We turn those leading
  # spaces into non-breaking spaces, which render. Only after a <br>, so normal
  # inline spacing is untouched.
  defp preserve_indent(nodes) do
    {out, _prev} =
      Enum.map_reduce(nodes, nil, fn node, prev ->
        converted =
          if is_binary(node) and match?({"br", _, _, _}, prev),
            do: leading_spaces_to_nbsp(node),
            else: node

        {converted, node}
      end)

    out
  end

  defp leading_spaces_to_nbsp(text) do
    Regex.replace(~r/^ +/, text, fn spaces ->
      String.duplicate("\u00A0", String.length(spaces))
    end)
  end

  defp with_style(tag, attrs) do
    case Map.fetch(@styles, tag) do
      {:ok, style} -> [{"style", style} | attrs]
      :error -> attrs
    end
  end
end
