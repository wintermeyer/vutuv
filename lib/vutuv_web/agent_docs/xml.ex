defmodule VutuvWeb.AgentDocs.Xml do
  @moduledoc """
  Renders an agent doc (see `VutuvWeb.AgentDocs`) as a plain, self-describing
  XML document, the machine sibling of the JSON renderer. The doc map is the
  single source of truth; this walks it generically, so a new doc field shows
  up in the XML for free, exactly as it does in JSON.

  Vocabulary (vutuv-native, deliberately simple so XSLT/XPath consumers can
  rely on it):

    * the root element is the doc's `type` (`<profile>`, `<post>`, `<tag>`, ...);
    * every map key becomes a child element of the same name;
    * a list renders as repeated `<item>` children inside the key element;
    * scalars are the element's text content, XML-escaped; an empty
      list/map or a `nil` renders as an empty element.

  Like JSON, the renderer-internal keys (`:noindex`/`:noai`/`:vcard_photo`)
  are dropped, and being a machine format it carries no `Accept-Language`
  hint (that stays to `:md`/`:txt` in `VutuvWeb.AgentDocs`).
  """

  # Steer the Content-Signal header / are vCard-only payload, never the body.
  # Mirrors VutuvWeb.AgentDocs.JSON so the two machine formats stay in step.
  @internal_keys [:noindex, :noai, :vcard_photo]

  @indent "  "

  def render(doc) do
    root = element_name(Map.get(doc, :type, "document"))
    children = doc |> Map.drop(@internal_keys) |> render_children(1)

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      "<",
      root,
      ">\n",
      children,
      "</",
      root,
      ">\n"
    ])
  end

  defp render_children(map, depth) do
    map
    |> Enum.map(fn {key, value} -> render_node(element_name(key), value, depth) end)
  end

  # An empty collection or a nil collapses to a self-closing element.
  defp render_node(name, value, depth) when value in [%{}, [], nil] do
    [pad(depth), "<", name, "/>\n"]
  end

  defp render_node(name, value, depth) when is_map(value) and not is_struct(value) do
    [
      pad(depth),
      "<",
      name,
      ">\n",
      render_children(value, depth + 1),
      pad(depth),
      "</",
      name,
      ">\n"
    ]
  end

  defp render_node(name, value, depth) when is_list(value) do
    items = Enum.map(value, &render_node("item", &1, depth + 1))
    [pad(depth), "<", name, ">\n", items, pad(depth), "</", name, ">\n"]
  end

  defp render_node(name, value, depth) do
    [pad(depth), "<", name, ">", VutuvWeb.Xml.escape(scalar(value)), "</", name, ">\n"]
  end

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_boolean(value), do: to_string(value)
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(%Date{} = value), do: Date.to_iso8601(value)
  defp scalar(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp scalar(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp scalar(%Time{} = value), do: Time.to_iso8601(value)
  defp scalar(value), do: to_string(value)

  # Doc keys are clean identifiers already; the sanitize is defensive so a
  # value-derived name (the root type) can never emit an invalid element.
  defp element_name(key) when is_atom(key), do: element_name(Atom.to_string(key))

  defp element_name(key) when is_binary(key) do
    sanitized = String.replace(key, ~r/[^A-Za-z0-9_.-]/, "_")
    if sanitized =~ ~r/^[A-Za-z_]/, do: sanitized, else: "_" <> sanitized
  end

  defp pad(depth), do: String.duplicate(@indent, depth)
end
