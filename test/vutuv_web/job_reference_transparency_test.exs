defmodule VutuvWeb.JobReferenceTransparencyTest do
  @moduledoc """
  The "How the review works" box under `/settings/job_references`: the one
  place a member is told where their Zeugnis goes.

  Its headline used to read "Your reference stays here.", which answers a
  question about a *place* with the website the reader is already looking at.
  It names the country now, and the point of these tests is that it names it
  from configuration: `:reference_check_country` and
  `:reference_check_hardware` are read by `Vutuv.References.Analyst` and
  rendered by `VutuvWeb.JobReferenceHTML`, so the box stays true on an
  installation whose machines stand somewhere else, or whose operator would
  rather not name their hardware at all.

  **`async: false`**: `Application.put_env/3` is global and the SQL sandbox
  does not roll it back, so holding either key down for the length of a test
  would change what every concurrently running test sees. Nothing else reads
  these two keys.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.Factory

  alias Vutuv.References.Analyst

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    insert(:job_reference, user: user)
    %{conn: conn, user: user}
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

  defp box(conn), do: conn |> get(~p"/settings/job_references") |> html_response(200)

  test "the headline names the configured country", %{conn: conn} do
    put_config(:reference_check_country, "DE")

    html = box(conn)

    assert Analyst.country() == "DE"
    assert html =~ "Your reference stays on our servers in Germany."
  end

  # A third-party installation elsewhere must not inherit our answer.
  test "a different country is the one that gets named", %{conn: conn} do
    put_config(:reference_check_country, "AT")

    html = box(conn)

    assert html =~ "Your reference stays on our servers in Austria."
    refute html =~ "in Germany"
  end

  # With no country configured the promise has to fall back to what is still
  # true everywhere rather than to a place nobody set.
  test "no configured country means no country in the sentence", %{conn: conn} do
    put_config(:reference_check_country, "")

    html = box(conn)

    assert html =~ "Your reference stays on our own servers."
    refute html =~ "on our servers in"
  end

  test "the hardware is named under the headline, and only when configured", %{conn: conn} do
    put_config(:reference_check_hardware, "NVIDIA GPU")
    assert box(conn) =~ "on our own hardware: NVIDIA GPU."

    put_config(:reference_check_hardware, "")
    named = box(conn)

    assert named =~ "It is analysed right here, on our own machines."
    refute named =~ "on our own hardware:"
  end
end
