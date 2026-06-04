defmodule VutuvWeb.Plug.AuthRecruiter do
  @moduledoc false

  alias Vutuv.Recruiting.RecruiterSubscription

  def init(opts) do
    opts
  end

  def call(conn, _default) do
    current_user = conn.assigns[:current_user]

    cond do
      is_nil(current_user) ->
        forbidden(conn)

      current_user.id != conn.assigns[:user_id] ->
        forbidden(conn)

      true ->
        active_subscription = RecruiterSubscription.active_subscription(conn.assigns[:user_id])

        if active_subscription && active_subscription.paid do
          conn
        else
          forbidden(conn)
        end
    end
  end

  defp forbidden(conn) do
    VutuvWeb.ControllerHelpers.render_error(conn, 403)
  end
end
