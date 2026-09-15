defmodule VutuvWeb.PostHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.PostComponents
  import VutuvWeb.UserHelpers

  embed_templates("../templates/post/*")

  def range_label("7d"), do: gettext("7 days")
  def range_label("30d"), do: gettext("30 days")
  def range_label("1y"), do: gettext("1 year")

  def bucket_label(at, "hour"), do: Calendar.strftime(at, "%d %b %Y, %H:00 UTC")
  def bucket_label(at, "day"), do: Calendar.strftime(at, "%d %b %Y")

  @doc """
  The author-facing audience summary: one short label per denial. Only ever
  rendered for the post's owner — readers must not see the deny list.
  """
  def denial_labels(post) do
    Enum.map(post.denials, &denial_label/1)
  end

  defp denial_label(%{wildcard: wildcard}) when is_binary(wildcard), do: wildcard_label(wildcard)
  defp denial_label(%{denied_user: %{} = user}), do: full_name(user)
  defp denial_label(_), do: gettext("unknown")
end
