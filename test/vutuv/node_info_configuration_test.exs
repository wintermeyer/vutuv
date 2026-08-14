defmodule Vutuv.NodeInfoConfigurationTest do
  @moduledoc """
  How another installation names and describes itself in NodeInfo (issue #1448).

  `async: false`, in a file of its own: this flips `:vutuv, :node_name`,
  `:node_description` and `:data_location`, and `Application.put_env/3` is
  global — the SQL sandbox does not roll it back. The first two are read only by
  `Vutuv.NodeInfo.document/1`, but **`:data_location` is also read by
  `VutuvWeb.PageHTML.data_location/0`**, i.e. by the start page's "Where your
  data lives" card, so anything asserting on that card must stay sync too.
  `VutuvWeb.WellKnownControllerTest` asserts on the configured values through
  the document, which is exactly the test that went red when this lived in the
  async module beside it.
  """

  use Vutuv.DataCase, async: false

  alias Vutuv.NodeInfo

  defp description, do: NodeInfo.document("2.1")["metadata"]["nodeDescription"]

  test "nodeName and nodeDescription come from config, never from a literal" do
    put_config(:node_name, "Beispiel")
    put_config(:node_description, "Ein Intranet.")

    metadata = NodeInfo.document("2.1")["metadata"]

    assert metadata["nodeName"] == "Beispiel"
    assert metadata["nodeDescription"] =~ "Ein Intranet."
  end

  describe "the hosting claim" do
    test "names the operator's own data location" do
      put_config(:node_description, "Ein Intranet.")
      put_config(:data_location, "Österreich")

      assert description() == "Ein Intranet. Hosted on our own hardware in Österreich."
    end

    test "is dropped entirely by an operator who cleared the location" do
      # What an operator on rented cloud infrastructure does — the start page's
      # hosting card disappears for them too, and this claim must go the same
      # way rather than being published in their name.
      put_config(:node_description, "Ein Intranet.")
      put_config(:data_location, "")

      assert description() == "Ein Intranet."
      refute description() =~ "own hardware"
    end

    test "is dropped when the key is absent altogether" do
      put_config(:node_description, "Ein Intranet.")
      Application.delete_env(:vutuv, :data_location)
      on_exit(fn -> Application.put_env(:vutuv, :data_location, "Deutschland") end)

      assert description() == "Ein Intranet."
    end
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
