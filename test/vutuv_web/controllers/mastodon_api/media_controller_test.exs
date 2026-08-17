defmodule VutuvWeb.MastodonApi.MediaControllerTest do
  @moduledoc """
  Photo upload through a Mastodon client.

  `async: false` because the whole module redirects `:uploads_dir_prefix` at the
  application level so nothing is written into the checkout, and that key is
  read by every uploader in the app, not only by the one under test.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo

  setup do
    Vutuv.RateLimiter.reset()

    tmp =
      Path.join(System.tmp_dir!(), "vutuv_mastodon_media_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original_uploads = Application.fetch_env(:vutuv, :uploads_dir_prefix)
    original_verification = Application.fetch_env(:vutuv, :verify_organization_domains)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      File.rm_rf(tmp)
      restore(:uploads_dir_prefix, original_uploads)
      restore(:verify_organization_domains, original_verification)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    {:ok, tmp: tmp}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:vutuv, key, value)
  defp restore(key, :error), do: Application.delete_env(:vutuv, key)

  defp jpeg!(tmp) do
    src = Path.join(tmp, "src-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(64, 64, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)
    %Plug.Upload{path: src, filename: "photo.jpg", content_type: "image/jpeg"}
  end

  defp release!(image_id) do
    PostImage
    |> Repo.get!(image_id)
    |> Ecto.Changeset.change(moderation: "approved")
    |> Repo.update!()
  end

  test "upload, describe and attach a photo to a status", %{conn: conn, tmp: tmp} do
    user = insert(:activated_user)
    token = mastodon_token(user, ["read", "write"])

    uploaded =
      conn
      |> mastodon_conn(token)
      |> post("/api/v1/media", %{"file" => jpeg!(tmp), "description" => "Ein grünes Feld"})
      |> json_response(200)

    assert uploaded["type"] == "image"
    assert uploaded["description"] == "Ein grünes Feld"

    status =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/statuses", %{"status" => "Mit Bild", "media_ids" => [uploaded["id"]]})
      |> json_response(200)

    stored = Posts.get_post(status["id"])
    assert [%PostImage{alt: "Ein grünes Feld"}] = stored.images
  end

  # The scan is what v2's 202 exists for here: nothing is publishable until the
  # picture is released, so the client is told to wait instead of posting into
  # a post only its author can see.
  #
  # This is the one test that switches `:moderate_images` **on** — the suite
  # runs with it off, so every other upload is released the moment it is
  # stored, which is also why v2 correctly answers a plain 200 elsewhere. The
  # key is read by `Vutuv.Moderation.ImageScans.enabled?/0` and
  # `initial_state/0`, i.e. by every upload path in the app, which is why this
  # module is `async: false` and why the flag is put back straight away.
  test "v2 answers 202 without a url and the poll flips to 200 once released", %{
    conn: conn,
    tmp: tmp
  } do
    original_moderation = Application.fetch_env(:vutuv, :moderate_images)
    Application.put_env(:vutuv, :moderate_images, true)
    on_exit(fn -> restore(:moderate_images, original_moderation) end)

    user = insert(:activated_user)
    token = mastodon_token(user, ["write:media"])

    pending =
      conn
      |> mastodon_conn(token)
      |> post("/api/v2/media", %{"file" => jpeg!(tmp)})
      |> json_response(202)

    assert pending["url"] == nil

    polled =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/media/#{pending["id"]}")

    assert polled.status == 206
    assert json_response(polled, 206)["url"] == nil

    release!(pending["id"])

    ready =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/media/#{pending["id"]}")
      |> json_response(200)

    assert is_binary(ready["url"])
  end

  test "the description can be set after the upload", %{conn: conn, tmp: tmp} do
    user = insert(:activated_user)
    token = mastodon_token(user, ["write:media"])

    uploaded = conn |> mastodon_conn(token) |> post("/api/v1/media", %{"file" => jpeg!(tmp)})
    id = json_response(uploaded, 200)["id"]

    updated =
      build_conn()
      |> mastodon_conn(token)
      |> put("/api/v1/media/#{id}", %{"description" => "Nachgereicht"})
      |> json_response(200)

    assert updated["description"] == "Nachgereicht"
    assert Repo.get!(PostImage, id).alt == "Nachgereicht"
  end

  test "somebody else's upload is neither readable nor attachable", %{conn: conn, tmp: tmp} do
    owner = insert(:activated_user)
    stranger = insert(:activated_user)
    {:ok, image} = Posts.create_pending_image(owner, jpeg!(tmp).path, "photo.jpg")
    token = mastodon_token(stranger, ["read", "write"])

    assert conn |> mastodon_conn(token) |> get("/api/v1/media/#{image.id}") |> response(404)

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/statuses", %{"status" => "Geklaut", "media_ids" => [image.id]})
           |> response(422)

    assert Repo.get!(PostImage, image.id).post_id == nil
  end

  test "a token without the media scope cannot upload", %{conn: conn, tmp: tmp} do
    user = insert(:activated_user)
    token = mastodon_token(user, ["read"])

    assert conn
           |> mastodon_conn(token)
           |> post("/api/v1/media", %{"file" => jpeg!(tmp)})
           |> response(403)
  end

  # Also the regression test for the data layer: an organization post has no
  # `user_id`, so attaching its pictures used to compare `i.user_id` with nil,
  # which Ecto refuses outright. Calibrated against the un-fixed code, where
  # this raises rather than failing an assertion.
  test "a publisher posts a photo in the organization's name", %{conn: conn, tmp: tmp} do
    member = insert(:activated_user)
    organization = active_organization_for(member)
    {:ok, _} = Organizations.add_role(organization, member, "publisher", member)
    token = mastodon_token(member, ["read", "write"], organization)

    uploaded =
      conn
      |> mastodon_conn(token)
      |> post("/api/v1/media", %{"file" => jpeg!(tmp)})
      |> json_response(200)

    status =
      build_conn()
      |> mastodon_conn(token)
      |> post("/api/v1/statuses", %{"status" => "Seitenbild", "media_ids" => [uploaded["id"]]})
      |> json_response(200)

    stored = Posts.get_post(status["id"])
    assert stored.organization_id == organization.id
    assert stored.acting_user_id == member.id
    assert [%PostImage{id: image_id}] = stored.images
    assert image_id == uploaded["id"]
  end
end
