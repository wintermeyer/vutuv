defmodule VutuvWeb.Plug.WelcomeModal do
  @moduledoc """
  Decides whether this request carries the one-time welcome questions
  (`VutuvWeb.WelcomeComponents.welcome_modal/1`, rendered by the app layout).

  Two things must agree, the same pair `VutuvWeb.WelcomeController` demands of
  the POST: the account has never answered or closed the questions
  (`users.welcome_completed_at` is NULL) *and* this session was sent here by a
  confirming **registration** PIN (the `:welcome_pending` session key, set by
  `VutuvWeb.SessionController`). So the modal opens once, over the profile that
  PIN lands on; it survives a reload and follows the member to the next page
  until they answer it or close it — and every later session, on any page, gets
  nothing, because only that one login sets the key.

  Two exclusions. `/system/welcome` renders the same form as a page, and a
  modal on top of it would be a second copy of one form — that is a **typed**
  GET of the URL, since the page a rejected submit lands on is a POST and this
  plug only answers GET at all. And an agent format (`.md`, `.json`, …) is a
  document, not a screen.

  The assign is read by **`root.html.heex`**, which every dead render builds —
  a LiveView page's too, and that is what makes this work: the profile the PIN
  lands on renders its `app` layout from the socket
  (`ControllerHelpers.render_live/3`), so a modal in that layout would never
  reach the one page it exists for. Live navigation inside a `live_session`
  re-runs no pipeline and so never re-asks this plug, which is right: the modal
  sits outside the live root and survives such a patch untouched.
  """

  import Plug.Conn

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias VutuvWeb.Plug.AgentFormat

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if pending?(conn) and not welcome_page?(conn) and not AgentFormat.agent_format?(conn) do
      assign(conn, :welcome_modal, true)
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp pending?(conn) do
    case conn.assigns[:current_user] do
      %User{} = user ->
        get_session(conn, :welcome_pending) == true and Accounts.needs_welcome?(user)

      _other ->
        false
    end
  end

  defp welcome_page?(conn), do: conn.path_info == ["system", "welcome"]
end
