defmodule Vutuv.Accounts.GravatarImportTest do
  @moduledoc """
  The avatar registration fetches from gravatar.com (issue #1447): that it is
  stored, and that `gravatar_imported_at` is stamped **only** when an image
  really arrived — the stamp is what tells the member about it, so a 404 or a
  failed fetch must leave it NULL and say nothing.

  Not async: sets the global `:uploads_dir_prefix` (so the avatar files land in
  a temp dir instead of the checkout) and `:gravatar_req_options` (the `plug:`
  responder standing in for gravatar.com). Nothing else in the suite reads the
  latter; `:uploads_dir_prefix` is shared with
  `Vutuv.UploadsIntegrationTest`, which is sync for the same reason.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.Factory

  alias Vutuv.Accounts

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_gravatar_#{System.unique_integer([:positive])}")
    prefix = Application.fetch_env(:vutuv, :uploads_dir_prefix)
    options = Application.fetch_env(:vutuv, :gravatar_req_options)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)
      restore(:uploads_dir_prefix, prefix)
      restore(:gravatar_req_options, options)
    end)

    user = insert(:user, emails: [build(:email)])
    {:ok, user: user}
  end

  test "an imported picture becomes the avatar and stamps the import", %{user: user} do
    stub_gravatar(200, png_bytes(), "image/png")

    assert {:ok, imported} = Accounts.store_gravatar(user)
    assert imported.avatar == "#{user.username}.png"
    assert %NaiveDateTime{} = imported.gravatar_imported_at

    assert Repo.reload!(user).gravatar_imported_at == imported.gravatar_imported_at
  end

  # 404 is gravatar's answer for "no picture for this address" (the `d=404`
  # parameter asks for it), and it is the common case. Nothing was imported, so
  # there is nothing to tell the member about.
  test "no picture at gravatar.com leaves the stamp NULL", %{user: user} do
    stub_gravatar(404, "", "text/plain")

    assert Accounts.store_gravatar(user) == nil
    assert Repo.reload!(user).gravatar_imported_at == nil
  end

  test "a failed fetch leaves the stamp NULL", %{user: user} do
    stub_gravatar(500, "", "text/plain")

    assert Accounts.store_gravatar(user) == nil
    assert Repo.reload!(user).gravatar_imported_at == nil
  end

  # `retry: false` only so the 500 case does not sit through Req's default
  # backoff ladder; what the stub proves is the branch taken after the last
  # answer, which the retries do not change. The content type is real
  # (`image/png`), because Req's decode_body step branches on it — a bare
  # send_resp would hand the code a differently shaped body than gravatar does.
  defp stub_gravatar(status, body, content_type) do
    Application.put_env(:vutuv, :gravatar_req_options,
      retry: false,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type(content_type)
        |> Plug.Conn.send_resp(status, body)
      end
    )
  end

  defp png_bytes do
    {:ok, img} = Image.new(120, 120, color: [10, 120, 200])
    path = Path.join(System.tmp_dir!(), "gravatar_#{System.unique_integer([:positive])}.png")
    {:ok, _} = Image.write(img, path)
    File.read!(path)
  end

  defp restore(key, {:ok, was}), do: Application.put_env(:vutuv, key, was)
  defp restore(key, :error), do: Application.delete_env(:vutuv, key)
end
