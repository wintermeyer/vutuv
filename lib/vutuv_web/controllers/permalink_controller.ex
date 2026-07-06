defmodule VutuvWeb.PermalinkController do
  @moduledoc """
  Username-independent profile permalinks (issue #904).

  A member's profile lives at `/:username`, but the username is theirs to change
  at any time, and changing it frees the old name immediately, so every link to
  the old address 404s. `/system/permalinks/users/:user_id` keys on the member's
  UUID v7 id, which never changes, and redirects to their *current* `/:username`,
  so a link built from it stays valid across every rename.

  The redirect is a plain 302 (not a permanent 301) on purpose: the target moves
  whenever the username changes, so it must not be cached as permanent. Lives
  under `/system/` like the member directory, so it does not burn a root path
  word a member could claim as a handle.
  """
  use VutuvWeb, :controller

  alias VutuvWeb.ControllerHelpers

  # A garbage or unknown id is a 404, never an `Ecto.CastError` 500:
  # `ControllerHelpers.get_user/1` casts through `UUIDv7.with_cast/2` and returns
  # nil for a malformed *or* missing id. A deleted or moderation-hidden member
  # resolves here but their `/:username` page enforces its own visibility.
  def user(conn, %{"user_id" => user_id}) do
    case ControllerHelpers.get_user(user_id) do
      nil -> ControllerHelpers.render_error(conn, 404)
      user -> redirect(conn, to: ~p"/#{user}")
    end
  end
end
