defmodule VutuvWeb.Xml do
  @moduledoc """
  The one XML text escape, shared by the hand-built sitemap and feed
  renderers (consistent with the hand-built vCard/Markdown ones — no XML
  dependency for two small documents).
  """

  @escapes [{"&", "&amp;"}, {"<", "&lt;"}, {">", "&gt;"}, {~s("), "&quot;"}, {"'", "&apos;"}]

  def escape(text) when is_binary(text) do
    Enum.reduce(@escapes, text, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  def escape(other), do: other |> to_string() |> escape()
end
