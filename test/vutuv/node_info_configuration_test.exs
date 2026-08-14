defmodule Vutuv.NodeInfoConfigurationTest do
  @moduledoc """
  How another installation names itself in NodeInfo (issue #1448).

  `async: false`, in a file of its own: this flips `:vutuv, :node_name` and
  `:node_description`, and `Application.put_env/3` is global — the SQL sandbox
  does not roll it back. `Vutuv.NodeInfo.document/1` is the only reader of
  either key, and `VutuvWeb.WellKnownControllerTest` asserts on the configured
  values through it, which is exactly the test that went red when this lived in
  the async module beside it.
  """

  use Vutuv.DataCase, async: false

  alias Vutuv.NodeInfo

  test "nodeName and nodeDescription come from config, never from a literal" do
    put_config(:node_name, "Beispiel")
    put_config(:node_description, "Ein Intranet.")

    metadata = NodeInfo.document("2.1")["metadata"]

    assert metadata["nodeName"] == "Beispiel"
    assert metadata["nodeDescription"] == "Ein Intranet."
  end

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end
end
