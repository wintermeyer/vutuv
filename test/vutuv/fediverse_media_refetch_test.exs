defmodule Vutuv.FediverseMediaRefetchTest do
  @moduledoc """
  The second try at a picture whose download never landed (issue #1803).

  `Media.fetch_async/1` is fire-and-forget, so whatever made the first attempt
  miss — a deploy killing the task, a blip, a server having a bad minute — was
  permanent: the row kept `file IS NULL` for ever and the card went on
  promising a check that could never run, because `ImageScans.repair_drift/0`
  deliberately skips a row with no bytes to judge. Thirteen pictures were in
  that state on production when this was written, the oldest since 2026-08-03,
  and every one of their source URLs answered `200` when asked again — twelve
  with a real image, the thirteenth with a video its own server declares as
  one.

  `async: false` — the HTTP stub lives in the application env, which the SQL
  sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse.Media
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost

  @actor "https://social.example/users/them"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp jpeg_bytes do
    {:ok, image} = Image.new(64, 64, color: [40, 90, 160])
    {:ok, bytes} = Image.write(image, :memory, suffix: ".jpg")
    bytes
  end

  defp stub_download(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp serving(status, bytes, type \\ "image/jpeg") do
    stub_download(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(status, bytes)
    end)
  end

  # Old enough that the sweeper no longer takes it for an attempt still in
  # flight. A row is only due once its first fetch has had time to finish.
  defp waiting_picture(attrs \\ []) do
    now = DateTime.utc_now(:second)
    settled = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600, :second)

    actor = "#{@actor}#{System.unique_integer([:positive])}"

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: actor,
        host: "social.example",
        handle: "them",
        inbox_uri: actor <> "/inbox"
      })

    post =
      Repo.insert!(%RemotePost{
        remote_account_id: account.id,
        object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
        content_text: "Mit Bild.",
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400)
      })

    Repo.insert!(
      struct(
        %RemoteImage{
          remote_post_id: post.id,
          source_uri: "https://social.example/media/#{System.unique_integer([:positive])}.jpg",
          moderation: "pending",
          file: nil,
          inserted_at: settled
        },
        attrs
      )
    )
  end

  defp reload(image), do: Repo.get!(RemoteImage, image.id)

  defp due_ids, do: Enum.map(Media.due_refetches(), & &1.id)

  describe "which pictures are due" do
    test "one whose bytes never arrived is" do
      image = waiting_picture()

      assert image.id in due_ids()
    end

    test "one that has its bytes is not" do
      image = waiting_picture(file: "img-abc.avif")

      refute image.id in due_ids()
    end

    test "one that has run out of tries is not" do
      image = waiting_picture(fetch_failures: RemoteImage.max_fetch_failures())

      refute image.id in due_ids()
    end

    test "one the gate refused is not, however it was spelled" do
      # The bytes were looked at and turned down, so asking for them again is
      # the one thing we must not do. `nil` is what the refusal wrote before it
      # learned the word.
      refused = waiting_picture(moderation: "rejected")
      legacy = waiting_picture(moderation: nil)

      refute refused.id in due_ids()
      refute legacy.id in due_ids()
    end

    test "one on an installation with no vision model is" do
      # `ImageScans.initial_state/0` answers "approved" when image moderation is
      # off, so a picture there is born approved and its failed download carries
      # that word. Keying the queue on "pending" left every such installation
      # with the bug this fixes.
      image = waiting_picture(moderation: "approved")

      assert image.id in due_ids()
    end

    test "one whose first download is still running is not" do
      # `fetch_now/1` stamps the clock itself, so a null there means either an
      # attempt that died with its slot or one still in flight. Only the row's
      # own age tells them apart.
      image =
        waiting_picture(inserted_at: NaiveDateTime.utc_now(:second), fetch_attempted_at: nil)

      refute image.id in due_ids()
    end

    test "one tried a moment ago waits for its backoff" do
      image = waiting_picture(fetch_attempted_at: DateTime.utc_now(:second), fetch_failures: 1)

      refute image.id in due_ids()
    end
  end

  describe "one pass over the due batch" do
    test "a picture that answers this time is stored and leaves the queue" do
      serving(200, jpeg_bytes())
      image = waiting_picture()

      assert Media.refetch_due() == 1

      stored = reload(image)
      assert stored.file =~ ~r/^img-/
      refute stored.id in due_ids()
    end

    test "a server still refusing takes a strike and is tried again later" do
      serving(503, "nope")
      image = waiting_picture()

      assert Media.refetch_due() == 1

      struck = reload(image)
      assert struck.fetch_failures == 1
      assert struck.fetch_attempted_at
      # Still on the ladder — a bad minute is not a verdict — but not due again
      # until its backoff has run. The gate's own column is untouched: this is
      # not the gate.
      assert struck.moderation == "pending"
      refute RemoteImage.unavailable?(struck)
      refute struck.id in due_ids()
    end

    test "the last strike gives up, and the card can say so" do
      serving(503, "nope")
      image = waiting_picture(fetch_failures: RemoteImage.max_fetch_failures() - 1)

      assert Media.refetch_due() == 1

      given_up = reload(image)
      assert RemoteImage.unavailable?(given_up)
      # Said by the fetch state, not by the verdict column: the gate never saw
      # this picture and has no opinion to record.
      assert given_up.moderation == "pending"
      refute given_up.id in due_ids()
    end

    test "a body that is not a picture gives up at once" do
      # The `bizzfed.de` row on production: an `.mp4` its server declared as an
      # image. Five more tries would fetch the same five megabytes of video.
      serving(200, "not an image at all", "video/mp4")
      image = waiting_picture()

      assert Media.refetch_due() == 1

      given_up = reload(image)
      assert RemoteImage.unavailable?(given_up)
      assert given_up.fetch_failures == RemoteImage.max_fetch_failures()
      refute given_up.id in due_ids()
    end

    test "a picture whose post has gone leaves the queue without a request" do
      image = waiting_picture()
      Repo.delete!(Repo.get!(RemotePost, image.remote_post_id))

      assert Media.refetch_due() == 0
      assert due_ids() == []
    end
  end

  describe "the sweeper's own clock" do
    test "an unworkable picture is not returned by the due query after one pass" do
      # The deadlock shape of #1316: a row the sweeper can never finish holds
      # the front of every batch for ever, because the ordering is oldest-first
      # and nothing about it changes. The clock has to move on every outcome,
      # not only on the ones that did some work.
      serving(503, "nope")
      images = for _ <- 1..3, do: waiting_picture()

      assert Media.refetch_due() == 3
      assert due_ids() == []

      for image <- images, do: assert(reload(image).fetch_attempted_at)
    end
  end
end
