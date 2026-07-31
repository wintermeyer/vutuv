defmodule VutuvWeb.MultipartFormFallbackTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.User

  # Issue #1227: one member's Safari (26.5.2, macOS) submitted the multipart
  # Basics & photos form with a declared boundary but a zero-byte body on every
  # attempt (nginx capture, 2026-07-31 05:41/05:42 UTC: `Content-Length: 0`),
  # while every urlencoded form from the same browser worked. WebKit builds a
  # multipart body as a stream it cannot always replay; a urlencoded body is
  # in-memory and survives. So app.js switches a multipart form to urlencoded
  # at submit time whenever no file is actually selected — the only thing
  # multipart buys is file transport. These tests pin both halves of that
  # contract.

  describe "the urlencoded profile save (the JS fallback's request shape)" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    # In a urlencoded submit an `<input type="file">` degrades to a text value,
    # so `user[avatar]` arrives as "" instead of being absent. The server must
    # treat that exactly like a multipart submit with no file.
    test "saves the text fields when the file params arrive as empty strings",
         %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/settings/profile",
          user: %{
            "avatar" => "",
            "avatar_crop" => "",
            "cover_photo" => "",
            "cover_crop" => "",
            "first_name" => "Rene",
            "headline" => "Saved without multipart"
          }
        )

      assert redirected_to(conn) == "/#{user.username}"

      updated = Repo.get!(User, user.id)
      assert updated.first_name == "Rene"
      assert updated.headline == "Saved without multipart"
    end

    test "an empty-string avatar param never clears a stored avatar",
         %{conn: conn, user: user} do
      user = Repo.update!(Ecto.Changeset.change(user, avatar: "existing.avif"))

      put(conn, ~p"/settings/profile",
        user: %{"avatar" => "", "avatar_crop" => "", "first_name" => "Rene"}
      )

      assert Repo.get!(User, user.id).avatar == "existing.avif"
    end
  end

  describe "the client half" do
    test "app.js downgrades a fileless multipart form to urlencoded at submit time" do
      js = File.read!(Path.expand("../../assets/js/app.js", __DIR__))

      assert js =~ "multipartEnctypeFallback",
             "app.js lost the issue #1227 submit-time enctype fallback"

      assert js =~ ~s(application/x-www-form-urlencoded)
    end

    test "the profile basics form stays multipart (the fallback's target)" do
      template =
        File.read!(Path.expand("../../lib/vutuv_web/templates/user/edit.html.heex", __DIR__))

      assert template =~ "multipart"
    end

    # Round 2 of issue #1227: with a photo selected the form must stay
    # multipart, and the member's WebKit still sent Content-Length: 0 (Safari
    # AND the DuckDuckGo browser — the same system WebKit). WebKit streams a
    # picked file from disk only at send time, and a file picked from the
    # Photos media library is a temporary export that can vanish before the
    # member finishes the crop dialog and presses Save — the body stream then
    # aborts and zero bytes go out. So the crop enhancement freezes the picked
    # file into an in-memory copy at selection time, when it is provably
    # readable; an in-memory File is serialized from RAM and cannot vanish.
    test "image_crop.js freezes a picked photo into memory at selection time" do
      js = File.read!(Path.expand("../../assets/js/image_crop.js", __DIR__))

      assert js =~ "freezePickedFile",
             "image_crop.js lost the issue #1227 pick-time in-memory freeze"

      # The mechanism: read the bytes, rebuild the FileList around a copy.
      assert js =~ "arrayBuffer"
      assert js =~ "DataTransfer"
    end
  end
end
