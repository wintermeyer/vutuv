defmodule Vutuv.PersonalNotesTest do
  @moduledoc """
  Private notes a member keeps about other accounts (`Vutuv.PersonalNotes`):
  as many as they like per account, newest first, only ever readable by their
  author, and gone the moment the account they are about is gone.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers, only: [remote_account: 1]

  alias Vutuv.Accounts
  alias Vutuv.Export
  alias Vutuv.Fediverse
  alias Vutuv.PersonalNotes
  alias Vutuv.PersonalNotes.PersonalNote

  defp member(attrs \\ []), do: insert(:activated_user, attrs)

  defp note!(author, subject, body) do
    {:ok, note} = PersonalNotes.create(author, subject, %{"body" => body})
    note
  end

  describe "writing" do
    test "keeps any number of notes per account, newest first" do
      me = member()
      ada = member()

      first = note!(me, ada, "Met at ElixirConf")
      second = note!(me, ada, "Asked about the **job**")
      third = note!(me, ada, "Sent the slides")

      assert Enum.map(PersonalNotes.recent(me, ada, 2), & &1.id) == [third.id, second.id]
      assert PersonalNotes.count(me, ada) == 3

      assert %{count: 3, notes: [%{id: id} | _]} = PersonalNotes.summary(me, ada)
      assert id == third.id
      assert first.body == "Met at ElixirConf"
    end

    test "trims the body and refuses an empty or oversized one" do
      me = member()
      ada = member()

      assert {:ok, %PersonalNote{body: "hello"}} =
               PersonalNotes.create(me, ada, %{"body" => "  hello \n"})

      assert {:error, changeset} = PersonalNotes.create(me, ada, %{"body" => "   "})
      assert "can't be blank" in errors_on(changeset).body

      too_long = String.duplicate("a", PersonalNote.max_body() + 1)
      assert {:error, changeset} = PersonalNotes.create(me, ada, %{"body" => too_long})
      assert errors_on(changeset).body != []
    end

    test "nobody writes a note about themselves" do
      me = member()

      assert {:error, :self} = PersonalNotes.create(me, me, %{"body" => "me"})
      assert PersonalNotes.count(me, me) == 0
    end

    test "works for a page and for an account on another network" do
      me = member()
      page = insert(:organization)
      remote = remote_account(handle: "tobias")

      note!(me, page, "Their press contact is Jana")
      note!(me, remote, "Fosstodon, asked for notes")

      assert [%{body: "Their press contact is Jana"}] = PersonalNotes.recent(me, page, 3)
      assert [%{body: "Fosstodon, asked for notes"}] = PersonalNotes.recent(me, remote, 3)
    end
  end

  describe "editing" do
    test "marks the note as edited and keeps its place" do
      me = member()
      ada = member()
      older = note!(me, ada, "first")
      newer = note!(me, ada, "second")

      assert {:ok, edited} = PersonalNotes.update(me, older.id, %{"body" => "first, corrected"})
      assert edited.body == "first, corrected"
      assert %DateTime{} = edited.edited_at
      assert edited.inserted_at == older.inserted_at

      assert Enum.map(PersonalNotes.recent(me, ada, 3), & &1.id) == [newer.id, older.id]
    end

    test "saving the text unchanged does not mark it as edited" do
      me = member()
      note = note!(me, member(), "same")

      assert {:ok, %PersonalNote{edited_at: nil}} =
               PersonalNotes.update(me, note.id, %{"body" => "same"})
    end

    test "an invalid edit comes back as a changeset" do
      me = member()
      note = note!(me, member(), "keep me")

      assert {:error, %Ecto.Changeset{}} = PersonalNotes.update(me, note.id, %{"body" => ""})
      assert PersonalNotes.get(me, note.id).body == "keep me"
    end

    test "deletes a note" do
      me = member()
      ada = member()
      note = note!(me, ada, "gone soon")

      assert :ok = PersonalNotes.delete(me, note.id)
      assert PersonalNotes.count(me, ada) == 0
      assert {:error, :not_found} = PersonalNotes.delete(me, note.id)
    end
  end

  describe "privacy" do
    test "nobody but the author reads, edits or deletes a note" do
      me = member()
      ada = member()
      other = member()
      note = note!(me, ada, "private")

      # Not the other member, and not the member the note is about.
      for viewer <- [other, ada] do
        assert PersonalNotes.get(viewer, note.id) == nil
        assert PersonalNotes.recent(viewer, ada, 3) == []
        assert PersonalNotes.list(viewer) == []
        assert {:error, :not_found} = PersonalNotes.update(viewer, note.id, %{"body" => "x"})
        assert {:error, :not_found} = PersonalNotes.delete(viewer, note.id)
      end

      assert PersonalNotes.get(me, note.id).body == "private"
    end

    test "a malformed id is simply not found" do
      me = member()

      assert PersonalNotes.get(me, "not-a-uuid") == nil
      assert {:error, :not_found} = PersonalNotes.update(me, "nope", %{"body" => "x"})
      assert {:error, :not_found} = PersonalNotes.delete(me, "nope")
    end

    test "no viewer, no notes" do
      assert PersonalNotes.summary(nil, member()) == %{count: 0, notes: []}
      refute PersonalNotes.available?(nil, member())
    end

    test "available to a signed-in member for anybody but themselves" do
      me = member()

      assert PersonalNotes.available?(me, member())
      assert PersonalNotes.available?(me, insert(:organization))
      assert PersonalNotes.available?(me, remote_account(handle: "x"))
      refute PersonalNotes.available?(me, me)
    end
  end

  describe "deletion" do
    test "a member's deletion takes the notes about them along" do
      me = member()
      ada = member()
      note!(me, ada, "about ada")

      {:ok, _} = Accounts.delete_user(ada)

      assert Repo.aggregate(PersonalNote, :count) == 0
    end

    test "the author's deletion takes their notes along" do
      me = member()
      note!(me, member(), "mine")

      {:ok, _} = Accounts.delete_user(me)

      assert Repo.aggregate(PersonalNote, :count) == 0
    end

    test "a page's deletion takes the notes about it along" do
      me = member()
      page = insert(:organization)
      note!(me, page, "about the page")

      Repo.delete!(page)

      assert Repo.aggregate(PersonalNote, :count) == 0
    end

    test "a remote account deleting itself takes the notes about it along" do
      me = member()
      remote = remote_account(handle: "leaving")
      note!(me, remote, "about them")

      :ok = Fediverse.remove_remote_account(remote.actor_uri)

      assert Repo.aggregate(PersonalNote, :count) == 0
    end
  end

  describe "the overview" do
    test "lists every note, newest first, with the account it is about" do
      me = member(first_name: "Me")
      ada = member(first_name: "Ada", last_name: "Lovelace")
      page = insert(:organization, name: "Analytical Engines")

      a = note!(me, ada, "about ada")
      b = note!(me, page, "about the page")

      assert [
               %{id: b_id, subject: %Vutuv.Organizations.Organization{}},
               %{id: a_id, subject: subject}
             ] =
               PersonalNotes.list(me)

      assert {b_id, a_id} == {b.id, a.id}
      assert subject.id == ada.id
    end

    test "searches the text and the name, case-insensitively" do
      me = member()
      ada = member(first_name: "Ada", last_name: "Lovelace")
      grace = member(first_name: "Grace", last_name: "Hopper")

      note!(me, ada, "Talked about Konferenzen")
      note!(me, grace, "Compiler pioneer")

      assert [%{body: "Talked about Konferenzen"}] = PersonalNotes.list(me, query: "konferenz")
      assert [%{body: "Compiler pioneer"}] = PersonalNotes.list(me, query: "HOPPER")
      assert [%{body: "Compiler pioneer"}] = PersonalNotes.list(me, query: grace.username)
      assert PersonalNotes.list(me, query: "nothing like this") == []
    end

    test "treats LIKE wildcards in the query as plain characters" do
      me = member()
      ada = member()
      note!(me, ada, "100% sure")
      note!(me, ada, "1000 things")

      assert [%{body: "100% sure"}] = PersonalNotes.list(me, query: "100%")
    end

    test "filters to one account and pages by id" do
      me = member()
      ada = member()
      grace = member()

      notes = for n <- 1..5, do: note!(me, ada, "ada #{n}")
      note!(me, grace, "grace")

      page1 = PersonalNotes.list(me, subject: ada, limit: 2)
      assert Enum.map(page1, & &1.body) == ["ada 5", "ada 4"]

      page2 = PersonalNotes.list(me, subject: ada, limit: 2, max_id: List.last(page1).id)
      assert Enum.map(page2, & &1.body) == ["ada 3", "ada 2"]

      assert length(PersonalNotes.list(me)) == length(notes) + 1
    end

    test "resolves the subject a filter link names, if the viewer may see it" do
      me = member()
      ada = member()
      page = insert(:organization)
      remote = remote_account(handle: "r")

      assert PersonalNotes.subject("member", ada.id, me).id == ada.id
      assert PersonalNotes.subject("organization", page.id, me).id == page.id
      assert PersonalNotes.subject("remote_account", remote.id, me).id == remote.id
      assert PersonalNotes.subject("member", "junk", me) == nil
      assert PersonalNotes.subject("bogus", me.id, me) == nil

      # A guessed id does not bring back somebody the viewer may not see.
      unconfirmed = insert(:user)
      frozen = insert(:organization, frozen_at: NaiveDateTime.utc_now(:second))
      assert PersonalNotes.subject("member", unconfirmed.id, me) == nil
      assert PersonalNotes.subject("organization", frozen.id, me) == nil
    end
  end

  test "the author's export carries their notes, the subject's does not" do
    me = member()
    ada = member()
    remote = remote_account(handle: "tobias")
    note!(me, ada, "about ada")
    note!(me, remote, "about tobias")

    assert [
             %{account: "@tobias@" <> _, kind: "remote_account", body: "about tobias"},
             %{account: account, kind: "member", body: "about ada", edited_at: nil}
           ] = Export.build(me).personal_notes

    assert account == "@" <> ada.username
    assert Export.build(ada).personal_notes == []
  end
end
