defmodule VutuvWeb.PressKitLiveTest do
  @moduledoc """
  The member's Media Kit editor (`/settings/media-kit`, issue #2085) — the first
  production caller of `Vutuv.PressKit.create/4`, and therefore the place the
  kind's write authorization is first asked at all.

  What the tests below hold:

    * a member writes their **own** press kit and nobody else's — a forged id
      from another member's shelf uploads, edits, reorders and deletes nothing;
    * the rights confirmation is a gate rather than a field: no tick, no file,
      and the stamp survives every later edit of the caption;
    * the shelf caps are `Vutuv.PressKit`'s, counted per shelf, and the add
      form is gone once one is full;
    * a picture the AI gate is still looking at says so on its tile;
    * the German page says the German words, which is what a `.po` fuzzy-fill
      would otherwise ship as confident nonsense.

  Not async: the upload path writes files and `:moderate_images` is a global
  flag, and the SQL sandbox rolls back neither. It also narrows `:press_kit`'s
  caps for the cap tests — `Vutuv.PressKit` is the only reader of that key.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.PressKit
  alias Vutuv.Repo

  setup %{conn: conn} do
    tmp = Path.join(System.tmp_dir!(), "vutuv_press_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {conn, user} = create_and_login_user(conn)
    {:ok, conn: conn, user: user, tmp: tmp}
  end

  # The size is a parameter because #2141's tests tell a batch apart by the
  # stored `width` — a press picture keeps no copy of the name it arrived under
  # (`Vutuv.PressKit.download_name/2`), so the pixels are what survives.
  defp photo_path(tmp, name \\ "portrait.jpg", {width, height} \\ {600, 400}) do
    path = Path.join(tmp, "#{System.unique_integer([:positive])}-#{name}")
    {:ok, img} = Image.new(width, height, color: [200, 40, 40])
    {:ok, _} = Image.write(img, path)
    path
  end

  defp add_photo!(owner, tmp, attrs \\ %{}) do
    attrs = Map.merge(%{"rights_confirmed" => "true", "credit" => "Foto: Ada King"}, attrs)
    {:ok, image} = PressKit.create(owner, owner, {photo_path(tmp), "portrait.jpg"}, attrs)
    image
  end

  defp open(conn), do: live(conn, ~p"/settings/media-kit")

  # Arms a shelf's rights tick the way the member does — the checkbox is in the
  # add form and its change event is what the picker's `disabled` reads.
  defp confirm_rights(live, shelf, credit) do
    live
    |> form("#press-add-#{shelf}", %{"shelf" => shelf, "rights" => "on", "credit" => credit})
    |> render_change()

    live
  end

  defp photo_entry(tmp, name, size \\ {600, 400}) do
    file_entry(name, File.read!(photo_path(tmp, name, size)), "image/jpeg")
  end

  # The one place a `Phoenix.LiveViewTest` upload entry is built.
  defp file_entry(name, content, type) do
    %{last_modified: 1_594_171_879_000, name: name, content: content, type: type}
  end

  # Drives one of the in-flight uploads of the #2141 batch to its last chunk.
  # The percentage is a **step**, not a target, and the batch already sent 10.
  defp finish(inflight, name), do: render_upload(Map.fetch!(inflight, name), name, 90)

  defp upload_photo(live, tmp, name \\ "portrait.jpg") do
    input = file_input(live, "#press-add-photo", :photo, [photo_entry(tmp, name)])
    render_upload(input, name)
  end

  defp upload_logo(live, tmp) do
    path = Path.join(tmp, "#{System.unique_integer([:positive])}-mark.png")
    {:ok, img} = Image.new(240, 80, color: [0, 170, 85])
    {:ok, _} = Image.write(img, path)

    entry = file_entry("mark.png", File.read!(path), "image/png")

    input = file_input(live, "#press-add-logo", :logo, [entry])
    render_upload(input, "mark.png")
  end

  # A vector the logo shelf accepts as a file and the cleaner then refuses
  # (issues #2181 and #2182): `body` goes inside the drawing, `root_attrs` onto
  # the `<svg>` element itself. Returns the page, so the caller asserts the
  # sentence the member is left with.
  defp refuse_logo(conn, body, root_attrs \\ "") do
    {:ok, live, _html} = open(conn)
    confirm_rights(live, "logo", "Logo: Ada King")

    markup =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="240" height="80"#{root_attrs}>) <>
        ~s(<rect width="240" height="80" fill="#0b3d91"/>#{body}</svg>)

    input =
      file_input(live, "#press-add-logo", :logo, [
        file_entry("mark.svg", markup, "image/svg+xml")
      ])

    render_upload(input, "mark.svg")
    render(live)
  end

  # What Figma and Illustrator export by default: the face embedded in a
  # `<style>` block, which is a file nothing here can take apart.
  defp webfont_svg do
    font = Base.encode64("wOFF" <> :binary.copy(<<0>>, 40))

    ~s(<style>@font-face{src:url\(data:font/woff;base64,#{font}\)}</style>)
  end

  defp ids(images), do: Enum.map(images, & &1.id)

  ## A page's editor (#2087)

  defp open_page_editor(conn, organization), do: live(conn, PressKit.editor_path(organization))

  # A second member of the page's team, signed in — the colleague whose view of
  # a picture somebody else uploaded is what #2087's gate is about. Its own
  # `build_conn/0`, because this module's setup already signed a member in on
  # the test's conn and a sent conn cannot make a second request.
  defp member_with_role(organization, role, granted_by) do
    # The page's own verification mail is already in this process's mailbox and
    # `sent_pin/0` reads the oldest `{:email, _}` it finds, so the login below
    # would read a message with no PIN in it.
    _ = flush_emails()
    {member_conn, member} = create_and_login_user(fresh_conn())
    {:ok, _} = Vutuv.Organizations.add_role(organization, member, role, granted_by)
    {member_conn, member}
  end

  # What `VutuvWeb.ConnCase`'s own setup hands each test, built again for a
  # second member.
  defp fresh_conn, do: build_conn() |> Plug.Test.init_test_session(%{})

  # A press photo on a **page's** shelf, uploaded by one of its members — the
  # owner and the uploader are two people here, which is the whole difference
  # from `add_photo!/3`.
  defp add_page_photo!(organization, uploader, tmp) do
    {:ok, image} =
      PressKit.create(organization, uploader, {photo_path(tmp), "portrait.jpg"}, %{
        "rights_confirmed" => "true",
        "credit" => "Foto: Ada King"
      })

    image
  end

  # The page's own logo, as a vector — the file the one-click adoption copies.
  defp with_svg_logo(organization, owner, tmp) do
    path = Path.join(tmp, "mark-#{System.unique_integer([:positive])}.svg")

    File.write!(path, """
    <svg xmlns="http://www.w3.org/2000/svg" width="240" height="80" viewBox="0 0 240 80">
      <rect width="240" height="80" fill="#0a5" />
      <circle cx="60" cy="40" r="24" fill="#fff" />
    </svg>
    """)

    store_logo!(organization, owner, path, "mark.svg")
  end

  defp with_png_logo(organization, owner, tmp) do
    path = Path.join(tmp, "mark-#{System.unique_integer([:positive])}.png")
    {:ok, img} = Image.new(240, 80, color: [0, 170, 85])
    {:ok, _} = Image.write(img, path)

    store_logo!(organization, owner, path, "mark.png")
  end

  defp store_logo!(organization, owner, path, filename) do
    {:ok, _organization} = Vutuv.Organizations.store_logo(organization, owner, path, filename)
    Repo.reload!(organization)
  end

  describe "the page" do
    test "lists the member's own press photos", %{conn: conn, user: user, tmp: tmp} do
      photo = add_photo!(user, tmp, %{"caption" => "Am Schreibtisch"})

      {:ok, live, _html} = open(conn)

      assert has_element?(live, "[data-press-picture='#{photo.id}']")
      assert render(live) =~ "Foto: Ada King"
    end

    test "the settings hub links to it, and that link opens the page", %{conn: conn} do
      hub = get(conn, ~p"/settings")

      assert html_response(hub, 200) =~ ~s(href="/settings/media-kit")

      # The rendered link, not the route we happen to know: a hub row pointing
      # at a retired URL is exactly the failure /settings/privacy shipped.
      assert {:ok, _live, _html} = open(conn)
    end

    test "a stranger's picture is neither listed nor touchable", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      stranger = insert(:activated_user)
      theirs = add_photo!(stranger, tmp)
      mine = add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      refute has_element?(live, "[data-press-picture='#{theirs.id}']")

      render_click(live, "delete", %{"id" => theirs.id})
      render_click(live, "move", %{"id" => theirs.id, "dir" => "up"})
      render_click(live, "open", %{"id" => theirs.id})
      render_click(live, "save", %{"picture_id" => theirs.id, "picture" => %{"credit" => "mine"}})

      kept = Repo.get!(ImageRow, theirs.id)
      assert kept.credit == "Foto: Ada King"
      assert kept.position == 0
      assert Repo.get(ImageRow, mine.id)
    end

    test "a reorder payload may rearrange the shelf but never join a foreign picture to it",
         %{conn: conn, user: user, tmp: tmp} do
      stranger = insert(:activated_user)
      theirs = add_photo!(stranger, tmp)
      first = add_photo!(user, tmp)
      second = add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      render_hook(live, "reorder_photos", %{"order" => [theirs.id, second.id, first.id]})

      assert ids(PressKit.photos(user)) == [second.id, first.id]
      # Numbered 0..n-1 over this member's own pictures: a foreign id must not
      # consume the hero's slot, or the first photo's download is named
      # `…-press-2.jpg`.
      assert [%{position: 0}, %{position: 1}] = PressKit.photos(user)
      assert Repo.get!(ImageRow, theirs.id).position == 0
    end

    test "a picture the payload left out keeps its place at the end", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      first = add_photo!(user, tmp)
      second = add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      render_hook(live, "reorder_photos", %{"order" => [second.id]})

      assert ids(PressKit.photos(user)) == [second.id, first.id]
      assert [%{position: 0}, %{position: 1}] = PressKit.photos(user)
    end
  end

  describe "authorization in the context" do
    setup do
      put_config(:verify_organization_domains, true)
      :ok
    end

    test "a member's press kit refuses a stranger as the uploader", %{tmp: tmp} do
      owner = insert(:activated_user)
      stranger = insert(:activated_user)

      assert {:error, :forbidden} =
               PressKit.create(owner, stranger, {photo_path(tmp), "portrait.jpg"}, %{
                 "rights_confirmed" => "true"
               })
    end

    test "a page's press kit refuses somebody who is not on its team", %{tmp: tmp} do
      outsider = insert(:activated_user)
      organization = active_organization_for(insert(:activated_user))

      assert {:error, :forbidden} =
               PressKit.create(organization, outsider, {photo_path(tmp), "portrait.jpg"}, %{
                 "rights_confirmed" => "true"
               })
    end

    test "a page's owner and its publisher may both write it, an admin of vutuv may not", %{
      tmp: tmp
    } do
      owner = insert(:activated_user)
      publisher = insert(:activated_user)
      admin = insert(:activated_user, admin?: true)
      organization = active_organization_for(owner)
      {:ok, _} = Vutuv.Organizations.add_role(organization, publisher, "publisher", owner)

      assert PressKit.manageable_by?(organization, owner)
      assert PressKit.manageable_by?(organization, publisher)
      refute PressKit.manageable_by?(organization, admin)

      assert {:ok, image} =
               PressKit.create(organization, publisher, {photo_path(tmp), "portrait.jpg"}, %{
                 "rights_confirmed" => "true"
               })

      # Every write states its viewer, not only the upload: a role withdrawn
      # after the file landed has to bite on the next edit.
      outsider = insert(:activated_user)

      assert {:error, :forbidden} = PressKit.update(image, outsider, %{"credit" => "theirs"})
      assert {:error, :forbidden} = PressKit.reorder(organization, outsider, false, [image.id])
      assert {:error, :forbidden} = PressKit.move(organization, outsider, false, image.id, :up)
    end
  end

  describe "uploading" do
    test "the picker stays closed until the rights are confirmed", %{conn: conn} do
      {:ok, live, _html} = open(conn)

      assert has_element?(live, "#press-add-photo input[type=file][disabled]")

      confirm_rights(live, "photo", "Foto: Ada King")

      refute has_element?(live, "#press-add-photo input[type=file][disabled]")
    end

    # The disabled picker is what a member meets; the changeset is what a
    # crafted client meets, and the page carries the tick into it rather than
    # asking a second question of its own. `Phoenix.LiveViewTest` refuses to
    # drive a disabled input at all, which is why the second half is asked one
    # layer down.
    test "a file offered without the tick is refused by the changeset", %{
      user: user,
      tmp: tmp
    } do
      assert {:error, changeset} =
               PressKit.create(user, user, {photo_path(tmp), "portrait.jpg"}, %{
                 "rights_confirmed" => false,
                 "credit" => "Foto: Ada King"
               })

      assert Keyword.has_key?(changeset.errors, :rights_confirmed)
      assert PressKit.photos(user) == []
    end

    test "a confirmed file lands on the shelf with its credit and its stamp", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      {:ok, live, _html} = open(conn)

      live |> confirm_rights("photo", "Foto: Grace Hopper") |> upload_photo(tmp)

      assert [photo] = PressKit.photos(user)
      assert photo.credit == "Foto: Grace Hopper"
      assert photo.logo == false
      assert photo.position == 0
      assert %NaiveDateTime{} = photo.rights_confirmed_at
    end

    test "the credit is offered ready-filled from the last picture on that shelf", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      add_photo!(user, tmp, %{"credit" => "Foto: Grace Hopper"})

      {:ok, _live, html} = open(conn)

      assert html =~ ~s(value="Foto: Grace Hopper")
    end

    test "an empty shelf offers the member's own name instead of an empty field", %{
      conn: conn,
      user: user
    } do
      {:ok, live, _html} = open(conn)

      name = Vutuv.Identity.display_name(user)

      # Both shelves: a member with nothing on either meets their own name twice
      # rather than two empty fields.
      assert has_element?(live, "#press-new-credit-photo[value='#{name}']")
      assert has_element?(live, "#press-new-credit-logo[value='#{name}']")
    end

    test "it stays a default: a cleared field stores an empty credit", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      {:ok, live, _html} = open(conn)

      live
      |> form("#press-add-photo", %{"shelf" => "photo", "rights" => "on", "credit" => ""})
      |> render_change()

      upload_photo(live, tmp)

      assert [photo] = PressKit.photos(user)
      assert photo.credit in [nil, ""]
    end
  end

  describe "the logo shelf" do
    test "a logo lands on its own shelf, and the tiles change ground", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      {:ok, live, _html} = open(conn)

      live |> confirm_rights("logo", "Logo: Ada King") |> upload_logo(tmp)

      assert [logo] = PressKit.logos(user)
      assert logo.logo == true
      assert PressKit.photos(user) == []

      # A white wordmark is invisible on a white card, so the shelf that holds
      # one lets the owner look at it on the ground it was drawn for.
      assert live |> element("[data-press-picture='#{logo.id}']") |> render() =~ "bg-white"

      render_click(live, "logo_ground", %{"ground" => "dark"})

      assert live |> element("[data-press-picture='#{logo.id}']") |> render() =~ "bg-slate-900"
    end

    test "a full logo shelf says so in its own words", %{conn: conn, user: user, tmp: tmp} do
      put_config(:press_kit, max_filesize: 30_000_000, max_photos: 10, max_logos: 1)

      {:ok, live, _html} = open(conn)
      live |> confirm_rights("logo", "Logo: Ada King") |> upload_logo(tmp)

      assert [_one] = PressKit.logos(user)
      assert live |> element("[data-press-count='logo']") |> render() =~ "1 of 1"
      assert has_element?(live, "[data-press-full='logo']")
      refute has_element?(live, "#press-add-logo")
    end
  end

  describe "the caps" do
    test "a full shelf hides the add form and says so", %{conn: conn, user: user, tmp: tmp} do
      put_config(:press_kit, max_filesize: 30_000_000, max_photos: 1, max_logos: 5)
      add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      refute has_element?(live, "#press-add-photo")
      assert has_element?(live, "[data-press-full='photo']")
      # The logo shelf is counted apart, so a full photo shelf costs it nothing.
      assert has_element?(live, "#press-add-logo")
    end

    test "the counter reads the cap rather than a literal", %{conn: conn, user: user, tmp: tmp} do
      put_config(:press_kit, max_filesize: 30_000_000, max_photos: 3, max_logos: 5)
      add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      assert live |> element("[data-press-count='photo']") |> render() =~ "1 of 3"
    end
  end

  describe "ordering" do
    test "the arrows swap two pictures and renumber the shelf from zero", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      first = add_photo!(user, tmp)
      second = add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      render_click(live, "move", %{"id" => second.id, "dir" => "up"})

      assert ids(PressKit.photos(user)) == [second.id, first.id]
      assert [%{position: 0}, %{position: 1}] = PressKit.photos(user)

      # The hero's download is named `…-press-1.jpg` from `position + 1`, so a
      # shelf numbered from 1 (which is what `Vutuv.Ordering` writes for the
      # profile sections) would hand the first photo out as number two.
      assert [hero | _] = PressKit.photos(user)
      assert PressKit.download_name(hero, ".jpg") =~ "-press-1.jpg"
    end
  end

  describe "editing a picture" do
    test "saving a caption keeps the moment the rights were released", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      # Aged deliberately: a restamp inside the same second is indistinguishable
      # from keeping it, so a test written against a fresh row passes with the
      # branch and without it.
      stamp = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -86_400)

      photo =
        user
        |> add_photo!(tmp)
        |> Ecto.Changeset.change(rights_confirmed_at: stamp)
        |> Repo.update!()

      {:ok, live, _html} = open(conn)

      render_click(live, "open", %{"id" => photo.id})

      live
      |> form("#press-form-#{photo.id}", %{
        "picture_id" => photo.id,
        "picture" => %{"caption" => "Foto von der Bühne", "credit" => "Foto: Grace Hopper"}
      })
      |> render_submit()

      assert [saved] = PressKit.photos(user)
      assert saved.caption == "Foto von der Bühne"
      assert saved.credit == "Foto: Grace Hopper"
      assert saved.rights_confirmed_at == stamp
    end

    test "an edit cannot move a picture onto the other shelf", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      photo = add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      render_click(live, "save", %{
        "picture_id" => photo.id,
        "picture" => %{"logo" => "true", "credit" => "Foto: Grace Hopper"}
      })

      assert [saved] = PressKit.photos(user)
      assert saved.logo == false
      assert PressKit.logos(user) == []
    end

    test "an over-long credit is a form error rather than a 500", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      photo = add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      html =
        render_click(live, "save", %{
          "picture_id" => photo.id,
          "picture" => %{"credit" => String.duplicate("a", 300)}
        })

      assert html =~ "press-error"
      assert Repo.get!(ImageRow, photo.id).credit == "Foto: Ada King"
    end

    test "Remove takes the picture off the shelf", %{conn: conn, user: user, tmp: tmp} do
      photo = add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      render_click(live, "delete", %{"id" => photo.id})

      assert PressKit.photos(user) == []
      refute Repo.get(ImageRow, photo.id)
    end
  end

  describe "the three bios (issue #2101)" do
    test "the card offers all three, empty, with their guidance", %{conn: conn} do
      {:ok, _live, html} = open(conn)

      assert html =~ ~s(data-press-bios)

      for length <- ~w(short medium long),
          do: assert(html =~ ~s(data-press-bio="#{length}"))

      # The word counts are guidance in the editor, so they are said here and
      # nowhere else.
      assert html =~ "About 50 words"
      assert html =~ "About 150 words"
      assert html =~ "0 words"
    end

    test "writing one stores it and shows it back", %{conn: conn, user: user} do
      {:ok, live, _html} = open(conn)

      render_click(live, "open_bio", %{"length" => "short"})

      html =
        live
        |> form("#press-bio-form-short", %{
          "length" => "short",
          "bio" => %{"text" => "Ada King builds **bridges** in Bonn."}
        })
        |> render_submit()

      assert PressKit.bio(user).short == "Ada King builds **bridges** in Bonn."
      # Rendered through the post pipeline, so the marks are marks.
      assert html =~ "<strong>bridges</strong>"
      refute html =~ "**bridges**"
    end

    test "an over-long short bio is stored: the count is guidance, not a limit", %{
      conn: conn,
      user: user
    } do
      eighty = Enum.map_join(1..80, " ", &"Wort#{&1}")

      {:ok, live, _html} = open(conn)
      render_click(live, "open_bio", %{"length" => "short"})

      html =
        live
        |> form("#press-bio-form-short", %{"length" => "short", "bio" => %{"text" => eighty}})
        |> render_submit()

      assert PressKit.bio(user).short == eighty
      assert html =~ "80 words"
      refute html =~ "press-error"
    end

    test "the counter follows what is typed, before anything is saved", %{conn: conn} do
      {:ok, live, _html} = open(conn)
      render_click(live, "open_bio", %{"length" => "medium"})

      html =
        live
        |> form("#press-bio-form-medium", %{
          "length" => "medium",
          "bio" => %{"text" => "One two three four."}
        })
        |> render_change()

      assert html =~ "4 words"
    end

    test "a mention in a bio links to that profile and notifies nobody", %{
      conn: conn,
      user: user
    } do
      photographer = insert_activated_user(username: "reafotografin")

      {:ok, live, _html} = open(conn)
      render_click(live, "open_bio", %{"length" => "long"})

      html =
        live
        |> form("#press-bio-form-long", %{
          "length" => "long",
          "bio" => %{"text" => "Portraits by @reafotografin."}
        })
        |> render_submit()

      assert html =~ ~s(href="/reafotografin")
      assert Vutuv.Activity.notifications_count(photographer.id) == 0
      assert PressKit.bio(user).long =~ "@reafotografin"
    end

    test "clearing a bio removes it rather than leaving an empty block", %{
      conn: conn,
      user: user
    } do
      {:ok, _bio} = PressKit.save_bio(user, user, %{"short" => "Something."})

      {:ok, live, _html} = open(conn)
      render_click(live, "open_bio", %{"length" => "short"})

      live
      |> form("#press-bio-form-short", %{"length" => "short", "bio" => %{"text" => "  "}})
      |> render_submit()

      assert PressKit.bio(user).short == nil
    end

    test "past the column cap the member is told, and nothing is written", %{
      conn: conn,
      user: user
    } do
      {:ok, live, _html} = open(conn)
      render_click(live, "open_bio", %{"length" => "long"})

      html =
        live
        |> form("#press-bio-form-long", %{
          "length" => "long",
          "bio" => %{"text" => String.duplicate("a", PressKit.max_bio_length() + 1)}
        })
        |> render_submit()

      assert html =~ "press-error"
      assert PressKit.bio(user).long == nil
    end

    test "a forged length writes nothing at all", %{conn: conn, user: user} do
      {:ok, live, _html} = open(conn)

      render_submit(live, "save_bio", %{"length" => "middling", "bio" => %{"text" => "Nope."}})

      assert PressKit.bio(user).short == nil
      assert PressKit.bio(user).medium == nil
      assert PressKit.bio(user).long == nil
    end
  end

  # Issue #2141. Three pictures in flight at once, finishing in the reverse of
  # the order they were picked, which is what a batch with one big file among
  # small ones does every time.
  #
  # **One `file_input` per picture, deliberately.** `Phoenix.LiveViewTest`'s
  # upload client stops the moment one of *its* entries is consumed, and its
  # channels go with it, so a single input can carry exactly one completed
  # upload — with three in one input the second `render_upload/3` exits with
  # "no process". Three clients registered before any of them finishes give the
  # server the same picture a real multi-pick does: three entries in the picked
  # order, all in flight, finishing in another order.
  describe "several pictures in flight at once (issue #2141)" do
    setup %{conn: conn, tmp: tmp} do
      {:ok, live, _html} = open(conn)
      confirm_rights(live, "photo", "Foto: Ada King")

      inflight =
        Map.new(
          [{"hero.jpg", 600}, {"second.jpg", 500}, {"third.jpg", 400}],
          fn {name, width} ->
            input =
              file_input(live, "#press-add-photo", :photo, [photo_entry(tmp, name, {width, 400})])

            render_upload(input, name, 10)
            {name, input}
          end
        )

      {:ok, live: live, inflight: inflight}
    end

    test "the shelf keeps the order they were picked in", %{
      user: user,
      inflight: inflight
    } do
      finish(inflight, "third.jpg")
      finish(inflight, "second.jpg")
      finish(inflight, "hero.jpg")

      assert Enum.map(PressKit.shelves(user).photos, & &1.width) == [600, 500, 400]
    end

    test "a picture that lands first keeps the slots of the ones picked before it", %{
      user: user,
      inflight: inflight
    } do
      finish(inflight, "third.jpg")

      assert [%{width: 400, position: 2}] = PressKit.shelves(user).photos
    end

    test "the hero note sits on the photo that was picked first", %{
      live: live,
      user: user,
      inflight: inflight
    } do
      finish(inflight, "third.jpg")
      finish(inflight, "hero.jpg")

      [hero, _third] = PressKit.shelves(user).photos

      assert hero.width == 600
      assert has_element?(live, "[data-press-picture='#{hero.id}'] [data-press-hero]")
    end

    test "a picture picked afterwards goes behind them all", %{
      live: live,
      user: user,
      tmp: tmp,
      inflight: inflight
    } do
      later =
        file_input(live, "#press-add-photo", :photo, [photo_entry(tmp, "later.jpg", {300, 200})])

      render_upload(later, "later.jpg")
      finish(inflight, "hero.jpg")

      assert Enum.map(PressKit.shelves(user).photos, & &1.width) == [600, 300]
    end

    # A batch reserves ahead of itself, so the shelf can hold one picture at
    # position 2 while positions 0 and 1 are still climbing, and a picture
    # picked after all of them belongs behind them. The layer that enforces it
    # is `PressKit.take_slot/3`, which hands out only free slots — so this stays
    # green with `note_slots/2`'s floor spelled either way, and is kept because
    # the promise is worth pinning rather than because it measures that floor.
    test "a picture picked afterwards goes behind the slots still being climbed", %{
      live: live,
      user: user,
      tmp: tmp,
      inflight: inflight
    } do
      finish(inflight, "third.jpg")

      later =
        file_input(live, "#press-add-photo", :photo, [photo_entry(tmp, "later.jpg", {300, 200})])

      render_upload(later, "later.jpg")

      shelf = PressKit.shelves(user).photos
      positions = Enum.map(shelf, & &1.position)

      assert positions == Enum.uniq(positions)
      assert Enum.map(shelf, & &1.width) == [400, 300]
    end
  end

  # A reserved slot is one socket's wish about order, taken from a snapshot of
  # one moment. Two things make that snapshot wrong, and both are ordinary.
  describe "a reserved slot the shelf cannot honour (issue #2141)" do
    # The commonest edit a full shelf gets. Nine rows and a highest position of
    # nine means the next wish is for ten, which is past the cap — but there is
    # a free slot, the one the deleted picture left, and the counter is already
    # promising it ("2 of 3", add form offered).
    test "a full shelf that loses one picture takes another", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      put_config(:press_kit, max_filesize: 30_000_000, max_photos: 3, max_logos: 5)
      Enum.each(1..3, fn _ -> add_photo!(user, tmp) end)
      [_first, middle, _last] = PressKit.shelves(user).photos

      {:ok, live, _html} = open(conn)
      render_click(live, "delete", %{"id" => middle.id})

      assert live |> element("[data-press-count='photo']") |> render() =~ "2 of 3"
      assert has_element?(live, "#press-add-photo")

      live |> confirm_rights("photo", "Foto: Ada King") |> upload_photo(tmp)

      refute render(live) =~ "No more than"
      assert [_a, _b, _c] = shelf = PressKit.shelves(user).photos
      # The gap the delete left, filled, rather than a fourth number nobody has.
      assert Enum.map(shelf, & &1.position) == [0, 1, 2]
    end

    # A phone and a laptop, both open on the editor. Each socket sees an empty
    # shelf, so each wishes for slot 0; two pictures answering to one slot are
    # two downloads called `<handle>-press-1.jpg`.
    test "two tabs of one member are given two slots", %{conn: conn, user: user, tmp: tmp} do
      {:ok, phone, _html} = open(conn)
      {:ok, laptop, _html} = open(recycle(conn))

      confirm_rights(phone, "photo", "Foto: Ada King")
      confirm_rights(laptop, "photo", "Foto: Ada King")

      phone
      |> file_input("#press-add-photo", :photo, [photo_entry(tmp, "phone.jpg", {600, 400})])
      |> render_upload("phone.jpg")

      laptop
      |> file_input("#press-add-photo", :photo, [photo_entry(tmp, "laptop.jpg", {500, 400})])
      |> render_upload("laptop.jpg")

      shelf = PressKit.shelves(user).photos

      assert Enum.map(shelf, & &1.position) == [0, 1]
      assert Enum.map(shelf, & &1.width) == [600, 500]

      assert Enum.map(shelf, &PressKit.download_name(&1, ".jpg")) ==
               Enum.uniq(Enum.map(shelf, &PressKit.download_name(&1, ".jpg")))
    end
  end

  describe "a picture the AI gate is still looking at" do
    test "wears the being-checked badge on its tile", %{conn: conn, user: user, tmp: tmp} do
      put_config(:moderate_images, true)
      photo = add_photo!(user, tmp)

      assert photo.moderation == "pending"

      {:ok, live, _html} = open(conn)

      assert live |> element("[data-press-picture='#{photo.id}']") |> render() =~ "Being checked"
    end

    # Issue #2144: ten identical grey badges and nothing else read like a failed
    # upload, so the shelf says once what a visitor meets meanwhile.
    test "the shelf says what a visitor sees meanwhile", %{conn: conn, user: user, tmp: tmp} do
      put_config(:moderate_images, true)
      add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      assert live |> element("[data-press-pending='photo']") |> render() =~
               "sees a pixelated stand-in in its place"

      refute has_element?(live, "[data-press-pending='logo']")
    end

    test "a released shelf says nothing of the kind", %{conn: conn, user: user, tmp: tmp} do
      add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      refute has_element?(live, "[data-press-pending='photo']")
    end
  end

  describe "a file on the wrong shelf (issue #2144)" do
    test "the logo shelf points at the photo shelf that would have taken it", %{
      conn: conn,
      tmp: tmp
    } do
      {:ok, live, _html} = open(conn)
      confirm_rights(live, "logo", "Logo: Ada King")

      input =
        file_input(live, "#press-add-logo", :logo, [photo_entry(tmp, "portrait.jpg", {60, 40})])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "portrait.jpg")
      assert render(live) =~ "That file type is not allowed."

      assert live |> element("[data-press-wrong-shelf='logo']") |> render() =~ "Press photos"
    end

    test "the photo shelf points at the logo shelf for a vector", %{conn: conn} do
      {:ok, live, _html} = open(conn)
      confirm_rights(live, "photo", "Foto: Ada King")

      entry =
        file_entry(
          "mark.svg",
          ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>),
          "image/svg+xml"
        )

      input = file_input(live, "#press-add-photo", :photo, [entry])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "mark.svg")

      assert live |> element("[data-press-wrong-shelf='photo']") |> render() =~ "Logo variants"
    end

    test "a format neither shelf takes is pointed nowhere", %{conn: conn} do
      {:ok, live, _html} = open(conn)
      confirm_rights(live, "photo", "Foto: Ada King")

      entry = file_entry("mappe.pdf", "%PDF-1.4", "application/pdf")

      input = file_input(live, "#press-add-photo", :photo, [entry])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "mappe.pdf")
      assert render(live) =~ "That file type is not allowed."
      refute has_element?(live, "[data-press-wrong-shelf='photo']")
    end
  end

  describe "a logo the cleaner refuses (issue #2182)" do
    test "a web font in it is named as a web font", %{conn: conn} do
      assert refuse_logo(conn, webfont_svg()) =~ "usually a web font"
    end

    test "a description that reads like an embedded file says which words", %{conn: conn} do
      assert refuse_logo(conn, ~s(<desc>Snapshot data:2026, brand book</desc>)) =~
               "reads as an embedded file"
    end

    # Issue #2181's refusal: the file is stored nowhere and the member is told
    # what is in their export rather than that it "could not be processed".
    test "a script handler is named as a script", %{conn: conn} do
      assert refuse_logo(conn, "", ~s( onload="fetch\('https://tracker.example'\)")) =~
               "carries a script"
    end

    test "and nothing of it reaches the shelf", %{conn: conn, user: user} do
      refuse_logo(conn, webfont_svg())

      assert PressKit.logos(user) == []
    end
  end

  describe "what the rest of the app has to know about the shelf" do
    # The GDPR export's own moduledoc: when a new per-user subsystem lands, its
    # section lands here too. This is the release where a member's press kit
    # starts existing, so it is the release that owes the export a section.
    test "the personal data export carries the member's press kit", %{user: user, tmp: tmp} do
      photo = add_photo!(user, tmp, %{"caption" => "Am Schreibtisch"})

      data = Vutuv.Export.build(user)

      assert data.schema_version >= 10
      assert [entry] = data.press_kit
      assert entry.kind == "photo"
      assert entry.credit == "Foto: Ada King"
      assert entry.caption == "Am Schreibtisch"
      # Absolute: this JSON is downloaded and kept, so a bare path addresses
      # nothing once it leaves the browser it was fetched in.
      assert entry.download_url ==
               VutuvWeb.Endpoint.url() <> PressKit.download_url(photo)

      assert %NaiveDateTime{} = entry.rights_confirmed_at
    end

    # #2084 left the rejection notice unclickable, because no branch named this
    # kind. The line has to lead somewhere, or a member is told a file was
    # refused and given nothing to do about it.
    test "a refused press picture's notice opens the press kit", %{user: user} do
      notice = %{kind: "image_rejected", image_kind: "press_kit", category: "nudity"}

      assert VutuvWeb.NotificationLine.notification_target(notice, user) == "/settings/media-kit"
    end
  end

  describe "a page's press kit editor" do
    setup %{conn: conn, user: user} do
      put_config(:verify_organization_domains, true)
      organization = active_organization_for(user)

      {:ok, conn: conn, organization: organization, owner: user}
    end

    test "its owner opens it, and the page's manage menu points there", %{
      conn: conn,
      organization: organization
    } do
      {:ok, _live, html} = open_page_editor(conn, organization)

      assert html =~ ~s(data-press-shelf="photo")
      assert html =~ ~s(data-press-shelf="logo")
      # …and no bios card: #2101 asked for a member's three bios, and
      # `press_bios.user_id` is a members-only column.
      refute html =~ "data-press-bios"

      page = conn |> get(~p"/organizations/#{organization.slug}") |> html_response(200)
      assert page =~ "organization-manage-press"
      assert page =~ PressKit.editor_path(organization)
    end

    test "a publisher opens it and writes the page's kit, an outsider gets nothing", %{
      organization: organization,
      owner: owner,
      tmp: tmp
    } do
      {publisher_conn, publisher} = member_with_role(organization, "publisher", owner)
      _ = flush_emails()
      {outsider_conn, _outsider} = create_and_login_user(fresh_conn())

      {:ok, live, _html} = open_page_editor(publisher_conn, organization)

      live
      |> confirm_rights("photo", "Foto: Rea Fotografin")
      |> upload_photo(tmp)

      assert [photo] = PressKit.photos(organization)
      # The row is the page's; the colleague who uploaded it is only recorded,
      # which is what keeps it when their account goes (#2087).
      assert photo.organization_id == organization.id
      assert is_nil(photo.user_id)
      assert photo.uploader_user_id == publisher.id

      assert outsider_conn |> get(PressKit.editor_path(organization)) |> html_response(404)
    end

    test "a role that is neither owner nor publisher is refused", %{
      organization: organization,
      owner: owner
    } do
      {recruiter_conn, _recruiter} = member_with_role(organization, "recruiter", owner)

      assert recruiter_conn |> get(PressKit.editor_path(organization)) |> html_response(404)
    end

    test "a picture waiting for the AI check is on every team member's editor", %{
      conn: conn,
      organization: organization,
      owner: owner,
      tmp: tmp
    } do
      # Uploaded by one colleague…
      {publisher_conn, _publisher} = member_with_role(organization, "publisher", owner)
      put_config(:moderate_images, true)
      {:ok, live, _html} = open_page_editor(publisher_conn, organization)

      live
      |> confirm_rights("photo", "Foto: Rea Fotografin")
      |> upload_photo(tmp)

      assert [photo] = PressKit.photos(organization)
      assert photo.moderation == "pending"

      # …and looked at by another, who has to be able to see what is being
      # checked. The editor lists the **page's** shelf, not the uploader's.
      {:ok, _other_live, html} = open_page_editor(conn, organization)

      assert html =~ "data-press-picture=\"#{photo.id}\""
      assert html =~ "Being checked"
    end

    test "the page's own vector logo is one press away, and the file it copies stays", %{
      conn: conn,
      organization: organization,
      owner: owner,
      tmp: tmp
    } do
      organization = with_svg_logo(organization, owner, tmp)
      source = Vutuv.OrganizationImageStore.original_path(organization.logo)

      {:ok, live, _html} = open_page_editor(conn, organization)

      # Armed by the shelf's own rights tick, like the picker beside it.
      assert has_element?(live, "#press-adopt-logo[disabled]")

      live
      |> confirm_rights("logo", "Logo: Acme GmbH")
      |> element("#press-adopt-logo")
      |> render_click()

      assert [logo] = PressKit.logos(organization)
      assert logo.content_type == "image/svg+xml"
      assert logo.organization_id == organization.id
      assert logo.rights_confirmed_at

      # Copied, never moved: the page's own logo must still be there.
      assert File.exists?(source)
    end

    test "the credit field offers the page's name, not the uploading member's", %{
      organization: organization,
      owner: owner
    } do
      {publisher_conn, publisher} = member_with_role(organization, "publisher", owner)

      {:ok, live, _html} = open_page_editor(publisher_conn, organization)

      # The kit belongs to the page, so the credit it offers names the page —
      # the colleague uploading for it is not who a journalist must print. The
      # refute is on the field, not on the page: the member's own name is in the
      # chrome of every page they are signed in to.
      assert has_element?(live, "#press-new-credit-photo[value='#{organization.name}']")

      refute has_element?(
               live,
               "#press-new-credit-photo[value='#{Vutuv.Identity.display_name(publisher)}']"
             )
    end

    # Both of these are the same hole seen twice: `ManageGate` asks the role at
    # **mount**, and an editor is open for as long as the tab is. While the kit's
    # owner was the viewer, resolving a picture out of `owned/2` was itself the
    # viewer check; with a page it no longer is, so every event has to re-ask.
    test "an edit by somebody whose role was withdrawn is refused, not a crash", %{
      organization: organization,
      owner: owner,
      tmp: tmp
    } do
      {publisher_conn, publisher} = member_with_role(organization, "publisher", owner)
      photo = add_page_photo!(organization, owner, tmp)

      {:ok, live, _html} = open_page_editor(publisher_conn, organization)

      {:ok, _} = Vutuv.Organizations.set_roles(organization, publisher, [], owner)

      # `PressKit.update/3` answers `{:error, :forbidden}`, which is not a
      # changeset — the handler used to hand it to `first_error/1` and take the
      # socket down with a FunctionClauseError. A refused write leaves the
      # picture as it was, exactly as a refused move or reorder does.
      render_click(live, "save", %{"picture_id" => photo.id, "picture" => %{"credit" => "theirs"}})

      assert Repo.get!(ImageRow, photo.id).credit == "Foto: Ada King"
      assert render(live) =~ "data-press-picture"
    end

    test "a withdrawn role cannot remove a picture", %{
      organization: organization,
      owner: owner,
      tmp: tmp
    } do
      {publisher_conn, publisher} = member_with_role(organization, "publisher", owner)
      photo = add_page_photo!(organization, owner, tmp)

      {:ok, live, _html} = open_page_editor(publisher_conn, organization)

      {:ok, _} = Vutuv.Organizations.set_roles(organization, publisher, [], owner)

      # The irreversible one: `Images.purge_by/2` drops the row **and** the
      # private original, and nothing derives a print file back. `PressKit.delete/1`
      # takes no viewer on purpose (#2084's AI rejection has none), so the
      # question is asked here, per event.
      render_click(live, "delete", %{"id" => photo.id})

      assert Repo.get(ImageRow, photo.id)
      assert [_] = PressKit.photos(organization)
    end

    test "a raster logo is not offered, since its file is not the printable one", %{
      conn: conn,
      organization: organization,
      owner: owner,
      tmp: tmp
    } do
      organization = with_png_logo(organization, owner, tmp)

      {:ok, live, _html} = open_page_editor(conn, organization)

      refute has_element?(live, "#press-adopt-logo")
    end

    test "a page with no logo at all is offered nothing", %{
      conn: conn,
      organization: organization
    } do
      {:ok, live, _html} = open_page_editor(conn, organization)

      refute has_element?(live, "#press-adopt-logo")
    end

    test "the page says the German words, in the page's own voice", %{
      conn: conn,
      organization: organization,
      owner: owner,
      tmp: tmp
    } do
      organization = with_svg_logo(organization, owner, tmp)
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")

      {:ok, _live, html} = open_page_editor(conn, organization)

      # The shelves and their gate, in German…
      assert html =~ "Pressefotos"
      assert html =~ "Logo-Varianten"
      assert html =~ "Rechte"
      # …and the two sentences that had to leave the member's msgid behind,
      # because its German addresses the reader as the owner ("Ihr Logo",
      # "über Sie schreibt") and a page's team is not the page. Both were
      # fuzzy-filled with exactly that member-voiced German by
      # `gettext.extract --merge`, which is why they are asserted by name.
      assert html =~ "Was eine Redaktion, die über diese Seite schreibt"
      assert html =~ "Das Logo dieser Seite als Datei"
      assert html =~ "Logo dieser Seite verwenden"
    end
  end

  describe "in German" do
    setup %{conn: conn} do
      # `recycle/1` first: the logged-in conn has already sent a response, and
      # a sent conn refuses a new request header.
      {:ok, conn: conn |> recycle() |> put_req_header("accept-language", "de-DE,de")}
    end

    test "the page and its shelves say the German words", %{conn: conn, user: user, tmp: tmp} do
      add_photo!(user, tmp)

      {:ok, _live, html} = open(conn)

      assert html =~ "Media Kit"
      assert html =~ "Pressefotos"
      assert html =~ "Logo-Varianten"
      assert html =~ "Bildnachweis"
      assert html =~ "Entfernen"
      # The rights sentence is the gate; a fuzzy-filled German for it would
      # promise something else entirely.
      assert html =~ "Rechte"
    end

    # Issue #2144's two new sentences, asserted by name: both are fresh msgids,
    # and a `gettext.extract --merge` fuzzy-fill would ship a German sentence
    # written for something else while every English test stayed green.
    test "the still-being-checked note says the German words", %{
      conn: conn,
      user: user,
      tmp: tmp
    } do
      put_config(:moderate_images, true)
      add_photo!(user, tmp)

      {:ok, live, _html} = open(conn)

      assert live |> element("[data-press-pending='photo']") |> render() =~
               "Besucher sehen an seiner Stelle eine verpixelte Vorschau"
    end

    test "the wrong-shelf pointer says the German words", %{conn: conn, tmp: tmp} do
      {:ok, live, _html} = open(conn)
      confirm_rights(live, "logo", "Logo: Ada King")

      input =
        file_input(live, "#press-add-logo", :logo, [photo_entry(tmp, "portrait.jpg", {60, 40})])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "portrait.jpg")

      assert live |> element("[data-press-wrong-shelf='logo']") |> render() =~
               "Pressefotos, weiter oben auf dieser Seite"
    end

    # Issue #2182's three refusals, asserted by name for the reason the module
    # keeps doing it: they are fresh msgids, `gettext.extract --merge`
    # fuzzy-fills a fresh msgid with the German of whatever it looks like, and
    # nothing fails the build over it — so a member would be told to do
    # something nobody ever meant.
    test "a refused logo says in German what is in it", %{conn: conn} do
      assert refuse_logo(conn, webfont_svg()) =~ "meist eine Web-Schrift"

      assert refuse_logo(conn, ~s(<desc>Snapshot data:2026, brand book</desc>)) =~
               "als eingebettete Datei"

      assert refuse_logo(conn, "", ~s( onload="fetch\('https://tracker.example'\)")) =~
               "enthält ein Skript"
    end

    test "the bios card says the German words (issue #2101)", %{conn: conn} do
      {:ok, _live, html} = open(conn)

      assert html =~ "Über Sie"
      assert html =~ "Kurze Fassung"
      assert html =~ "Mittlere Fassung"
      assert html =~ "Lange Fassung"
      assert html =~ "Etwa 50 Wörter"
      assert html =~ "0 Wörter"
      assert html =~ "Noch nichts geschrieben."
      # "Write" and "Edit" are different words in German, and the empty row
      # offers the first one.
      assert html =~ "Schreiben"
    end
  end
end
