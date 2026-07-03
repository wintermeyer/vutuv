defmodule VutuvWeb.ImportRateLimitTest do
  @moduledoc """
  The LinkedIn import is throttled per member (and per IP). Enabling the limiter
  mutates global config, so this runs non-async with a reset + restore, like the
  other rate-limit tests.
  """
  use VutuvWeb.ConnCase, async: false

  setup do
    Vutuv.RateLimiter.reset()
    prev_rate_limit = Application.get_env(:vutuv, :rate_limit)
    prev_import = Application.get_env(:vutuv, :linkedin_import_rate_limit)
    Application.put_env(:vutuv, :rate_limit, enabled: true)
    Application.put_env(:vutuv, :linkedin_import_rate_limit, {2, 60_000})

    on_exit(fn ->
      Application.put_env(:vutuv, :rate_limit, prev_rate_limit)
      Application.put_env(:vutuv, :linkedin_import_rate_limit, prev_import)
    end)

    :ok
  end

  defp upload_zip do
    entries = [{~c"Skills.csv", "Name\nElixir\n"}]
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    path = Path.join(System.tmp_dir!(), "li_rl_#{System.unique_integer([:positive])}.zip")
    File.write!(path, binary)
    %Plug.Upload{path: path, filename: "export.zip", content_type: "application/zip"}
  end

  test "throttles a member's repeated imports", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # The first two uploads render the preview; the third is throttled.
    for _ <- 1..2 do
      resp =
        post(conn, ~p"/settings/import/linkedin", %{
          "import" => %{"archive" => upload_zip()}
        })

      assert html_response(resp, 200) =~ "linkedin-import-preview"
    end

    resp =
      post(conn, ~p"/settings/import/linkedin", %{
        "import" => %{"archive" => upload_zip()}
      })

    assert redirected_to(resp) == ~p"/settings/import/linkedin"
  end
end
