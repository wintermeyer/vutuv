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

  ## Click tracking

  With `to_email_html(body, track: true)` every link to vutuv.de gets a
  `?nlt=<placeholder>` tracking parameter on its `href` (the visible link text is
  untouched, so the URL still reads normally). The placeholder is swapped for the
  per-recipient signed token by `put_click_token/2`, once per recipient, after
  the merge variables are substituted. The plain-text body never goes through
  here, so the ASCII version keeps the bare link. External links are left alone.
  """

  alias VutuvWeb.NewsletterToken

  # The literal stand-in for the per-recipient click token. It is inserted into
  # the rendered HTML once (so the render still happens a single time) and
  # `put_click_token/2` replaces it per recipient. Deliberately made of plain
  # letters/underscores so Earmark's HTML transform leaves it byte-for-byte
  # intact and a simple String.replace finds it.
  @click_sentinel "__vutuv_nlt__"

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

  With `track: true` every internal (vutuv.de) link gets the click-tracking
  placeholder on its `href` (see `put_click_token/2`); the default leaves links
  untouched (the admin preview).
  """
  def to_email_html(markdown, opts \\ [])

  def to_email_html(markdown, opts) when is_binary(markdown) do
    {_status, ast, _messages} = Earmark.as_ast(markdown, breaks: true)
    hosts = if Keyword.get(opts, :track, false), do: internal_hosts(), else: []

    ast
    |> style_nodes(hosts)
    |> Earmark.Transform.transform()
  end

  def to_email_html(_markdown, _opts), do: ""

  @doc """
  Swaps the per-recipient click-token placeholder left by
  `to_email_html(body, track: true)` for `token` in the rendered HTML. Called
  once per recipient, after the merge variables are substituted. A no-op when the
  body carries no tracked links.
  """
  def put_click_token(html, token) when is_binary(html) and is_binary(token),
    do: String.replace(html, @click_sentinel, token)

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

  defp style_nodes(nodes, hosts) when is_list(nodes) do
    nodes |> Enum.map(&style_node(&1, hosts)) |> preserve_indent()
  end

  defp style_node({tag, attrs, content, meta}, hosts) do
    {tag, attrs |> with_style(tag) |> track_link(tag, hosts), style_nodes(content, hosts), meta}
  end

  # Text nodes (binaries) and anything else pass through unchanged.
  defp style_node(other, _hosts), do: other

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

  defp with_style(attrs, tag) do
    case Map.fetch(@styles, tag) do
      {:ok, style} -> [{"style", style} | attrs]
      :error -> attrs
    end
  end

  # Appends the click-tracking placeholder to an internal link's href. Only
  # touches <a> tags, and only when tracking is on (hosts != []). The visible
  # link content is left alone — only the href carries the parameter.
  defp track_link(attrs, "a", [_ | _] = hosts) do
    Enum.map(attrs, fn
      {"href", url} -> {"href", tracked_href(url, hosts)}
      other -> other
    end)
  end

  defp track_link(attrs, _tag, _hosts), do: attrs

  defp tracked_href(url, hosts) when is_binary(url) do
    uri = URI.parse(url)

    if uri.host in hosts do
      URI.to_string(%{uri | query: append_click_param(uri.query)})
    else
      url
    end
  end

  defp tracked_href(url, _hosts), do: url

  defp append_click_param(nil), do: "#{NewsletterToken.param()}=#{@click_sentinel}"
  defp append_click_param(query), do: "#{query}&#{NewsletterToken.param()}=#{@click_sentinel}"

  # The hosts that count as "vutuv.de" for link tracking: the configured public
  # host plus its www/non-www twin, so a link to either form is tracked.
  defp internal_hosts do
    case Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url] do
      url when is_binary(url) -> url |> URI.parse() |> Map.get(:host) |> host_variants()
      _ -> []
    end
  end

  defp host_variants(nil), do: []
  defp host_variants("www." <> rest = host), do: [host, rest]
  defp host_variants(host), do: [host, "www." <> host]
end
