defmodule VutuvWeb.Admin.DeliverabilityHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers

  embed_templates("../../templates/admin/deliverability/*")

  @doc "Short timestamp for the dashboard tables."
  def fmt(nil), do: ""
  def fmt(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  @doc "The undeliverable addresses of a frozen member, comma-joined."
  def dead_addresses(%{emails: emails}) when is_list(emails) do
    emails
    |> Enum.filter(& &1.undeliverable_at)
    |> Enum.map_join(", ", & &1.value)
  end

  def dead_addresses(_user), do: ""

  @doc "Human label for a deliverability audit action (see Vutuv.Deliverability.Event)."
  def event_label("address_deactivated"), do: gettext("Address deactivated (bounced)")
  def event_label("address_recovered"), do: gettext("Address mark cleared")
  def event_label("account_frozen"), do: gettext("Account frozen (unreachable)")
  def event_label("account_thawed"), do: gettext("Account thawed")
  def event_label(other), do: other

  @doc "Why a transition happened, from the event detail map (string keys)."
  def reason_label(%{"reason" => "repeated_bounces"}), do: gettext("repeated hard bounces")
  def reason_label(%{"reason" => "grace_period"}), do: gettext("dead past the grace period")
  def reason_label(%{"reason" => "address_recovered"}), do: gettext("an address works again")
  def reason_label(%{"reason" => "admin"}), do: gettext("admin action")
  def reason_label(%{"dsn" => dsn}) when is_binary(dsn), do: dsn
  def reason_label(_detail), do: nil

  @doc "Whether a transition was automatic (no actor) or by an admin."
  def actor_link(nil, _users), do: gettext("system")

  def actor_link(actor_id, users) do
    case Map.get(users, actor_id) do
      nil -> gettext("(gone)")
      user -> "@" <> user.username
    end
  end
end
