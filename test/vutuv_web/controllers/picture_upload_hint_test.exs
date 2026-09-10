defmodule VutuvWeb.PictureUploadHintTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Uploads
  alias VutuvWeb.UI

  # What /settings/profile promises about a picture, and what it says when it
  # refuses one. The avatar was the strictest upload on the site and said so
  # nowhere: the picker offered every image the phone held, the server took two
  # formats, and the refusal ("is not a valid image", in English on a German
  # page) named neither the formats nor the cap. Directly under it sat the
  # "Fetch my picture from gravatar.com" button, so the dead end read as "you
  # need a Gravatar account to have a picture here" — which is how it was
  # reported.

  # A refused avatar upload, rendered in German: the msgids live in
  # Vutuv.Accounts.User, so only a rendered page proves the errors.po anchors in
  # VutuvWeb.ErrorHelpers are in place.
  defp refuse_avatar(conn, user, contents) do
    src = Path.join(System.tmp_dir!(), "refused_#{System.unique_integer([:positive])}.jpg")
    File.write!(src, contents)
    on_exit(fn -> File.rm(src) end)

    conn
    |> recycle()
    |> put_req_header("accept-language", "de-DE,de;q=0.9")
    |> put(~p"/settings/profile", %{
      "user" => %{
        "first_name" => user.first_name,
        "avatar" => %Plug.Upload{filename: "refused.jpg", path: src, content_type: "image/jpeg"}
      }
    })
    |> html_response(422)
  end

  test "the form offers what the server takes, and says so before a file is picked", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings/profile") |> html_response(200)
    accept = Enum.join(Uploads.extension_whitelist(), ",")

    for field <- ~w(user_avatar user_cover_photo) do
      assert [tag] = Regex.run(~r/<input[^>]*id="#{field}"[^>]*>/, html)

      assert tag =~ ~s(accept="#{accept}"),
             "#{field} must offer the whitelist, not image/*: #{tag}"
    end

    hint =
      "#{UI.format_list(Uploads.extension_whitelist())}, up to " <>
        UI.megabyte_label(Uploads.max_filesize())

    assert html |> String.split(hint) |> length() == 3, "expected the hint under both fields"
  end

  test "an unreadable file is refused in German, naming the formats", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    html = refuse_avatar(conn, user, "kein Bild")

    assert html =~ "Diese Datei können wir nicht lesen."
    assert html =~ UI.format_list(Uploads.extension_whitelist())
  end

  test "a file over the cap is refused in German, naming the cap", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    html = refuse_avatar(conn, user, :binary.copy("x", Uploads.max_filesize() + 1))

    assert html =~ "Diese Datei ist größer als #{UI.megabyte_label(Uploads.max_filesize())}."
  end
end
