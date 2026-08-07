defmodule VutuvWeb.JobReferenceTransparencyTest do
  @moduledoc """
  The "How the review works" box under `/settings/job_references`: the one
  place a member is told where their Zeugnis goes.

  Its headline used to read "Your reference stays here.", which answers a
  question about a *place* with the website the reader is already looking at.
  It names the country now, and the point of these tests is that it names it
  from configuration: `:reference_check_country`, `:reference_check_hardware`,
  `:reference_check_model` and `:reference_check_model_url` are read by
  `Vutuv.References.Analyst` and rendered by `VutuvWeb.JobReferenceHTML`, so
  the box stays true on an installation whose machines stand somewhere else,
  whose operator would rather not name their hardware, or which runs a model
  of its own.

  **`async: false`**: `Application.put_env/3` is global and the SQL sandbox
  does not roll it back, so holding any of those keys down for the length of a
  test would change what every concurrently running test sees. Their only
  other readers are `Vutuv.References.Analyst` (which `:reference_check_model`
  sends to Ollama, so a check running beside this would ask for a model that
  is not there) and `Vutuv.References.AnalystTest`, which is `async: false`
  for the same reason.
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

  # "The model is open source" is a claim a reader can only check by going and
  # looking at the model, so the name is the way there (issue #1318). Named in
  # the sentence and nothing more, it was a string among strings.
  test "the model name is a link to the model's own page", %{conn: conn} do
    put_config(:reference_check_model, "qwen3.6:27b")

    html = box(conn)

    assert Analyst.model_url() == "https://ollama.com/library/qwen3.6:27b"

    # `<.link>` collects the extra attributes into a global map, so they come
    # out sorted rather than in source order — match each on its own.
    assert [anchor] = Regex.run(~r{<a [^>]*data-model-link[^>]*>[^<]*</a>}, html)
    assert anchor =~ ~s(href="https://ollama.com/library/qwen3.6:27b")
    assert anchor =~ ~s(target="_blank")
    assert anchor =~ ~s(rel="noopener")
    assert anchor =~ ">qwen3.6:27b</a>"

    # The sentence is split on a `{model}` marker now, so a translation that
    # kept the old `%{model}` (or lost the marker) prints it as characters.
    assert html =~ "We use <a "
    assert html =~ ", a freely available language model."
    refute html =~ "{model}"
  end

  # An installation whose model has no page anywhere still has to read as a
  # sentence, so the name stays put and only the link goes away.
  test "with no address for the model the name is still named", %{conn: conn} do
    put_config(:reference_check_model, "hausmodell:v1")
    put_config(:reference_check_model_url, "")

    html = box(conn)

    assert html =~ "hausmodell:v1"
    refute html =~ "data-model-link"
  end
end
