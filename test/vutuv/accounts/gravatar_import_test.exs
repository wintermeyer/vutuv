defmodule Vutuv.Accounts.GravatarImportTest do
  @moduledoc """
  The gravatar.com avatar import (issue #1447), which is now a thing a member
  asks for and never something registration does behind their back.

  Two claims are worth a test each. That the import works and stores the
  picture, and that each failure is told apart from the others — "gravatar.com
  has nothing for your address" and "gravatar.com did not answer" are different
  news for the member, so the function must not collapse them into one error.

  Not async: sets the global `:uploads_dir_prefix` (so the avatar files land in
  a temp dir instead of the checkout) and `:gravatar_req_options` (the `plug:`
  responder standing in for gravatar.com). Nothing else in the suite reads the
  latter; `:uploads_dir_prefix` is shared with `Vutuv.UploadsIntegrationTest`,
  which is sync for the same reason.
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

    {:ok, user: insert(:user, emails: [build(:email)])}
  end

  test "an imported picture becomes the avatar", %{user: user} do
    stub_gravatar(200, png_bytes(), "image/png")

    assert {:ok, imported} = Accounts.import_gravatar_avatar(user)
    assert imported.avatar == "#{user.username}.png"
    assert Repo.reload!(user).avatar == imported.avatar
  end

  # 404 is gravatar's answer for "no picture for this address" (the `d=404`
  # parameter asks for it), and it is by far the common case.
  test "no picture there is :not_found, and the avatar is untouched", %{user: user} do
    stub_gravatar(404, "", "text/plain")

    assert Accounts.import_gravatar_avatar(user) == {:error, :not_found}
    assert Repo.reload!(user).avatar == nil
  end

  test "an unreachable gravatar.com is :unavailable, not :not_found", %{user: user} do
    stub_gravatar(500, "", "text/plain")

    assert Accounts.import_gravatar_avatar(user) == {:error, :unavailable}
    assert Repo.reload!(user).avatar == nil
  end

  # A member with no address at all cannot be looked up; that must answer, not
  # raise (the old code took `hd/1` of the list).
  test "a member without an email address is :not_found" do
    assert Accounts.import_gravatar_avatar(insert(:user)) == {:error, :not_found}
  end

  defp stub_gravatar(status, body, content_type) do
    Application.put_env(:vutuv, :gravatar_req_options,
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
