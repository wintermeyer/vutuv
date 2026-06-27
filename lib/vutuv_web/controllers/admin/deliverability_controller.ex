defmodule VutuvWeb.Admin.DeliverabilityController do
  @moduledoc """
  The two undo actions behind the deliverability dashboard. The dashboard itself
  is a LiveView (`VutuvWeb.Admin.DeliverabilityLive`), where thaw/clear act
  reload-free; these CSRF POSTs are the no-JS / scriptable fallback. thaw lifts a
  freeze; clear lifts a single address's undeliverable mark (re-assessing the
  owner, which lifts a freeze if a working address remains). See
  `Vutuv.Deliverability`.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.Deliverability
  alias Vutuv.Repo
  alias VutuvWeb.ControllerHelpers

  def thaw(conn, %{"id" => id}) do
    case Repo.get(User, id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      user ->
        message =
          case Deliverability.thaw(user, conn.assigns.current_user) do
            {:ok, :thawed} -> {:info, gettext("Account thawed; the member is reachable again.")}
            {:ok, :noop} -> {:error, gettext("That account was not frozen.")}
          end

        flash_redirect(conn, message)
    end
  end

  def clear_address(conn, %{"id" => id}) do
    case Repo.get(Email, id) do
      nil ->
        ControllerHelpers.render_error(conn, 404)

      email ->
        Deliverability.clear_address(email, conn.assigns.current_user)
        flash_redirect(conn, {:info, gettext("Address mark cleared; the owner was re-assessed.")})
    end
  end

  defp flash_redirect(conn, {kind, message}) do
    conn
    |> put_flash(kind, message)
    |> redirect(to: ~p"/admin/deliverability")
  end
end
