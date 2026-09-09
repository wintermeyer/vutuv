defmodule VutuvWeb.PressKitLiveTest do
  @moduledoc """
  The member's press-kit editor (`/settings/press`, issue #2085) — the first
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

  defp photo_path(tmp, name \\ "portrait.jpg") do
    path = Path.join(tmp, "#{System.unique_integer([:positive])}-#{name}")
    {:ok, img} = Image.new(600, 400, color: [200, 40, 40])
    {:ok, _} = Image.write(img, path)
    path
  end

  defp add_photo!(owner, tmp, attrs \\ %{}) do
    attrs = Map.merge(%{"rights_confirmed" => "true", "credit" => "Foto: Ada King"}, attrs)
    {:ok, image} = PressKit.create(owner, owner, {photo_path(tmp), "portrait.jpg"}, attrs)
    image
  end

  defp open(conn), do: live(conn, ~p"/settings/press")

  # Arms a shelf's rights tick the way the member does — the checkbox is in the
  # add form and its change event is what the picker's `disabled` reads.
  defp confirm_rights(live, shelf, credit) do
    live
    |> form("#press-add-#{shelf}", %{"shelf" => shelf, "rights" => "on", "credit" => credit})
    |> render_change()

    live
  end

  defp photo_entry(tmp, name) do
    %{
      last_modified: 1_594_171_879_000,
      name: name,
      content: File.read!(photo_path(tmp, name)),
      type: "image/jpeg"
    }
  end

  defp upload_photo(live, tmp, name \\ "portrait.jpg") do
    input = file_input(live, "#press-add-photo", :photo, [photo_entry(tmp, name)])
    render_upload(input, name)
  end

  defp upload_logo(live, tmp) do
    path = Path.join(tmp, "#{System.unique_integer([:positive])}-mark.png")
    {:ok, img} = Image.new(240, 80, color: [0, 170, 85])
    {:ok, _} = Image.write(img, path)

    entry = %{
      last_modified: 1_594_171_879_000,
      name: "mark.png",
      content: File.read!(path),
      type: "image/png"
    }

    input = file_input(live, "#press-add-logo", :logo, [entry])
    render_upload(input, "mark.png")
  end

  defp ids(images), do: Enum.map(images, & &1.id)

  describe "the page" do
    test "lists the member's own press photos", %{conn: conn, user: user, tmp: tmp} do
      photo = add_photo!(user, tmp, %{"caption" => "Am Schreibtisch"})

      {:ok, live, _html} = open(conn)

      assert has_element?(live, "[data-press-picture='#{photo.id}']")
      assert render(live) =~ "Foto: Ada King"
    end

    test "the settings hub links to it, and that link opens the page", %{conn: conn} do
      hub = get(conn, ~p"/settings")

      assert html_response(hub, 200) =~ ~s(href="/settings/press")

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

  describe "a picture the AI gate is still looking at" do
    test "wears the being-checked badge on its tile", %{conn: conn, user: user, tmp: tmp} do
      put_config(:moderate_images, true)
      photo = add_photo!(user, tmp)

      assert photo.moderation == "pending"

      {:ok, live, _html} = open(conn)

      assert live |> element("[data-press-picture='#{photo.id}']") |> render() =~ "Being checked"
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

      assert VutuvWeb.NotificationLine.notification_target(notice, user) == "/settings/press"
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

      assert html =~ "Pressefotos &amp; Logos"
      assert html =~ "Logo-Varianten"
      assert html =~ "Bildnachweis"
      assert html =~ "Entfernen"
      # The rights sentence is the gate; a fuzzy-filled German for it would
      # promise something else entirely.
      assert html =~ "Rechte"
    end
  end
end
