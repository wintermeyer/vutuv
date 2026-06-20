defmodule VutuvWeb.Admin.DeliverabilityController do
  @moduledoc """
  The admin email-deliverability dashboard. Surfaces the bounce machinery so an
  admin can see and undo it: accounts frozen because every address bounced
  (`Vutuv.Deliverability`), addresses currently marked undeliverable, the raw
  bounce ledger, and the audit trail of every transition. Two undo actions:
  thaw a frozen account, or clear a single address's undeliverable mark (which
  re-assesses the owner, lifting a freeze if a working address remains).
  """

  use VutuvWeb, :controller

  import Ecto.Query

  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.Deliverability
  alias Vutuv.Repo
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    events = Deliverability.recent_events()

    render(conn, "index.html",
      page_title: gettext("Deliverability"),
      frozen: Deliverability.frozen_accounts(),
      deactivated: Deliverability.deactivated_addresses(),
      bounces: Deliverability.recent_bounces(),
      events: events,
      users: users_for_events(events)
    )
  end

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

  # The audit rows reference members by bare id (the ledger is FK-free); resolve
  # them in one query so the template can link names.
  defp users_for_events(events) do
    ids =
      events
      |> Enum.flat_map(&[&1.user_id, &1.actor_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.all(from(u in User, where: u.id in ^ids)) |> Map.new(&{&1.id, &1})
  end
end
