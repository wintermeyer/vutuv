defmodule VutuvWeb.JobReferenceControllerTest do
  @moduledoc """
  The Arbeitszeugnis editor and the public list.

  The claims worth guarding here are all about visibility, because this is the
  one section where the wrong default is a privacy incident rather than a bug:
  a new entry is private, it stays private without an explicit tick, and the
  public page shows nothing a member did not publish.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  alias Vutuv.AccountEvents
  alias Vutuv.References

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    %{conn: conn, user: user}
  end

  describe "the editor" do
    test "lists the member's own references, published or not", %{conn: conn, user: user} do
      private = insert(:job_reference, user: user, title: "Privates Zeugnis")

      public =
        insert(:job_reference,
          user: user,
          title: "Oeffentliches Zeugnis",
          public?: true,
          public_consented_at: DateTime.utc_now(:second)
        )

      conn = get(conn, ~p"/settings/job_references")
      body = html_response(conn, 200)

      assert body =~ private.title
      assert body =~ public.title
    end

    test "the form renders", %{conn: conn} do
      conn = get(conn, ~p"/settings/job_references/new")
      assert html_response(conn, 200) =~ "job_reference"
    end
  end

  describe "creating" do
    # The default that matters. A member who fills in the form and saves has
    # published nothing.
    test "a new reference is private", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/settings/job_references", %{
          "job_reference" => %{
            "title" => "Zeugnis Muster GmbH",
            "employer" => "Muster GmbH",
            "body" => "Wir waren mit seinen Leistungen zufrieden.",
            "owner_confirmation" => "true"
          }
        })

      assert redirected_to(conn) == ~p"/settings/job_references"

      assert [reference] = References.list_job_references(user)
      refute reference.public?
      assert is_nil(reference.public_consented_at)
    end

    # Ticking "show publicly" without the confirmation must not publish.
    test "ticking public without the confirmation is refused", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/settings/job_references", %{
          "job_reference" => %{
            "title" => "Zeugnis",
            "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
            "public?" => "true",
            "owner_confirmation" => "true"
          }
        })

      assert html_response(conn, 422)
      assert References.list_job_references(user) == []
    end

    test "publishes with both ticks", %{conn: conn, user: user} do
      post(conn, ~p"/settings/job_references", %{
        "job_reference" => %{
          "title" => "Zeugnis",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "public?" => "true",
          "public_consent" => "true",
          "owner_confirmation" => "true"
        }
      })

      assert [reference] = References.list_job_references(user)
      assert reference.public?
      assert reference.public_consented_at
    end

    test "attaches the chosen CV entries", %{conn: conn, user: user} do
      job = insert(:work_experience, user: user)

      post(conn, ~p"/settings/job_references", %{
        "job_reference" => %{
          "title" => "Zeugnis",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "links" => ["work_experience:#{job.id}"],
          "owner_confirmation" => "true"
        }
      })

      assert [reference] = References.list_job_references(user)
      assert [link] = reference.links
      assert link.work_experience_id == job.id
    end

    test "ignores a CV entry belonging to somebody else", %{conn: conn, user: user} do
      theirs = insert(:work_experience, user: insert(:user))

      post(conn, ~p"/settings/job_references", %{
        "job_reference" => %{
          "title" => "Zeugnis",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "links" => ["work_experience:#{theirs.id}"],
          "owner_confirmation" => "true"
        }
      })

      assert [reference] = References.list_job_references(user)
      assert reference.links == []
    end

    test "a malformed link value is dropped rather than raising", %{conn: conn, user: user} do
      post(conn, ~p"/settings/job_references", %{
        "job_reference" => %{
          "title" => "Zeugnis",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "links" => ["nonsense", "x:y:z"],
          "owner_confirmation" => "true"
        }
      })

      assert [reference] = References.list_job_references(user)
      assert reference.links == []
    end
  end

  # A Zeugnis names a person and grades them, and here a language model reads
  # it. Filing somebody else's is the processing of another human's personal
  # data with nothing behind it, so the question is asked at the moment of the
  # act and the save does not happen without an answer — and what is kept is
  # the answer's timestamp, not a sentence nobody had to read.
  describe "the ownership gate" do
    test "a new reference is refused without the confirmation", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/settings/job_references", %{
          "job_reference" => %{"title" => "Fremdes Zeugnis"}
        })

      assert html_response(conn, 422)
      assert References.list_job_references(user) == []
    end

    test "the confirmation is stamped, not just accepted", %{conn: conn, user: user} do
      post(conn, ~p"/settings/job_references", %{
        "job_reference" => %{
          "title" => "Mein Zeugnis",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "owner_confirmation" => "true"
        }
      })

      assert [reference] = References.list_job_references(user)
      assert %DateTime{} = reference.owner_confirmed_at
    end

    # Asked once. A tick that reappears under every title change is a tick
    # people learn to click past, which is the opposite of what it is for.
    test "an edit does not ask again", %{conn: conn, user: user} do
      reference = insert(:job_reference, user: user)

      put(conn, ~p"/settings/job_references/#{reference}", %{
        "job_reference" => %{"title" => "Neuer Titel"}
      })

      assert References.get_job_reference(user, reference.id).title == "Neuer Titel"
    end

    # The stamp must not be settable from outside, exactly like the publish
    # one: an API client could otherwise affirm on the member's behalf.
    test "the stamp cannot be sent instead of ticked", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/settings/job_references", %{
          "job_reference" => %{
            "title" => "Zeugnis",
            "owner_confirmed_at" => "2020-01-01T00:00:00Z"
          }
        })

      assert html_response(conn, 422)
      assert References.list_job_references(user) == []
    end

    # A member who trips some other validation must not have to re-affirm: a
    # promise re-made on every attempt stops being read.
    test "a ticked confirmation survives an unrelated error", %{conn: conn} do
      conn =
        post(conn, ~p"/settings/job_references", %{
          "job_reference" => %{"title" => "", "owner_confirmation" => "true"}
        })

      html = html_response(conn, 422)
      assert html =~ ~s(name="job_reference[owner_confirmation]" value="true" checked)
    end

    test "the edit form does not carry the question at all", %{conn: conn, user: user} do
      reference = insert(:job_reference, user: user)

      html = conn |> get(~p"/settings/job_references/#{reference}/edit") |> html_response(200)

      refute html =~ "owner_confirmation"
    end
  end

  describe "editing" do
    setup %{user: user} do
      %{reference: insert(:job_reference, user: user)}
    end

    test "updates the entry", %{conn: conn, user: user, reference: reference} do
      put(conn, ~p"/settings/job_references/#{reference}", %{
        "job_reference" => %{"title" => "Neuer Titel"}
      })

      assert [updated] = References.list_job_references(user)
      assert updated.title == "Neuer Titel"
    end

    # The form renders the text `readonly`, but that is decoration: a crafted
    # POST, a stale tab or an API client must hit the same wall. The AI review
    # grades this exact wording and a published Zeugnis is read as a former
    # employer's words, so the text is not the member's to rewrite.
    test "a submitted text is ignored on an entry that already has one", %{
      conn: conn,
      user: user,
      reference: reference
    } do
      original = reference.body

      put(conn, ~p"/settings/job_references/#{reference}", %{
        "job_reference" => %{
          "title" => "Neuer Titel",
          "body" => "Stets zu unserer allervollsten Zufriedenheit.",
          "body_source" => "typed"
        }
      })

      updated = References.get_job_reference(user, reference.id)
      assert updated.title == "Neuer Titel"
      assert updated.body == original
      assert updated.body_source == reference.body_source
    end

    # An entry whose extraction failed holds no text, and locking that would
    # leave the member no way to supply one.
    test "an entry without text still accepts one", %{conn: conn, user: user} do
      empty = insert(:job_reference, user: user, body: nil, body_source: nil)

      put(conn, ~p"/settings/job_references/#{empty}", %{
        "job_reference" => %{"title" => empty.title, "body" => "Nachgetragener Text."}
      })

      assert References.get_job_reference(user, empty.id).body == "Nachgetragener Text."
    end

    test "unpublishing clears the consent stamp", %{conn: conn, user: user} do
      published =
        insert(:job_reference,
          user: user,
          public?: true,
          public_consented_at: DateTime.utc_now(:second)
        )

      put(conn, ~p"/settings/job_references/#{published}", %{
        "job_reference" => %{"title" => published.title, "public?" => "false"}
      })

      # The setup already left one entry here, so pick the one under test out
      # of the list rather than matching a single-element list.
      updated = References.get_job_reference(user, published.id)
      refute updated.public?
      assert is_nil(updated.public_consented_at)
    end

    test "deletes the entry", %{conn: conn, user: user, reference: reference} do
      delete(conn, ~p"/settings/job_references/#{reference}")
      assert References.list_job_references(user) == []
    end

    # A member must not be able to reach another member's Zeugnis by id.
    test "a foreign reference is a 404", %{conn: conn} do
      theirs = insert(:job_reference, user: insert(:user))

      conn = get(conn, ~p"/settings/job_references/#{theirs}/edit")
      assert conn.status == 404
    end
  end

  # The upload is the one control this section exists for, and it is the one a
  # keyboard or a screen reader is most easily locked out of: the input is
  # visually clipped so the zone can be a drop target, which is exactly the
  # arrangement that strands people when a detail slips.
  describe "the upload zone stays operable without a mouse" do
    test "the clipped input keeps a label, a description and its error line", %{conn: conn} do
      html = conn |> get(~p"/settings/job_references/new") |> html_response(200)

      # Clipped in CSS, never `hidden` or `display:none` — either would take it
      # out of the tab order and leave no way to choose a file at all.
      assert html =~ ~s(class="upload-drop__input")
      refute html =~ ~s(type="file" hidden)

      # The zone IS the label, so clicking it opens the picker with no
      # JavaScript and the input has a name to announce.
      assert html =~ ~s(<label class="upload-drop__zone" for="job_reference_document">)

      # The formats/size line is a description, not part of the name, and the
      # refusal is announced when JavaScript writes it.
      assert html =~
               ~s(aria-describedby="job_reference_document_formats job_reference_document_size_error")

      assert html =~ ~s(role="alert")
    end

    # Almost nobody types a Zeugnis out. Offering the text box as the equal
    # second half of an "either / or" made a new member choose between two
    # things when there was nothing to choose, so on a new entry it folds away
    # and the upload stands alone — while an existing entry shows it open,
    # because there it is what the review actually read.
    test "the text box is folded away on a new entry and open on an existing one", %{
      conn: conn,
      user: user
    } do
      new_html = conn |> get(~p"/settings/job_references/new") |> html_response(200)
      reference = insert(:job_reference, user: user)

      edit_html =
        conn |> get(~p"/settings/job_references/#{reference}/edit") |> html_response(200)

      assert new_html =~ ~s(<details class="editform__reveal")
      refute new_html =~ ~s(<details class="editform__reveal" open)
      assert edit_html =~ ~s(<details class="editform__reveal" open)
    end

    test "the label says it is required before the round trip", %{conn: conn} do
      html = conn |> get(~p"/settings/job_references/new") |> html_response(200)

      assert html =~ ~s(name="job_reference[title]")
      assert html =~ "required"
    end

    test "the size the page promises is the size the server enforces", %{conn: conn} do
      html = conn |> get(~p"/settings/job_references/new") |> html_response(200)

      assert html =~ ~s(data-upload-max="#{Vutuv.JobReferenceDocument.max_size()}")
      assert html =~ "10 MB"
    end

    test "the text is read-only exactly where it is locked", %{conn: conn, user: user} do
      locked = insert(:job_reference, user: user, body: "Stets zur vollsten Zufriedenheit.")
      empty = insert(:job_reference, user: user, body: nil)

      locked_html =
        conn |> get(~p"/settings/job_references/#{locked}/edit") |> html_response(200)

      empty_html = conn |> get(~p"/settings/job_references/#{empty}/edit") |> html_response(200)

      assert locked_html =~ "readonly"

      refute empty_html =~
               ~s(<textarea id="job_reference_body" name="job_reference[body]" readonly)
    end
  end

  # An uploaded file is not detachable on its own. The form used to offer a
  # "Remove file" beside the text, which left an entry claiming a grade with
  # nothing behind it: the review reads the text, but the text is only worth
  # anything because a document was read to produce it. So the file lives and
  # dies with its entry, and deleting the entry is the one way out.
  describe "an uploaded file stays with its entry" do
    setup %{user: user} do
      reference =
        insert(:job_reference,
          user: user,
          document: "zeugnis.pdf",
          document_content_type: "application/pdf",
          document_size: 12_345,
          document_fingerprint: String.duplicate("a", 64)
        )

      %{reference: reference}
    end

    test "the edit form names the file and offers no way to remove it", %{
      conn: conn,
      reference: reference
    } do
      html = conn |> get(~p"/settings/job_references/#{reference}/edit") |> html_response(200)

      assert html =~ "zeugnis.pdf"
      refute html =~ ~s(/settings/job_references/#{reference.id}/document")
    end

    # The removal was a route as well as a link, so a stale tab, a bookmark or
    # a crafted request must hit the same wall the missing link does.
    test "the removal route is gone", %{conn: conn, reference: reference} do
      conn = delete(conn, "/settings/job_references/#{reference.id}/document")

      assert conn.status == 404
    end

    # Deleting the entry is now the only way to get rid of the file, so the
    # confirmation has to say that the document goes with it.
    test "the delete confirmation says the document goes with it", %{conn: conn} do
      html = conn |> get(~p"/settings/job_references") |> html_response(200)

      assert html =~ "Delete this reference, its document and its review?"
    end
  end

  # The account log answers "what happened to my account, and when". A Zeugnis
  # is one of the more sensitive things stored here, so every hand that touches
  # one leaves a row — while the row itself stays free of the title, the
  # employer and the grade, all of which would outlive the entry by a year.
  describe "the account activity log" do
    defp kinds_logged(user), do: Enum.map(AccountEvents.recent(user, 20), & &1.kind)

    test "an added reference is logged", %{conn: conn, user: user} do
      post(conn, ~p"/settings/job_references", %{
        "job_reference" => %{
          "title" => "Zeugnis Muster GmbH",
          "country" => "DE",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "owner_confirmation" => "true"
        }
      })

      assert "job_reference_added" in kinds_logged(user)
    end

    test "a change is logged with the field names and nothing else", %{conn: conn, user: user} do
      reference = insert(:job_reference, user: user)

      put(conn, ~p"/settings/job_references/#{reference}", %{
        "job_reference" => %{"title" => "Neuer Titel", "public?" => "false"}
      })

      event = Enum.find(AccountEvents.recent(user, 20), &(&1.kind == "job_reference_updated"))

      assert event.details["fields"] == ["public?", "title"]
      refute Enum.any?(Map.values(event.details), &(&1 == "Neuer Titel"))
    end

    test "a deletion is logged", %{conn: conn, user: user} do
      reference = insert(:job_reference, user: user)

      delete(conn, ~p"/settings/job_references/#{reference}")

      assert "job_reference_removed" in kinds_logged(user)
    end
  end

  describe "the public list" do
    test "shows only published entries", %{conn: conn, user: user} do
      private = insert(:job_reference, user: user, title: "Privates Zeugnis")

      public =
        insert(:job_reference,
          user: user,
          title: "Oeffentliches Zeugnis",
          public?: true,
          public_consented_at: DateTime.utc_now(:second)
        )

      body = conn |> get(~p"/#{user}/job_references") |> html_response(200)

      assert body =~ public.title
      refute body =~ private.title
    end

    test "a private entry's own page is a 404", %{conn: conn, user: user} do
      private = insert(:job_reference, user: user)

      conn = get(conn, ~p"/#{user}/job_references/#{private}")
      assert conn.status == 404
    end

    test "a published entry's page renders its text", %{conn: conn, user: user} do
      published =
        insert(:job_reference,
          user: user,
          public?: true,
          public_consented_at: DateTime.utc_now(:second),
          body: "Wir waren mit seinen Leistungen zufrieden."
        )

      body = conn |> get(~p"/#{user}/job_references/#{published}") |> html_response(200)
      assert body =~ "Leistungen zufrieden"
    end

    # A published entry whose document has not cleared moderation must not
    # surface, even though the member did tick public.
    test "hides a published entry whose document is still in moderation", %{
      conn: conn,
      user: user
    } do
      pending =
        insert(:job_reference,
          user: user,
          public?: true,
          public_consented_at: DateTime.utc_now(:second),
          document: "zeugnis.pdf",
          document_fingerprint: String.duplicate("a", 64),
          document_moderation: "pending"
        )

      conn = get(conn, ~p"/#{user}/job_references/#{pending}")
      assert conn.status == 404
    end
  end
end
