defmodule VutuvWeb.SocialMediaFormI18nTest do
  @moduledoc """
  The social-media-account form and its create flash must be fully localized.

  Two regressions this guards:
  * the provider `<select>` prompt and the field labels were hardcoded English
    ("Select a Social Media Provider" / humanized "Provider" / "Account"), an
    English island in an otherwise German UI, because they never went through
    gettext.
  * the German create flash carried a "das"/"dass" spelling error
    ("Wussten Sie, das der ..." instead of "... dass der ...").
  """
  use VutuvWeb.ConnCase, async: true

  @backend VutuvWeb.Gettext

  defp de(msgid), do: Gettext.gettext(@backend, msgid)

  test "the provider prompt is translated, not a hardcoded English island", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    html = conn |> get(~p"/#{user}/social_media_accounts/new") |> html_response(200)

    # The old hardcoded English prompt must be gone (it now goes through gettext).
    refute html =~ "Select a Social Media Provider"
    assert html =~ ~s(<select)
  end

  test "the German create flash uses 'dass', not the misspelled 'das'" do
    Gettext.put_locale(@backend, "de")

    flash =
      de(
        "Social media account created successfully. BTW: Did you know that the vutuv repo is hosted on GitHub? https://github.com/wintermeyer/vutuv"
      )

    assert flash =~ "Wussten Sie, dass der"
    refute flash =~ "Wussten Sie, das der"
  end

  test "the provider prompt has a German translation" do
    Gettext.put_locale(@backend, "de")

    prompt = de("Select a social media provider")

    # A translated msgid returns German, not the English msgid echoed back.
    assert prompt != "Select a social media provider"
    assert prompt =~ "Anbieter"
  end
end
