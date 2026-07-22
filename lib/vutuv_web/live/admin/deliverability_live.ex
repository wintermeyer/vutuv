defmodule VutuvWeb.Admin.DeliverabilityLive do
  @moduledoc """
  The admin email-deliverability dashboard (`/admin/deliverability`). Surfaces the
  bounce machinery so an admin can see and undo it: accounts frozen because every
  address bounced (`Vutuv.Deliverability`), addresses currently marked
  undeliverable, the raw bounce ledger and the audit trail of every transition.

  Two undo actions, both **reload-free** over the socket: thaw a frozen account, or
  clear a single address's undeliverable mark (which re-assesses the owner, lifting
  a freeze if a working address remains). The classic CSRF POST routes
  (`DeliverabilityController.thaw/clear_address`) stay as the no-JS / scriptable
  fallback. Lives in the `:admin` live_session (`on_mount :require_admin`).
  """

  use VutuvWeb, :live_view

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  import Ecto.Query

  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.Deliverability
  alias Vutuv.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Deliverability")) |> load()}
  end

  @impl true
  def handle_event("thaw", %{"id" => id}, socket) do
    case Repo.get(User, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That account no longer exists."))}

      user ->
        socket =
          case Deliverability.thaw(user, socket.assigns.current_user) do
            {:ok, :thawed} ->
              put_flash(socket, :info, gettext("Account thawed; the member is reachable again."))

            {:ok, :noop} ->
              put_flash(socket, :error, gettext("That account was not frozen."))
          end

        {:noreply, load(socket)}
    end
  end

  def handle_event("clear", %{"id" => id}, socket) do
    case Repo.get(Email, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That address no longer exists."))}

      email ->
        Deliverability.clear_address(email, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Address mark cleared; the owner was re-assessed."))
         |> load()}
    end
  end

  # Re-read every list from the source so a thaw/clear re-renders the whole
  # dashboard consistently (a clear can lift a freeze, dropping a row from two
  # tables at once and appending to the audit trail).
  defp load(socket) do
    events = Deliverability.recent_events()

    socket
    |> assign(:frozen, Deliverability.frozen_accounts())
    |> assign(:deactivated, Deliverability.deactivated_addresses())
    |> assign(:bounces, Deliverability.recent_bounces())
    |> assign(:events, events)
    |> assign(:users, users_for_events(events))
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

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Deliverability")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Deliverability")]}
    />

    <div class="card-list">
      <section class="card">
        <h1 class="flex items-center gap-2">
          {gettext("Frozen accounts")}
          <.count_badge count={length(@frozen)} />
        </h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Confirmed members whose every email address bounced, so they can no longer receive a login PIN. Hidden from other members until an address works again. Thaw to lift the freeze."
          )}
        </p>

        <p :if={@frozen == []} class="card__empty">
          {gettext("No accounts are frozen for unreachability.")}
        </p>

        <div :if={@frozen != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Member")}</th>
                <th>{gettext("Dead addresses")}</th>
                <th>{gettext("Frozen since")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={u <- @frozen} id={"frozen-#{u.id}"}>
                <td>
                  <a href={~p"/#{u}"}>
                    {full_name(u)} <span class="text-slate-600 dark:text-slate-400">@{u.username}</span>
                  </a>
                </td>
                <td class="breakwrap">{dead_addresses(u)}</td>
                <td><.local_time at={u.unreachable_at} id={"frozen-time-#{u.id}"} /></td>
                <td class="text-right">
                  <button
                    type="button"
                    class="button button--small"
                    id={"thaw-#{u.id}"}
                    phx-click="thaw"
                    phx-value-id={u.id}
                  >
                    {gettext("Thaw")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="card">
        <h1 class="flex items-center gap-2">
          {gettext("Deactivated addresses")}
          <.count_badge count={length(@deactivated)} />
        </h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Addresses marked undeliverable after a hard bounce. Automatic mail to them is dropped; login PINs still send. Clearing the mark is normally automatic on the next successful login PIN."
          )}
        </p>

        <p :if={@deactivated == []} class="card__empty">
          {gettext("No addresses are deactivated.")}
        </p>

        <div :if={@deactivated != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Address")}</th>
                <th>{gettext("Owner")}</th>
                <th>{gettext("Since")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @deactivated} id={"deactivated-#{e.id}"}>
                <td class="breakwrap">{e.value}</td>
                <td>
                  <a :if={e.user} href={~p"/#{e.user}"}>@{e.user.username}</a>
                  <span :if={is_nil(e.user)} class="text-slate-600 dark:text-slate-400">{gettext("(unknown)")}</span>
                </td>
                <td><.local_time at={e.undeliverable_at} id={"deactivated-time-#{e.id}"} /></td>
                <td class="text-right">
                  <button
                    type="button"
                    class="button button--small button--secondary"
                    id={"clear-#{e.id}"}
                    phx-click="clear"
                    phx-value-id={e.id}
                  >
                    {gettext("Clear")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="card">
        <h1>{gettext("Audit trail")}</h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Every deactivation, recovery, freeze and thaw, newest first.")}
        </p>

        <p :if={@events == []} class="card__empty">{gettext("No deliverability events yet.")}</p>

        <div :if={@events != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Action")}</th>
                <th>{gettext("Member / address")}</th>
                <th>{gettext("Why")}</th>
                <th>{gettext("By")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={ev <- @events} id={"event-#{ev.id}"}>
                <td><.local_time at={ev.inserted_at} id={"event-time-#{ev.id}"} /></td>
                <td>{event_label(ev.action)}</td>
                <td class="breakwrap">
                  <%= if member = ev.user_id && Map.get(@users, ev.user_id) do %>
                    <a href={~p"/#{member}"}>@{member.username}</a>
                  <% end %>
                  <span :if={ev.email_value} class="text-slate-600 dark:text-slate-400">{ev.email_value}</span>
                </td>
                <td>{reason_label(ev.detail)}</td>
                <td>{actor_link(ev.actor_id, @users)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="card">
        <h1>{gettext("Recent bounces")}</h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext("The raw bounce ledger, newest first.")}
        </p>

        <p :if={@bounces == []} class="card__empty">{gettext("No bounces recorded.")}</p>

        <div :if={@bounces != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Address")}</th>
                <th>{gettext("Status")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={b <- @bounces} id={"bounce-#{b.id}"}>
                <td><.local_time at={b.inserted_at} id={"bounce-time-#{b.id}"} /></td>
                <td class="breakwrap">{b.email_value}</td>
                <td>{b.status}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  # ---- presentation helpers (moved here from the deleted DeliverabilityHTML) ----

  # The undeliverable addresses of a frozen member, comma-joined.
  defp dead_addresses(%{emails: emails}) when is_list(emails) do
    emails
    |> Enum.filter(& &1.undeliverable_at)
    |> Enum.map_join(", ", & &1.value)
  end

  defp dead_addresses(_user), do: ""

  # Human label for a deliverability audit action (see Vutuv.Deliverability.Event).
  defp event_label("address_deactivated"), do: gettext("Address deactivated (bounced)")
  defp event_label("address_recovered"), do: gettext("Address mark cleared")
  defp event_label("account_frozen"), do: gettext("Account frozen (unreachable)")
  defp event_label("account_thawed"), do: gettext("Account thawed")
  defp event_label(other), do: other

  # Why a transition happened, from the event detail map (string keys).
  defp reason_label(%{"reason" => "repeated_bounces"}), do: gettext("repeated hard bounces")
  defp reason_label(%{"reason" => "grace_period"}), do: gettext("dead past the grace period")
  defp reason_label(%{"reason" => "address_recovered"}), do: gettext("an address works again")
  defp reason_label(%{"reason" => "admin"}), do: gettext("admin action")

  defp reason_label(%{"reason" => "misclassified_bounce"}),
    do: gettext("bounce was misclassified (quota/blocked, not a dead mailbox)")

  defp reason_label(%{"dsn" => dsn}) when is_binary(dsn), do: dsn
  defp reason_label(_detail), do: nil

  # Whether a transition was automatic (no actor) or by an admin.
  defp actor_link(nil, _users), do: gettext("system")

  defp actor_link(actor_id, users) do
    case Map.get(users, actor_id) do
      nil -> gettext("(gone)")
      user -> "@" <> user.username
    end
  end
end
