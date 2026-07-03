defmodule VutuvWeb.ImportControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Ecto.Query

  alias Vutuv.Imports.LinkedIn
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Tags.UserTag

  @sample_files [
    {"Positions.csv",
     "Company Name,Title,Description,Location,Started On,Finished On\nAcme,Engineer,,Berlin,2020,\n"},
    {"Skills.csv", "Name\nElixir\n"}
  ]

  defp zip_binary(files) do
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    binary
  end

  defp upload_zip(files) do
    path = Path.join(System.tmp_dir!(), "linkedin_#{System.unique_integer([:positive])}.zip")
    File.write!(path, zip_binary(files))
    %Plug.Upload{path: path, filename: "export.zip", content_type: "application/zip"}
  end

  test "the upload form renders for the owner", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    html = conn |> get(~p"/settings/import/linkedin") |> html_response(200)
    assert html =~ "linkedin-import-form"
    # The drag-and-drop enhancement wraps the file input in a dropzone, but the
    # input must keep its name so the plain multipart POST still works with JS off.
    assert html =~ "data-dropzone"
    assert html =~ ~s(name="import[archive]")
  end

  test "the page links to LinkedIn's data export page and shows the screenshot", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    html = conn |> get(~p"/settings/import/linkedin") |> html_response(200)
    assert html =~ "https://www.linkedin.com/mypreferences/d/download-my-data"
    assert html =~ "/images/linkedin-download-my-data.webp"
  end

  test "a guest cannot open the import page", %{conn: conn} do
    # /settings is user-agnostic and login-required: the import page always
    # belongs to whoever is signed in, and a guest is turned away.
    conn = get(conn, ~p"/settings/import/linkedin")
    assert redirected_to(conn) == "/"
  end

  test "uploading an archive shows a preview of the candidates", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip(@sample_files)}
      })

    body = html_response(conn, 200)
    assert body =~ "linkedin-import-preview"
    assert body =~ "Acme"
    assert body =~ "Elixir"
    # Each candidate group carries a select-all/deselect-all toggle (JS reveals
    # the button; it starts hidden and the checkboxes work without it).
    assert body =~ "data-select-group"
    assert body =~ "data-select-all"
  end

  test "the uploaded temp file is deleted after parsing", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    upload = upload_zip(@sample_files)

    post(conn, ~p"/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    refute File.exists?(upload.path)
  end

  # The regression behind the "500 on upload" bug report: a CSV re-saved in
  # Excel (Windows-1252/Latin-1) before re-zipping used to crash the preview's
  # Jason.encode! and render the 500 page instead of anything helpful.
  test "an archive with a Latin-1 encoded CSV still previews", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    latin1_csv =
      :unicode.characters_to_binary(
        "Company Name,Title,Description,Location,Started On,Finished On\n" <>
          "Müller GmbH,Geschäftsführer,,Berlin,2020,\n",
        :utf8,
        :latin1
      )

    conn =
      post(conn, ~p"/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip([{"Positions.csv", latin1_csv}])}
      })

    body = html_response(conn, 200)
    assert body =~ "linkedin-import-preview"
    assert body =~ "Müller GmbH"
  end

  test "an oversized upload is rejected with the friendly flash", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    path = Path.join(System.tmp_dir!(), "big_#{System.unique_integer([:positive])}.zip")
    File.write!(path, :binary.copy(<<0>>, 50_000_001))
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "big.zip", content_type: "application/zip"}

    conn =
      post(conn, ~p"/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    assert redirected_to(conn) == ~p"/settings/import/linkedin"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "50 MB"
  end

  test "a non-zip upload is rejected with a flash", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    path = Path.join(System.tmp_dir!(), "notzip_#{System.unique_integer([:positive])}.zip")
    File.write!(path, "this is not a zip")
    upload = %Plug.Upload{path: path, filename: "x.zip", content_type: "application/zip"}

    conn =
      post(conn, ~p"/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    assert redirected_to(conn) == ~p"/settings/import/linkedin"
  end

  test "confirm imports only the checked candidates", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, parsed} = LinkedIn.parse(zip_binary(@sample_files))
    payload = Jason.encode!(LinkedIn.payload_map(parsed))
    position_id = hd(parsed.positions).id

    # Select the position, leave the Elixir skill unchecked.
    conn =
      post(conn, ~p"/settings/import/linkedin/apply", %{
        "payload" => payload,
        "selected" => [position_id]
      })

    assert redirected_to(conn) == ~p"/#{user}"
    assert Repo.get_by(WorkExperience, user_id: user.id, organization: "Acme")

    # The unchecked Elixir skill was not imported; only the three registration
    # tags the account signed up with exist.
    refute Repo.exists?(
             from(ut in UserTag,
               join: t in assoc(ut, :tag),
               where: ut.user_id == ^user.id and t.name == "Elixir"
             )
           )
  end
end
