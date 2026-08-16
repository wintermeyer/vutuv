defmodule Vutuv.Translations.TranslatorTest do
  @moduledoc """
  The Ollama translation client (issue #1457): one call that translates and
  reports the source language, the Markdown/plain-text prompt split, the
  plausibility gate that strikes instead of storing junk, and the two error
  classes the worker depends on. All against a `plug:` stub via
  `:translation_req_options` (answering with a real JSON content-type) — no
  live Ollama. `async: false`: the stub key is global application env.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse.RemotePost
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

  defp post!(body), do: insert(:post, body: body)

  defp remote!(attrs) do
    account =
      Repo.insert!(%Vutuv.Fediverse.RemoteAccount{
        actor_uri: "https://social.example/users/u#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        inbox_uri: "https://social.example/inbox"
      })

    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct!(
        %RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  test "translates a Markdown post in one call and reports the source language" do
    parent = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, Jason.decode!(raw)})
      answer(conn, %{"source_language" => "de", "body" => "Good **morning** everyone."})
    end)

    post = post!("Guten **Morgen** allerseits.")

    assert {:ok, result} = Translator.translate(post, "en")
    assert result.body == "Good **morning** everyone."
    assert result.source_language == "de"
    assert result.summary == nil
    assert is_binary(result.model)

    assert_receive {:request, request}
    prompt = hd(request["messages"])["content"]
    assert prompt =~ "Markdown"
    assert prompt =~ "Guten **Morgen** allerseits."
    assert request["options"]["temperature"] == 0
    assert request["options"]["num_ctx"] >= 16_384
    # One call, no separate detection request.
    refute_receive {:request, _}, 50
  end

  test "remote content translates as plain text, content warning included" do
    parent = self()

    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, Jason.decode!(raw)})

      answer(conn, %{
        "source_language" => "fr",
        "body" => "Hello everyone.",
        "summary" => "CW: politics"
      })
    end)

    remote = remote!(%{content_text: "Bonjour tout le monde.", summary: "CW: politique"})

    assert {:ok, result} = Translator.translate(remote, "en")
    assert result.summary == "CW: politics"
    assert result.source_language == "fr"

    assert_receive {:request, request}
    prompt = hd(request["messages"])["content"]
    assert prompt =~ "plain text"
    assert prompt =~ "CW: politique"
    assert request["format"]["required"] == ["source_language", "body", "summary"]
  end

  test "a garbage source-language tag stores as \"und\", never on the wire" do
    stub(fn conn ->
      answer(conn, %{"source_language" => "definitely not a tag", "body" => "Fine text here."})
    end)

    assert {:ok, %{source_language: "und"}} = Translator.translate(post!("Ein Text hier."), "en")
  end

  test "an empty answer is a content strike, not a stored translation" do
    stub(fn conn -> answer(conn, %{"source_language" => "de", "body" => "   "}) end)

    assert {:error, {:content, :empty}} = Translator.translate(post!("Guten Morgen."), "en")
  end

  test "an absurd length ratio is a content strike" do
    stub(fn conn -> answer(conn, %{"source_language" => "de", "body" => "Hi."}) end)

    long = String.duplicate("Ein ordentlich langer deutscher Satz. ", 20)
    assert {:error, {:content, :length_ratio}} = Translator.translate(post!(long), "en")
  end

  test "a translated code fence is a content strike" do
    source = """
    Schau dir das an:

    ```elixir
    IO.puts("Hallo")
    ```
    """

    translated = """
    Look at this:

    ```elixir
    IO.puts("Hello")
    ```
    """

    stub(fn conn -> answer(conn, %{"source_language" => "de", "body" => translated}) end)

    assert {:error, {:content, :fence_changed}} = Translator.translate(post!(source), "en")
  end

  test "an intact code fence passes the gate" do
    source = """
    Schau dir das an:

    ```elixir
    IO.puts("Hallo")
    ```
    """

    translated = """
    Look at this:

    ```elixir
    IO.puts("Hallo")
    ```
    """

    stub(fn conn -> answer(conn, %{"source_language" => "de", "body" => translated}) end)

    assert {:ok, %{body: ^translated}} = Translator.translate(post!(source), "en")
  end

  test "non-JSON content in the answer is a content strike" do
    stub(fn conn ->
      body = %{"message" => %{"role" => "assistant", "content" => "no json at all"}}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    assert {:error, {:content, :bad_answer}} = Translator.translate(post!("Guten Morgen."), "en")
  end

  test "an HTTP failure is a service error — the text is fine" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, {:service, _reason}} = Translator.translate(post!("Guten Morgen."), "en")
  end
end
