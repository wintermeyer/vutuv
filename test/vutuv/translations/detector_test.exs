defmodule Vutuv.Translations.DetectorTest do
  @moduledoc """
  The Ollama language detector (issue #1535): one cheap call that names the
  language of a text nobody declared one for, the sample it sends (a short
  prefix with the markup stripped, never the whole body), and the two error
  classes the sweep branches on. Against a `plug:` stub via
  `:translation_req_options` — the same seam the translator uses, answering
  with a real JSON content-type. `async: false`: the stub key is global
  application env.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Translations.Detector
  alias Vutuv.Translations.Translator

  setup do
    on_exit(fn -> Application.delete_env(:vutuv, :translation_req_options) end)
    :ok
  end

  defp stub(fun), do: Application.put_env(:vutuv, :translation_req_options, plug: fun)

  defp answer(conn, payload) do
    body = %{"message" => %{"role" => "assistant", "content" => Jason.encode!(payload)}}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp answering(language) do
    parent = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, Jason.decode!(raw)})
      answer(conn, %{"language" => language})
    end)
  end

  test "names the language in one call" do
    answering("de")
    post = insert(:post, body: "Guten Morgen allerseits, heute wird es sonnig.")

    assert {:ok, "de"} = Detector.detect(post)

    assert_receive {:request, request}
    assert request["format"]["required"] == ["language"]
    assert request["options"]["temperature"] == 0
    assert hd(request["messages"])["content"] =~ "Guten Morgen allerseits"
    # One call per row, and no translation is asked for.
    refute_receive {:request, _}, 50
  end

  test "normalizes a regional tag to the primary subtag we store" do
    answering("de-AT")

    assert {:ok, "de"} =
             Detector.detect(insert(:post, body: "Ein Satz auf gutem Österreichisch."))
  end

  test "sends a short sample, not the whole body" do
    answering("de")
    long = String.duplicate("Ein ordentlich langer deutscher Satz. ", 200)

    assert {:ok, "de"} = Detector.detect(insert(:post, body: long))

    assert_receive {:request, request}
    prompt = hd(request["messages"])["content"]
    assert String.length(prompt) < String.length(long)
  end

  test "markup is stripped from the sample, so a link post is not mistaken for English" do
    answering("de")

    post =
      insert(:post,
        body: """
        Guten Morgen! Sieh dir https://example.com/some/english-looking/path an, @kollege.

        ```elixir
        IO.puts("hello world")
        ```

        ~~~python
        print("tilde fenced code")
        ~~~
        """
      )

    assert {:ok, "de"} = Detector.detect(post)

    assert_receive {:request, request}
    prompt = hd(request["messages"])["content"]
    refute prompt =~ "english-looking"
    refute prompt =~ "IO.puts"
    refute prompt =~ "tilde fenced code"
  end

  test "asks for the translator's own context size, or Ollama reloads the model" do
    answering("de")

    assert {:ok, "de"} = Detector.detect(insert(:post, body: "Ein ganz gewöhnlicher Satz hier."))

    assert_receive {:request, request}
    assert request["options"]["num_ctx"] == Translator.num_ctx()
    assert request["model"] == Translator.model()
  end

  test "a text with nothing to go on never reaches the model" do
    stub(fn _conn -> raise "the model must not be called" end)

    assert {:error, {:content, :no_sample}} =
             Detector.detect(insert(:post, body: "https://a.example"))
  end

  test "an honest \"could not tell\" is a content error, so the row is stamped and left NULL" do
    answering("und")

    assert {:error, {:content, :undetermined}} =
             Detector.detect(insert(:post, body: "Lorem ipsum dolor sit amet, consetetur."))
  end

  test "a garbage tag is undetermined too, never a stored language" do
    answering("definitely not a tag")

    assert {:error, {:content, :undetermined}} =
             Detector.detect(insert(:post, body: "Ein ganz gewöhnlicher deutscher Satz."))
  end

  test "an unknown language is undetermined — the chips only offer curated codes" do
    answering("xx")

    assert {:error, {:content, :undetermined}} =
             Detector.detect(insert(:post, body: "Ein ganz gewöhnlicher deutscher Satz."))
  end

  test "an HTTP failure is a service error — the sweep pauses instead of stamping" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, {:service, _reason}} =
             Detector.detect(insert(:post, body: "Ein ganz gewöhnlicher deutscher Satz."))
  end
end
