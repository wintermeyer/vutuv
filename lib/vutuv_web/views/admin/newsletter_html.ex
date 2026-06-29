defmodule VutuvWeb.Admin.NewsletterHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Newsletters

  embed_templates("../../templates/admin/newsletter/*")

  @doc "Short timestamp for the listing and delivery-log tables."
  def fmt(nil), do: ""
  def fmt(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  @doc "Human label for a newsletter status."
  def status_label("draft"), do: gettext("Draft")
  def status_label("sending"), do: gettext("Sending")
  def status_label("sent"), do: gettext("Sent")
  def status_label(other), do: other

  @doc "Human label for a delivery status."
  def delivery_status_label("sent"), do: gettext("Sent")
  def delivery_status_label("suppressed"), do: gettext("Suppressed (bounced address)")
  def delivery_status_label("error"), do: gettext("Error")
  def delivery_status_label(other), do: other

  @doc "Human label for a delivery kind."
  def kind_label("test"), do: gettext("Test")
  def kind_label("broadcast"), do: gettext("Broadcast")
  def kind_label(other), do: other

  @doc "The delivery-log page size, shared by the query and the pager."
  def deliveries_per_page, do: Newsletters.deliveries_per_page()

  @doc "The click-log page size, shared by the query and the pager."
  def clicks_per_page, do: Newsletters.clicks_per_page()

  @doc "A click rate as a one-decimal percentage string, German with a decimal comma."
  def percent(rate) when is_number(rate) do
    decimal = if Gettext.get_locale(VutuvWeb.Gettext) == "de", do: ",", else: "."

    string =
      rate
      |> Float.round(1)
      |> :erlang.float_to_binary(decimals: 1)
      |> String.replace(".", decimal)

    "#{string} %"
  end

  @doc "The active filters as a string-keyed query map (for the pager and links)."
  def delivery_query(filters) do
    %{
      "q" => filters.q,
      "kind" => filters.kind,
      "status" => filters.status,
      "sort" => filters.sort,
      "dir" => filters.dir
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  @doc "The query for a sortable header link: select `column`, toggling direction."
  def sort_query(filters, column) do
    dir = if filters.sort == column and filters.dir == "asc", do: "desc", else: "asc"

    filters
    |> delivery_query()
    |> Map.merge(%{"sort" => column, "dir" => dir})
  end

  @doc "The sort indicator (▲/▼) for a header, or empty when it is not the sort column."
  def sort_caret(filters, column) do
    cond do
      filters.sort != column -> ""
      filters.dir == "asc" -> " ▲"
      true -> " ▼"
    end
  end

  @doc "The merge variables available to the composer."
  def variables, do: Newsletters.variables()
end
