defmodule VutuvWeb.Plug.PendingFlash do
  @moduledoc """
  Carries a flash across a response that cannot carry one itself.

  `Phoenix.Controller.fetch_flash/2` persists the flash into the session **only**
  while `conn.status in 300..308`; on any other status its `before_send`
  callback deletes it instead. So an action that answers **JSON** and lets the
  browser navigate afterwards silently loses whatever it flashed. Both passkey
  ceremonies work that way (`assets/js/webauthn.js` drives them with `fetch()`
  and then sets `window.location`), which is why the passkey login's "Welcome
  back" greeting never once appeared on screen.

  Such an action calls `put_pending_flash/3` instead of `put_flash/3`. The
  message rides in the session, and this plug — wired into the `:browser`
  pipeline right after `fetch_flash` — pops it on the next request and flashes
  it there, where an ordinary HTML response renders it as the usual toast.

  It only ever *adds* to the flash, so a request that sets its own is untouched.

  One deliberate limitation: it fires on the **next** request through the
  `:browser` pipeline, which is normally the page the JS navigates to but could
  in principle be a background `fetch()` from the page the member is leaving
  (that request would consume the message and drop it). Both current callers
  navigate immediately, so the race is theoretical; if a flow ever needs a hard
  guarantee, hand the message to the client and let it render, rather than
  making this plug guess which response will be HTML.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3]

  @session_key :pending_flash

  # Only the kinds the toast tray renders; anything else would style as nothing.
  @kinds ~w(info error)

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      %{"kind" => kind, "message" => message} when kind in @kinds and is_binary(message) ->
        conn
        |> delete_session(@session_key)
        |> put_flash(String.to_existing_atom(kind), message)

      nil ->
        conn

      # Anything else is a leftover from an older shape; drop it rather than
      # raise on a member's next page load.
      _ ->
        delete_session(conn, @session_key)
    end
  end

  @doc """
  Stashes `message` to be flashed on the member's next page.

  Use it in place of `put_flash/3` in an action whose response is **not** a
  redirect — a JSON answer the browser navigates away from. `kind` is `:info` or
  `:error`, matching the toast tray.
  """
  def put_pending_flash(conn, kind, message)
      when kind in [:info, :error] and is_binary(message) do
    put_session(conn, @session_key, %{"kind" => Atom.to_string(kind), "message" => message})
  end
end
