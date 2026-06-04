defmodule VutuvWeb.Plug.All404 do
  @moduledoc false

  def init(opts) do
    opts
  end

  def call(conn, _) do
    VutuvWeb.ControllerHelpers.render_error(conn, 404)
  end
end
