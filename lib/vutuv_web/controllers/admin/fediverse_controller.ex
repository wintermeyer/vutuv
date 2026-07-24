defmodule VutuvWeb.Admin.FediverseController do
  @moduledoc """
  The operator's Fediverse screen (`/admin/fediverse`, issue #1067): the
  blocklist of remote servers, what each server has stored here, and the
  inbound caps currently in force.

  Anyone can run an ActivityPub server, so "a server we federate with" is not a
  vetted party. This is the kill switch: block a host and everything it sent is
  dropped and everything already stored from it is deleted. Which servers an
  installation refuses is per-installation content, so it lives in data with an
  admin screen, never in a source edit.
  """
  use VutuvWeb, :controller

  alias Vutuv.Fediverse
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.UI

  # Everything Fediverse 404s while the installation-wide switch is off, so an
  # intranet installation has no blocklist screen either.
  plug(:require_fediverse)

  def index(conn, _params) do
    render(conn, "index.html",
      blocked: Fediverse.list_blocked_instances(),
      inbound_hosts: Fediverse.inbound_hosts(),
      stats: Fediverse.stats(),
      caps: Fediverse.inbound_caps(),
      page_title: gettext("Fediverse")
    )
  end

  def create(conn, %{"blocked_instance" => attrs}) do
    case Fediverse.block_instance(attrs, conn.assigns.current_user) do
      {:ok, {blocked, purged}} ->
        conn
        |> put_flash(:info, blocked_message(blocked, purged))
        |> redirect(to: ~p"/admin/fediverse")

      {:error, _changeset} ->
        conn
        |> put_flash(
          :error,
          gettext("Enter the server name on its own, for example mastodon.example.")
        )
        |> redirect(to: ~p"/admin/fediverse")
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/admin/fediverse")

  def delete(conn, %{"id" => id}) do
    case Fediverse.unblock_instance(id) do
      {:ok, blocked} ->
        conn
        |> put_flash(
          :info,
          gettext(
            "%{host} is no longer blocked. What was deleted stays deleted; the server has to follow again.",
            host: blocked.host
          )
        )
        |> redirect(to: ~p"/admin/fediverse")

      {:error, _} ->
        redirect(conn, to: ~p"/admin/fediverse")
    end
  end

  defp blocked_message(blocked, %{followers: followers, deliveries: deliveries}) do
    gettext(
      "%{host} is blocked. Removed: %{followers} remote followers and %{deliveries} queued deliveries.",
      host: blocked.host,
      followers: UI.delimited_count(followers),
      deliveries: UI.delimited_count(deliveries)
    )
  end

  defp require_fediverse(conn, _opts) do
    if Fediverse.enabled?(), do: conn, else: ControllerHelpers.render_error(conn, 404)
  end
end
