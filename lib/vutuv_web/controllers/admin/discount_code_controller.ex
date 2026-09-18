defmodule VutuvWeb.Admin.DiscountCodeController do
  @moduledoc """
  Discount codes for ad bookings, at `/admin/ads/discounts`: the list, the form
  that makes one, and forgetting one.

  One page rather than the usual index/new/show trio. A code is four fields and
  is read as a row — an admin makes one, copies it and hands it over, so the
  form belongs beside the list it lands in, and a detail page would only repeat
  the row it came from.
  """
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireAdsEnabled)

  alias Vutuv.Accounts
  alias Vutuv.Ads.DiscountCode
  alias Vutuv.Ads.Discounts

  def index(conn, _params) do
    render_index(conn, Discounts.change_code(%DiscountCode{}))
  end

  def create(conn, %{"discount_code" => params}) do
    case Discounts.create_code(conn.assigns[:current_user], member_params(params)) do
      {:ok, code} ->
        conn
        |> put_flash(:info, gettext("Code %{code} is ready to hand out.", code: code.id))
        |> redirect(to: ~p"/admin/ads/discounts")

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render_index(changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Discounts.delete_code(id) do
      {:ok, _code} ->
        conn
        |> put_flash(:info, gettext("The code is gone. Bookings that used it keep their price."))
        |> redirect(to: ~p"/admin/ads/discounts")

      {:error, :not_found} ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  # The form asks for a handle, because nobody knows a member's UUID; an unknown
  # one is an error on the field rather than a silently unrestricted code, which
  # is the difference between "for Anna" and "for everybody".
  defp member_params(%{"username" => username} = params) when is_binary(username) do
    case String.trim(username) do
      "" -> Map.put(params, "user_id", nil)
      handle -> Map.put(params, "user_id", user_id_for(handle))
    end
  end

  defp member_params(params), do: params

  defp user_id_for(handle) do
    case Accounts.get_user_by_username(String.trim_leading(handle, "@")) do
      nil -> "unknown"
      user -> user.id
    end
  end

  defp render_index(conn, changeset) do
    render(conn, "index.html",
      codes: Discounts.list_codes(),
      changeset: changeset,
      default_expiry: DiscountCode.default_expiry(),
      page_title: gettext("Ad discount codes")
    )
  end
end
