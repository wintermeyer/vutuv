defmodule VutuvWeb.ImportRateLimitTest do
  @moduledoc """
  The LinkedIn import is throttled per member (and per IP). Enabling the limiter
  mutates global config, so this runs non-async with a reset + restore, like the
  other rate-limit tests.
  """
  use VutuvWeb.ConnCase, async: false

  setup do
    Vutuv.RateLimiter.reset()
    put_config(:rate_limit, enabled: true)
    put_config(:linkedin_import_rate_limit, {2, 60_000})

    :ok
  end

  # `:linkedin_import_rate_limit` is normally ABSENT, and `Application.get_env/2`
  # answers nil for absent and for nil alike — so the obvious
  # `put_env(key, get_env(key))` restore wrote nil back as a real value and
  # poisoned the key for every later test in the run. The next reader then did
  # not get the function's default, it got nil, which crashed the contact
  # finder's upload with a MatchError (11 tests, in a file that has nothing to
  # do with rate limits). Capture with fetch_env/2 and restore the two cases
  # apart.
  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp upload_zip do
    entries = [{~c"Skills.csv", "Name\nElixir\n"}]
    {:ok, {_name, binary}} = :zip.create(~c"export.zip", entries, [:memory])
    path = Path.join(System.tmp_dir!(), "li_rl_#{System.unique_integer([:positive])}.zip")
    File.write!(path, binary)
    %Plug.Upload{path: path, filename: "export.zip", content_type: "application/zip"}
  end

  test "throttles a member's repeated imports", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

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
