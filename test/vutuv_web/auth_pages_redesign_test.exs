defmodule VutuvWeb.AuthPagesRedesignTest do
  use VutuvWeb.ConnCase, async: true

  # The logged-out entry pages (landing/registration, login, the two PIN
  # screens) and the two legal pages used to render the legacy "imagebox": a
  # full-bleed stock photo (skateboard / leaf) with a floating card. That look
  # predated the Direction A reskin, so it clashed with every other page (cool
  # blue/slate cards on a grey canvas) and ignored dark mode entirely.
  #
  # They now share the Direction A `<.auth_layout>` (a brand-gradient hero panel
  # beside a white form card) or, for the legal pages, a plain content card. The
  # imagebox is gone from both stylesheets. These checks keep it from creeping
  # back while leaving the existing form-mechanics guards in their own files.

  @components_css Path.expand("../../assets/css/components.css", __DIR__)
  @app_css Path.expand("../../assets/css/app.css", __DIR__)

  describe "the landing / registration page" do
    test "renders the registration form on the Direction A hero, not the imagebox",
         %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      # The sign-up form still works (its fields are intact).
      assert body =~ ~s(name="user[first_name]")
      assert body =~ ~s(name="user[emails][0][value]")

      # The new branded hero (brand-blue gradient) is present.
      assert body =~ "from-brand-"

      # The legacy photo panel is gone for good.
      refute body =~ "imagebox"
    end
  end

  describe "the login page" do
    test "renders the email form on the Direction A hero, not the imagebox",
         %{conn: conn} do
      body = conn |> get(~p"/login") |> html_response(200)

      assert body =~ ~s(name="session[email]")
      assert body =~ "from-brand-"
      refute body =~ "imagebox"
    end
  end

  describe "the stylesheets" do
    test "carry no .imagebox rules anymore" do
      refute File.read!(@components_css) =~ "imagebox",
             "the legacy imagebox panel (and its embedded photos) must be removed from components.css"

      refute File.read!(@app_css) =~ "imagebox",
             "the issue #761 .imagebox__input override is obsolete once the imagebox is gone"
    end
  end
end
