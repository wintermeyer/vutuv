defmodule VutuvWeb.SettingsExampleButtonsTest do
  @moduledoc """
  The two "Play the example" buttons on /settings/preferences — the feed tab's
  ticker (issue #1668) and the browser tab's teaser (issue #1681).

  Both are a setting whose effect happens somewhere the member cannot watch, so
  the example is the whole reason the card is legible. And both read their own
  switch before playing, which is where the one bug in this file's history came
  from: they climbed to `.closest(".card")`, and the kit's `<.card>` is a pile
  of utility classes that emits no `card` class at all. `form` was null, `on`
  came back `undefined`, and the button silently did nothing from the day it
  shipped. Nothing failed, because nothing here can fail — a LiveView or
  controller test never runs `app.js`, and it took driving the page in a real
  browser to see it.

  So this asserts the two halves of the contract that a browser would check:
  the page really renders the checkbox each handler looks up, and the handlers
  really look it up somewhere that exists.
  """
  use VutuvWeb.ConnCase, async: true

  @app_js "assets/js/app.js"

  describe "the switch each example reads" do
    test "is rendered on the page, under the name the handler queries", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      # `name*=` on a checkbox, so the hidden false-companion beside it (same
      # name, type="hidden") must not be what the handler finds.
      assert html =~ ~s(name="user[browser_tab_teaser?]" type="checkbox")
      assert html =~ "data-tab-teaser-play"
    end

    test "is looked up somewhere that exists" do
      app_js = File.read!(@app_js)

      refute app_js =~ ~s|closest(".card")|,
             """
             A handler in #{@app_js} climbs to `.card`, and no such element is \
             rendered — the kit's <.card> emits utility classes only, so the \
             lookup returns null and whatever depends on it silently does \
             nothing. Query the document for the control's own name instead.\
             """

      assert app_js =~
               ~s|document.querySelector('input[type="checkbox"][name*="browser_tab_teaser"]')|
    end
  end
end
