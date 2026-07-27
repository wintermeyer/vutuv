defmodule VutuvWeb.LandingExperiment do
  @moduledoc """
  The web half of the landing-page headline split test (`Vutuv.Experiments`):
  which variant this visitor sees, and where the three counters are bumped.

  The choice rides in the **session the sign-up form already needs** for its
  CSRF token, so the test sets no cookie of its own and needs no consent
  banner; it also means a reload keeps showing the same headline instead of
  flickering between the two. Because `Plug.Conn.configure_session(renew:
  true)` rotates the session id but keeps its contents, the variant survives
  both the registration and the PIN round trip, which is what lets the
  confirmation be attributed to the headline that brought the member in.

  Nothing here trusts the client: the variant is read back from the signed
  session, never from a form field, so a hand-crafted POST cannot stuff our
  own statistics.
  """

  import Plug.Conn

  alias Vutuv.Experiments

  @session_key :landing_variant

  @doc """
  Assigns the visitor's variant for the landing-page render, counting one view
  the first time this session sees it (so a reload is not a second view).
  """
  def assign_variant(conn) do
    case variant(conn) do
      nil ->
        variant = Experiments.pick_landing_variant()
        Experiments.record(variant, :views)

        conn
        |> put_session(@session_key, variant)
        |> assign(:landing_variant, variant)

      variant ->
        assign(conn, :landing_variant, variant)
    end
  end

  @doc """
  Assigns the variant for a **re-render** of the landing page (a sign-up that
  came back with errors). Same headline, no second view counted.
  """
  def assign_variant_without_view(conn) do
    assign(conn, :landing_variant, variant(conn) || Experiments.default_landing_variant())
  end

  @doc "This session's variant, or nil when it never saw the landing page."
  def variant(conn) do
    case get_session(conn, @session_key) do
      variant when is_binary(variant) ->
        if Experiments.landing_variant?(variant), do: variant

      _ ->
        nil
    end
  end

  @doc "Counts the sign-up form that just created an account."
  def record_signup(conn) do
    Experiments.record(variant(conn), :signups)
    conn
  end

  @doc """
  Counts the PIN that just turned a fresh registration into a real member, and
  forgets the variant so a later login cannot count a second one.
  """
  def record_confirmation(conn) do
    Experiments.record(variant(conn), :confirmations)
    delete_session(conn, @session_key)
  end
end
