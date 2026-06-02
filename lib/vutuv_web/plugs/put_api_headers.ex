defmodule VutuvWeb.Plug.PutAPIHeaders do
  @moduledoc false

  def init(opts) do
    opts
  end

  def call(conn, _default) do
    # put standard api headers here
    conn
  end
end
