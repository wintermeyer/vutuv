defmodule VutuvWeb.ImportControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory
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
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/#{user}/settings/import/linkedin")
    assert html_response(conn, 200) =~ "linkedin-import-form"
  end

  test "a member cannot open another member's import page", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    other = insert(:activated_user)
    conn = get(conn, ~p"/#{other}/settings/import/linkedin")
    assert conn.status == 403
  end

  test "uploading an archive shows a preview of the candidates", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/#{user}/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip(@sample_files)}
      })

    body = html_response(conn, 200)
    assert body =~ "linkedin-import-preview"
    assert body =~ "Acme"
    assert body =~ "Elixir"
  end

  test "the uploaded temp file is deleted after parsing", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    upload = upload_zip(@sample_files)

    post(conn, ~p"/#{user}/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    refute File.exists?(upload.path)
  end

  test "a non-zip upload is rejected with a flash", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    path = Path.join(System.tmp_dir!(), "notzip_#{System.unique_integer([:positive])}.zip")
    File.write!(path, "this is not a zip")
    upload = %Plug.Upload{path: path, filename: "x.zip", content_type: "application/zip"}

    conn =
      post(conn, ~p"/#{user}/settings/import/linkedin", %{"import" => %{"archive" => upload}})

    assert redirected_to(conn) == ~p"/#{user}/settings/import/linkedin"
  end

  test "confirm imports only the checked candidates", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, parsed} = LinkedIn.parse(zip_binary(@sample_files))
    payload = Jason.encode!(LinkedIn.payload_map(parsed))
    position_id = hd(parsed.positions).id

    # Select the position, leave the Elixir skill unchecked.
    conn =
      post(conn, ~p"/#{user}/settings/import/linkedin/apply", %{
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
