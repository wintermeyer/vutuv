defmodule Vutuv.ReferencesTest do
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.References
  alias Vutuv.References.JobReference

  describe "changeset" do
    test "requires a title and a known kind" do
      changeset = JobReference.changeset(%JobReference{}, %{})
      assert %{title: ["can't be blank"]} = errors_on(changeset)

      changeset = JobReference.changeset(%JobReference{}, %{title: "Zeugnis", kind: "nonsense"})
      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    # The label is how a member tells five Zeugnisse apart, so it may not be
    # blank — and `validate_required` trims, which is what makes a title of
    # spaces as blank as an empty one. The form's `required` attribute is a
    # courtesy on top; this is the rule.
    test "refuses a label that is blank in any spelling" do
      for blank <- [nil, "", "   ", "\n ", "\t"] do
        changeset =
          JobReference.changeset(%JobReference{}, %{
            title: blank,
            owner_confirmation: "true"
          })

        assert %{title: ["can't be blank"]} = errors_on(changeset)
      end
    end

    test "one character is a label" do
      changeset =
        JobReference.changeset(%JobReference{}, %{title: "A", owner_confirmation: "true"})

      assert changeset.valid?
    end

    test "defaults to qualified and to not public" do
      changeset =
        JobReference.changeset(%JobReference{}, %{title: "Zeugnis", owner_confirmation: "true"})

      assert changeset.valid?
      reference = apply_changes(changeset)
      assert reference.kind == "qualified"
      refute reference.public?
    end

    # Every user-writable :string column needs a length validation matching
    # varchar(255), or an oversized value raises Postgres 22001 instead of
    # returning a field error.
    test "caps the varchar columns at 255 and the body at 50_000" do
      changeset =
        JobReference.changeset(%JobReference{}, %{
          title: String.duplicate("a", 256),
          employer: String.duplicate("b", 256),
          body: String.duplicate("c", 50_001)
        })

      errors = errors_on(changeset)
      assert ["should be at most 255 character(s)"] = errors.title
      assert ["should be at most 255 character(s)"] = errors.employer
      assert ["should be at most 50000 character(s)"] = errors.body
    end

    test "accepts a body at the cap" do
      changeset =
        JobReference.changeset(%JobReference{}, %{
          title: "Zeugnis",
          body: String.duplicate("c", 50_000),
          owner_confirmation: "true"
        })

      assert changeset.valid?
    end

    test "rejects an unknown body_source" do
      changeset =
        JobReference.changeset(%JobReference{}, %{title: "Z", body_source: "guessed"})

      assert %{body_source: ["is invalid"]} = errors_on(changeset)
    end

    # A <textarea> submits its line breaks as CRLF whatever it was given, so
    # the text that comes back from the edit form is never byte-identical to
    # the text extracted from the document. Stored canonical, so what the model
    # reads and what the review is bound to cannot drift apart on a save that
    # changed something else entirely.
    test "stores line breaks canonically, whatever the browser submitted" do
      changeset =
        JobReference.changeset(%JobReference{}, %{
          title: "Zeugnis",
          body: "Sehr geehrte Damen,\r\nzufrieden.\rEnde"
        })

      assert apply_changes(changeset).body == "Sehr geehrte Damen,\nzufrieden.\nEnde"
    end

    test "leaves a body it was never given alone" do
      changeset = JobReference.changeset(%JobReference{body: "gespeichert"}, %{title: "Zeugnis"})
      refute Map.has_key?(changeset.changes, :body)
    end
  end

  # An entry with nothing in it is not a Zeugnis: nothing to show, nothing to
  # attach to a CV, nothing for the review to read.
  describe "an entry must carry something" do
    test "neither a document nor a text is refused", %{} do
      user = insert(:user)

      assert {:error, changeset} =
               References.create_job_reference(user, %{
                 "title" => "Leeres Zeugnis",
                 "owner_confirmation" => "true"
               })

      assert %{document: [message]} = errors_on(changeset)
      assert message =~ "Upload the document"
    end

    test "a whitespace-only text counts as nothing" do
      user = insert(:user)

      assert {:error, _changeset} =
               References.create_job_reference(user, %{
                 "title" => "Leeres Zeugnis",
                 "body" => "   \n ",
                 "owner_confirmation" => "true"
               })
    end

    test "a text alone is enough" do
      user = insert(:user)

      assert {:ok, reference} =
               References.create_job_reference(user, %{
                 "title" => "Getipptes Zeugnis",
                 "body" => "Stets zu unserer vollsten Zufriedenheit.",
                 "owner_confirmation" => "true"
               })

      assert reference.body =~ "Zufriedenheit"
    end

    # A stored document is content even while the text is still being read out
    # of it, so an edit that touches something else must not trip over this.
    test "an entry whose document carries it survives an unrelated edit", %{} do
      user = insert(:user)
      stored = insert(:job_reference, user: user, body: nil, document: "zeugnis.pdf")

      assert {:ok, updated} = References.update_job_reference(stored, %{"title" => "Neuer Titel"})
      assert updated.title == "Neuer Titel"
    end
  end

  # The text is what the document says, not what the person being judged would
  # like it to say. Two claims rest on that and both collapse if it can be
  # edited afterwards: the AI review grades this exact wording against § 109
  # GewO, and a published Zeugnis is shown to strangers as a former employer's
  # own words. The lock is in the changeset, not in a `readonly` attribute — a
  # crafted POST or an API client must hit the same wall as the form.
  describe "the text is fixed once it exists" do
    test "an entry with text refuses a new one" do
      stored = %JobReference{id: Vutuv.UUIDv7.generate(), body: "Stets zu unserer Zufriedenheit."}

      changeset =
        JobReference.changeset(stored, %{
          title: "Zeugnis",
          body: "Stets zu unserer vollsten Zufriedenheit."
        })

      refute Map.has_key?(changeset.changes, :body)
      assert apply_changes(changeset).body == "Stets zu unserer Zufriedenheit."
    end

    test "the provenance is locked with it, so it cannot claim to be typed" do
      stored = %JobReference{
        id: Vutuv.UUIDv7.generate(),
        body: "Gelesen.",
        body_source: "pdf_text"
      }

      changeset = JobReference.changeset(stored, %{body: "Anders.", body_source: "typed"})

      refute Map.has_key?(changeset.changes, :body_source)
      assert apply_changes(changeset).body_source == "pdf_text"
    end

    # A new entry is where a member pastes their text, so nothing is locked yet.
    test "a new entry accepts one" do
      changeset = JobReference.changeset(%JobReference{}, %{title: "Z", body: "Der Text."})
      assert apply_changes(changeset).body == "Der Text."
    end

    # An entry whose extraction failed holds no text. Locking that would be a
    # dead end: no way to supply one, and nothing to protect either.
    test "an entry left without text still accepts one" do
      for empty <- [nil, "", "   \n "] do
        stored = %JobReference{id: Vutuv.UUIDv7.generate(), body: empty}
        changeset = JobReference.changeset(stored, %{body: "Nachgetragen."})

        assert apply_changes(changeset).body == "Nachgetragen."
      end
    end

    # The extraction path writes the body straight through `Ecto.Changeset`,
    # never this changeset, so reading a scan is unaffected by the lock.
    test "the reader can still fill an entry" do
      stored = %JobReference{id: Vutuv.UUIDv7.generate(), body: "Alt."}

      updated =
        stored |> Ecto.Changeset.change(body: "Frisch gelesen.") |> Ecto.Changeset.apply_changes()

      assert updated.body == "Frisch gelesen."
    end
  end

  # Going public is the one change on this schema that can hurt: a Zeugnis
  # carries an employer's judgement of a person. It therefore needs an explicit
  # tick, exactly like a qualification's proof document.
  describe "public visibility gate" do
    test "refuses to go public without the consent tick" do
      changeset = JobReference.changeset(%JobReference{}, %{title: "Z", public?: true})

      refute changeset.valid?
      assert %{public_consent: [_message]} = errors_on(changeset)
    end

    test "goes public with the tick and stamps the consent time" do
      changeset =
        JobReference.changeset(%JobReference{}, %{
          title: "Z",
          public?: true,
          public_consent: "true",
          owner_confirmation: "true"
        })

      assert changeset.valid?
      reference = apply_changes(changeset)
      assert reference.public?
      assert %DateTime{} = reference.public_consented_at
    end

    test "going private again clears the consent stamp" do
      public = %JobReference{public?: true, public_consented_at: DateTime.utc_now(:second)}

      reference =
        public
        |> JobReference.changeset(%{title: "Z", public?: false})
        |> apply_changes()

      refute reference.public?
      assert is_nil(reference.public_consented_at)
    end

    test "staying public across an unrelated edit needs no fresh tick" do
      # A struct standing for an entry already in the database has to look
      # like one: a hand-built struct is `:built`, which the changeset reads as
      # an insert, and an insert is the one case that asks for the tick.
      public =
        insert(:job_reference,
          user: insert(:user),
          title: "Z",
          public?: true,
          public_consented_at: DateTime.utc_now(:second)
        )

      changeset = JobReference.changeset(public, %{employer: "Muster GmbH"})

      assert changeset.valid?
      assert apply_changes(changeset).public?
    end

    # The consent columns must never be mass-assignable: a JSON API client
    # could otherwise publish a Zeugnis by sending the timestamp itself.
    test "public_consented_at cannot be set directly" do
      stamp = ~U[2020-01-01 00:00:00Z]

      changeset =
        JobReference.changeset(%JobReference{}, %{
          title: "Z",
          public?: true,
          public_consent: "true",
          public_consented_at: stamp
        })

      refute apply_changes(changeset).public_consented_at == stamp
    end
  end

  # The analysis reads one country's employment law. Storing and showing a
  # reference works everywhere; only the check is bound to a jurisdiction.
  describe "country and check availability" do
    test "defaults to the installation's country" do
      reference =
        %JobReference{}
        |> JobReference.changeset(%{title: "Zeugnis"})
        |> apply_changes()

      assert reference.country == Vutuv.Geo.default_country()
    end

    test "takes the country from the params and uppercases it" do
      reference =
        %JobReference{}
        |> JobReference.changeset(%{title: "Zeugnis", country: "ch"})
        |> apply_changes()

      assert reference.country == "CH"
    end

    test "rejects something that is not a country code" do
      changeset = JobReference.changeset(%JobReference{}, %{title: "Z", country: "Deutschland"})
      assert %{country: ["has invalid format"]} = errors_on(changeset)
    end

    test "the check is offered for Germany" do
      assert References.check_supported?(%JobReference{country: "DE"})
    end

    # Austria forbids the coded grading this prompt decodes, Switzerland has its
    # own case law. A German reading of either would be confidently wrong.
    test "the check is not offered for Austria or Switzerland" do
      refute References.check_supported?(%JobReference{country: "AT"})
      refute References.check_supported?(%JobReference{country: "CH"})
    end
  end

  describe "create_job_reference/2" do
    setup do
      %{user: insert(:user)}
    end

    test "stores an entry for its owner", %{user: user} do
      assert {:ok, reference} =
               References.create_job_reference(user, %{
                 "title" => "Zeugnis Muster GmbH",
                 "employer" => "Muster GmbH",
                 "body" => "Wir waren mit seinen Leistungen zufrieden.",
                 "owner_confirmation" => "true"
               })

      assert reference.user_id == user.id
      refute reference.public?
    end

    # user_id is set programmatically, never cast — otherwise one member could
    # file a Zeugnis on another member's profile.
    test "ignores a user_id in the params", %{user: user} do
      other = insert(:user)

      assert {:ok, reference} =
               References.create_job_reference(user, %{
                 "title" => "Zeugnis",
                 "user_id" => other.id,
                 "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
                 "owner_confirmation" => "true"
               })

      assert reference.user_id == user.id
    end
  end

  describe "list_job_references/1 and public_job_references/1" do
    setup do
      user = insert(:user)

      {:ok, private} =
        References.create_job_reference(user, %{
          "title" => "Privat",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "owner_confirmation" => "true"
        })

      {:ok, public} =
        References.create_job_reference(user, %{
          "title" => "Oeffentlich",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "public?" => "true",
          "public_consent" => "true",
          "owner_confirmation" => "true"
        })

      %{user: user, private: private, public: public}
    end

    test "the owner sees both", %{user: user, private: private, public: public} do
      ids = user |> References.list_job_references() |> Enum.map(& &1.id)
      assert private.id in ids
      assert public.id in ids
    end

    test "the public list carries only the public one", %{
      user: user,
      private: private,
      public: public
    } do
      ids = user |> References.public_job_references() |> Enum.map(& &1.id)
      assert public.id in ids
      refute private.id in ids
    end
  end

  describe "delete_job_reference/1" do
    test "removes the entry" do
      user = insert(:user)

      {:ok, reference} =
        References.create_job_reference(user, %{
          "title" => "Zeugnis",
          "body" => "Wir waren mit ihren Leistungen stets zufrieden.",
          "owner_confirmation" => "true"
        })

      assert {:ok, _deleted} = References.delete_job_reference(reference)
      assert References.list_job_references(user) == []
    end
  end
end
