defmodule VutuvWeb.RegistrationLiveTest do
  @moduledoc """
  The three-step sign-up form (`VutuvWeb.RegistrationLive`).

  The load-bearing test here is `"the whole way through really creates the
  account"`: the wizard only *collects*, and the account is created by the same
  `POST /new_registration` the single-screen form posted to — so the thing worth
  proving is that what it renders into its hidden fields is what that endpoint
  accepts. It submits through the form's own rendered `action` and fields rather
  than a hand-built params map, which is the only version of this test that would
  have caught the retired-URL bug of v7.34.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Tags

  @moduletag :capture_log

  defp open(conn \\ build_conn(), session \\ %{}) do
    live_isolated(
      conn,
      VutuvWeb.RegistrationLive,
      session: Map.merge(%{"csrf_token" => "token", "locale" => "en"}, session)
    )
  end

  # Walk the wizard the way a member does: fill step 1, continue, answer step 2,
  # continue. The settings have to be sent while step 2 is the one showing — an
  # unticked box posts nothing at all, so only the step that renders the boxes
  # may read an absent key as "off".
  defp walk_to_topics(view, fields \\ %{}, settings \\ nil) do
    fields =
      Map.merge(
        %{"first_name" => "Egon", "last_name" => "Müller", "email" => "egon@example.com"},
        fields
      )

    render_change(view, "validate", %{"step" => fields})
    render_click(view, "next", %{})
    settings && render_change(view, "validate", %{"step" => settings})
    render_click(view, "next", %{})
    view
  end

  defp tag_with_members(base, count) do
    name = unique_tag_name(base)
    tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))

    for _ <- 1..count, do: insert(:user_tag, user: insert(:activated_user), tag: tag)

    tag
  end

  describe "the steps" do
    test "opens on the name and address, with no topics in sight" do
      {:ok, view, html} = open()

      assert has_element?(view, "#step_first_name")
      assert has_element?(view, "#step_email")
      refute has_element?(view, "#signup-topic")
      # The settings belong to step 2 and must not be on the first screen.
      refute has_element?(view, "#signup-settings")
      assert html =~ "1"
    end

    test "refuses to continue without a name or an address" do
      {:ok, view, _html} = open()

      html = render_click(view, "next", %{})

      # Still on step 1, with something said about why.
      assert has_element?(view, "#step_first_name")
      refute has_element?(view, "#signup-settings")
      assert html =~ "can&#39;t be blank" or html =~ "blank"
    end

    test "refuses an address that is not one" do
      {:ok, view, _html} = open()

      render_change(view, "validate", %{
        "step" => %{"first_name" => "Egon", "last_name" => "Müller", "email" => "egon"}
      })

      render_click(view, "next", %{})

      assert has_element?(view, "#step_email")
      refute has_element?(view, "#signup-settings")
    end

    test "step 2 carries every setting the single screen had, at its old default" do
      {:ok, view, _html} = open()

      render_change(view, "validate", %{
        "step" => %{
          "first_name" => "Egon",
          "last_name" => "Müller",
          "email" => "egon@example.com"
        }
      })

      html = render_click(view, "next", %{})

      assert has_element?(view, "#signup-settings")
      assert has_element?(view, "#signup-gender")

      # The four positive boxes are ticked, the data-saving one is not, exactly
      # as the one-screen form shipped them.
      assert html =~ ~s(name="user[emails][0][public?]" value="true")
      assert html =~ ~s(name="user[noindex?]" value="false")
      assert html =~ ~s(name="user[noai?]" value="false")
      assert html =~ ~s(name="user[low_bandwidth?]" value="false")

      # Nothing is preselected in the gender group (PageController.index/2 says
      # why, and members wrote in about it when something was).
      refute html =~ ~s(name="step[gender]" value="female" checked)
      refute html =~ ~s(name="step[gender]" value="male" checked)
    end

    test "goes back without losing what was typed" do
      {:ok, view, _html} = open()

      render_change(view, "validate", %{
        "step" => %{
          "first_name" => "Egon",
          "last_name" => "Müller",
          "email" => "egon@example.com"
        }
      })

      render_click(view, "next", %{})
      html = render_click(view, "back", %{})

      assert html =~ ~s(value="Egon")
      assert html =~ ~s(value="egon@example.com")
    end
  end

  # These moved here from `page_controller_test.exs` when the form became three
  # steps: the promises are unchanged, the screen they are made on is step 2.
  describe "what the settings step promises" do
    defp settings_html(view) do
      render_change(view, "validate", %{
        "step" => %{
          "first_name" => "Egon",
          "last_name" => "Müller",
          "email" => "egon@example.com"
        }
      })

      render_click(view, "next", %{})
    end

    # All the opt-in boxes are framed positively (you grant a permission by
    # checking) and start CHECKED. Showing the address on your profile is what
    # most members want, so the box defaults ON; the schema default stays
    # private, so any other code path that creates an email without a choice
    # still keeps it private. Being findable is the point of the product, so the
    # indexing box stays checked; it is wired to the inverted `noindex?` field:
    # checked means "allow indexing" (noindex? = false). The AI box works the
    # same way on the inverted `noai?` field.
    test "the boxes are positively framed and checked by default" do
      {:ok, view, _html} = open()
      html = settings_html(view)

      assert html =~ "Allow others to view your email address"
      assert html =~ "Allow search engines to index your profile"
      assert html =~ "Allow AI agents and LLMs to use your profile"
      refute html =~ "Prevent search engines from indexing your profile"

      assert html =~ ~s(name="user[emails][0][public?]" value="true")
      assert html =~ ~s(name="user[noindex?]" value="false")
      assert html =~ ~s(name="user[noai?]" value="false")
    end

    # The gender question is the membership statistic, and it is the field
    # members complained about in its first incarnation. What must never come
    # back is the shape, not the word: preselected, in front of the name, and
    # unexplained.
    # **Including the blank one.** "Keine Angabe" carries the value "", so a
    # field defaulting to "" renders it preselected — which is an answer the
    # member never gave, in the one group where that is the whole complaint.
    # The browser found this; the first version of this test only named the
    # three real answers and stayed green.
    test "the gender group preselects nothing, the blank option included" do
      {:ok, view, _html} = open()

      checked =
        view
        |> settings_html()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(input[name="step[gender]"][checked]))
        |> Enum.to_list()

      assert checked == []
    end

    # Picking it really is an answer, and it reaches the submit as the empty
    # string the changeset folds to nil.
    test "declining is stored as a choice" do
      {:ok, view, _html} = open()
      settings_html(view)

      html = render_change(view, "validate", %{"step" => %{"gender" => ""}})
      doc = LazyHTML.from_fragment(html)

      assert [_] =
               doc
               |> LazyHTML.query(~s(input[name="step[gender]"][value=""][checked]))
               |> Enum.to_list()
    end

    test "the gender question offers all three answers and a way to decline" do
      {:ok, view, _html} = open()
      html = settings_html(view)

      assert html =~ ~s(name="step[gender]")
      assert html =~ ~s(value="female")
      assert html =~ ~s(value="male")
      assert html =~ ~s(value="diverse")
      assert html =~ "Prefer not to say"
    end

    # It is asked after the name by construction now: the name is step 1 and
    # this is step 2, so the order cannot drift with the markup.
    test "the gender question is not on the first step" do
      {:ok, view, html} = open()

      refute html =~ ~s(name="step[gender]")
      assert settings_html(view) =~ ~s(name="step[gender]")
    end

    # `mix gettext.extract --merge` fills a brand-new msgid with the translation
    # of whatever existing string it looks similar to, flags it `fuzzy`, and
    # fails no build — so a German page can ship confident nonsense while every
    # English assertion stays green. This field walked straight into it:
    # "Diverse" came back as "Trennlinie" and "Male" as "Maltesisch". One-word
    # labels are what that matcher gets wrong, so every one of them is asserted
    # here by name in the German render.
    test "the gender question is really translated, not fuzzy-filled" do
      {:ok, view, _html} = open(build_conn(), %{"locale" => "de"})

      gender =
        view
        |> settings_html()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#signup-gender")
        |> LazyHTML.text()

      assert gender =~ "Geschlecht"
      assert gender =~ "Weiblich"
      assert gender =~ "Männlich"
      assert gender =~ "Divers"
      assert gender =~ "Keine Angabe"

      # The two labels that were fuzzy-filled with unrelated words. Naming them
      # keeps the regression identifiable if anyone re-runs the merge and takes
      # the suggestion.
      refute gender =~ "Trennlinie"
      refute gender =~ "Maltesisch"
    end

    # One home for the visibility choices, and no checkbox floating loose in the
    # form: low-bandwidth mode is not a visibility choice, so rather than a
    # second group of one it sits with the others under a legend that covers
    # both — "Settings" (Stefan, 2026-09-03).
    test "every checkbox sits in the one named fieldset" do
      {:ok, view, _html} = open()
      doc = view |> settings_html() |> LazyHTML.from_fragment()

      in_settings =
        doc
        |> LazyHTML.query(~s(#signup-settings input[type="checkbox"]))
        |> LazyHTML.attribute("name")

      assert "step[email_public]" in in_settings
      assert "step[search_engines]" in in_settings
      assert "step[ai_agents]" in in_settings
      assert "step[fediverse]" in in_settings
      assert "step[low_bandwidth]" in in_settings

      in_form =
        doc
        |> LazyHTML.query(~s(#registration-form input[type="checkbox"]))
        |> LazyHTML.attribute("name")

      in_a_fieldset =
        doc
        |> LazyHTML.query(~s(#registration-form fieldset input[type="checkbox"]))
        |> LazyHTML.attribute("name")

      assert Enum.sort(in_form) == Enum.sort(in_a_fieldset)

      assert [_] = Enum.to_list(LazyHTML.query(doc, ~s(#signup-settings > legend))),
             "the signup-settings fieldset has no legend"
    end
  end

  describe "the topics step" do
    test "offers the topics most members carry, each with its own tally" do
      tag = tag_with_members("Elixir", 3)

      {:ok, view, _html} = open()
      html = walk_to_topics(view) |> render()

      assert html =~ tag.name
      # The chip says how many members carry it, which is the point of the step.
      assert html =~ "3"
    end

    test "a tapped suggestion becomes a chip and the reach appears" do
      tag = tag_with_members("Linux", 2)

      {:ok, view, _html} = open()
      view = walk_to_topics(view)

      html = render_click(view, "add_tag", %{"name" => tag.name})

      assert html =~ ~s(name="user[tag_list]" value="#{tag.name}")
      assert has_element?(view, "#signup-reach")
    end

    test "the reach counts a member once, however many of the topics they carry" do
      elixir = unique_tag_name("Elixir")
      linux = unique_tag_name("Linux")
      elixir_tag = insert(:tag, name: elixir, slug: Vutuv.SlugHelpers.tagify(elixir))
      linux_tag = insert(:tag, name: linux, slug: Vutuv.SlugHelpers.tagify(linux))

      both = insert(:activated_user)
      insert(:user_tag, user: both, tag: elixir_tag)
      insert(:user_tag, user: both, tag: linux_tag)

      {:ok, view, _html} = open()
      view = walk_to_topics(view)

      render_click(view, "add_tag", %{"name" => elixir})
      render_click(view, "add_tag", %{"name" => linux})

      # Two chips of one member each, one person behind them. A form may not
      # promise a reach the click cannot deliver.
      assert render(view) =~ "1"
      assert Tags.member_reach_by_name([elixir, linux]) == 1
    end

    # Typing the comma is what finishes a tag, with no button pressed: the badge
    # appears as it is typed and whatever follows stays in the field. A field
    # that keeps "Hund," as text until something else happens reads as broken.
    test "a comma turns what was typed into a badge" do
      {:ok, view, _html} = open()
      view = walk_to_topics(view)

      html = render_change(view, "validate", %{"step" => %{"typed" => "Hund,"}})

      assert html =~ ~s(name="user[tag_list]" value="Hund")
      # And the field is empty again, ready for the next one.
      assert [""] =
               html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#signup-topic")
               |> LazyHTML.attribute("value")
    end

    test "what follows the comma stays in the field" do
      {:ok, view, _html} = open()
      view = walk_to_topics(view)

      html = render_change(view, "validate", %{"step" => %{"typed" => "Hund, Kat"}})

      assert html =~ ~s(name="user[tag_list]" value="Hund")

      assert ["Kat"] =
               html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#signup-topic")
               |> LazyHTML.attribute("value")
    end

    test "a typed line of topics becomes one chip per topic" do
      {:ok, view, _html} = open()
      view = walk_to_topics(view)

      html = render_click(view, "add_typed", %{"value" => "Origami, Cooking"})

      assert html =~ ~s(value="Origami, Cooking")
    end

    test "a chip can be taken off again" do
      {:ok, view, _html} = open()
      view = walk_to_topics(view)

      render_click(view, "add_typed", %{"value" => "Origami, Cooking"})
      html = render_click(view, "remove_tag", %{"name" => "Origami"})

      assert html =~ ~s(name="user[tag_list]" value="Cooking")
    end

    test "the submit waits for the third topic" do
      {:ok, view, _html} = open()
      view = walk_to_topics(view)

      render_click(view, "add_typed", %{"value" => "Origami, Cooking"})
      assert render(view) =~ "disabled"

      render_click(view, "add_typed", %{"value" => "Cats"})
      refute render(view) =~ ~s(type="submit" disabled)
    end
  end

  describe "the submit" do
    test "the whole way through really creates the account", %{conn: conn} do
      {:ok, view, _html} = open()

      view
      |> walk_to_topics(%{"email" => "egon@example.com"})
      |> render_click("add_typed", %{"value" => "Origami, Cooking, Cats"})

      {action, params} = submitted_form(render(view))

      # Through the form's own action, never a route typed into the test: a
      # ConnTest that PUTs a hand-built path is exactly what hid the retired
      # /:slug/settings/* URLs for eight releases.
      conn = post(conn, action, params)

      assert html_response(conn, 200) =~ "PIN"
      assert user = registered("egon@example.com")
      assert user.first_name == "Egon"
      assert length(Repo.preload(user, :user_tags).user_tags) == 3
    end

    test "the settings reach the account as the boxes left them", %{conn: conn} do
      {:ok, view, _html} = open()

      # Step 2 answered with the search-engine and AI boxes unticked, which is
      # what an unticked box does: it posts nothing at all.
      walk_to_topics(view, %{"email" => "quiet@example.com"}, %{
        "email_public" => "true",
        "low_bandwidth" => "true"
      })

      render_click(view, "add_typed", %{"value" => "Origami, Cooking, Cats"})

      {action, params} = submitted_form(render(view))
      post(conn, action, params)

      user = registered("quiet@example.com")

      # Search engines and AI were unticked, so the negative columns are set.
      assert user.noindex?
      assert user.noai?
      assert user.low_bandwidth?
    end

    test "a rejected submit comes back on the topics step with the reason" do
      {:ok, _view, html} =
        open(build_conn(), %{
          "form_state" => %{
            "params" => %{"first_name" => "Egon", "tag_list" => "Origami"},
            "errors" => ["Please enter at least 3 different tags."]
          }
        })

      # Back on step 3, not at an empty step 1, and saying why.
      assert html =~ "Please enter at least 3 different tags."
      assert html =~ "Origami"
      assert html =~ ~s(value="Egon")
    end
  end

  describe "German" do
    test "the steps are German for a German visitor" do
      {:ok, _view, html} = open(build_conn(), %{"locale" => "de"})

      assert html =~ "Vorname"
      assert html =~ "E-Mail-Adresse"
      # The short labels are the ones `gettext.extract --merge` fuzzy-fills with
      # something unrelated, so they are asserted by name.
      refute html =~ "First name"
    end

    test "the topics step is German too" do
      {:ok, view, _html} = open(build_conn(), %{"locale" => "de"})
      html = walk_to_topics(view) |> render()

      assert html =~ "Wofür interessieren Sie sich?"
    end
  end

  # The account behind an address, the way a test can reach it:
  # `Vutuv.Accounts.user_by_email/1` is private.
  defp registered(address) do
    email = Repo.get_by(Email, value: address)
    email && Repo.get(User, email.user_id)
  end

  # The form as the browser would submit it: its action, plus every input that
  # carries a name and a value.
  defp submitted_form(html) do
    document = LazyHTML.from_fragment(html)
    form = LazyHTML.query(document, "form#registration-form")
    action = form |> LazyHTML.attribute("action") |> List.first()

    params =
      document
      |> LazyHTML.query("form#registration-form input[name]")
      |> Enum.reduce(%{}, fn input, acc ->
        name = input |> LazyHTML.attribute("name") |> List.first()
        value = input |> LazyHTML.attribute("value") |> List.first() || ""

        put_form_param(acc, name, value)
      end)

    {action, Map.delete(params, "_csrf_token")}
  end

  # "user[emails][0][value]" => %{"user" => %{"emails" => %{"0" => …}}}
  defp put_form_param(acc, name, value) do
    case Regex.scan(~r/[^\[\]]+/, name) do
      [[_single]] -> Map.put(acc, name, value)
      segments -> put_in_path(acc, Enum.map(segments, &List.first/1), value)
    end
  end

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value) do
    Map.put(map, key, put_in_path(Map.get(map, key, %{}), rest, value))
  end
end
