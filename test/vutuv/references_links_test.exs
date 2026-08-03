defmodule Vutuv.ReferencesLinksTest do
  use Vutuv.DataCase, async: true

  import Ecto.Query
  import Vutuv.Factory

  alias Vutuv.References
  alias Vutuv.References.Link
  alias Vutuv.Repo

  setup do
    user = insert(:user)

    %{
      user: user,
      reference: insert(:job_reference, user: user),
      job: insert(:work_experience, user: user),
      school: insert(:education, user: user),
      cert: insert(:qualification, user: user)
    }
  end

  describe "put_links/2" do
    test "attaches one CV entry", %{reference: reference, job: job} do
      assert {:ok, linked} = References.put_links(reference, [{:work_experience, job.id}])
      assert [link] = linked.links
      assert Link.subject(link) == {:work_experience, job.id}
    end

    test "attaches several entries across kinds", %{
      reference: reference,
      job: job,
      school: school,
      cert: cert
    } do
      assert {:ok, linked} =
               References.put_links(reference, [
                 {:work_experience, job.id},
                 {:education, school.id},
                 {:qualification, cert.id}
               ])

      subjects = linked.links |> Enum.map(&Link.subject/1) |> Enum.sort()

      assert subjects ==
               Enum.sort([
                 {:work_experience, job.id},
                 {:education, school.id},
                 {:qualification, cert.id}
               ])
    end

    test "replaces the previous set rather than adding to it", %{
      reference: reference,
      job: job,
      school: school
    } do
      {:ok, _first} = References.put_links(reference, [{:work_experience, job.id}])
      {:ok, second} = References.put_links(reference, [{:education, school.id}])

      assert [link] = second.links
      assert Link.subject(link) == {:education, school.id}
    end

    test "clears every link when given an empty list", %{reference: reference, job: job} do
      {:ok, _linked} = References.put_links(reference, [{:work_experience, job.id}])

      assert {:ok, cleared} = References.put_links(reference, [])
      assert cleared.links == []
    end

    test "the same entry twice yields one link", %{reference: reference, job: job} do
      assert {:ok, linked} =
               References.put_links(reference, [
                 {:work_experience, job.id},
                 {:work_experience, job.id}
               ])

      assert length(linked.links) == 1
    end

    # A member must not be able to hang their Zeugnis off somebody else's CV
    # entry — that would put their document on a stranger's profile.
    test "silently drops CV entries owned by somebody else", %{reference: reference} do
      stranger = insert(:user)
      their_job = insert(:work_experience, user: stranger)

      assert {:ok, linked} = References.put_links(reference, [{:work_experience, their_job.id}])
      assert linked.links == []
    end

    test "keeps the owned entries when a foreign one is mixed in", %{
      reference: reference,
      job: job
    } do
      stranger = insert(:user)
      their_job = insert(:work_experience, user: stranger)

      assert {:ok, linked} =
               References.put_links(reference, [
                 {:work_experience, job.id},
                 {:work_experience, their_job.id}
               ])

      assert [link] = linked.links
      assert Link.subject(link) == {:work_experience, job.id}
    end
  end

  describe "database integrity" do
    # The CHECK constraint is what actually holds the invariant; the schema
    # validation only turns it into a friendly error. Prove the constraint by
    # going around the changeset.
    test "refuses a link with no subject", %{reference: reference} do
      assert_raise Postgrex.Error, ~r/exactly_one_subject/, fn ->
        Repo.insert_all("job_reference_links", [
          %{
            id: Ecto.UUID.dump!(Vutuv.UUIDv7.generate()),
            job_reference_id: Ecto.UUID.dump!(reference.id),
            inserted_at: NaiveDateTime.utc_now(:second),
            updated_at: NaiveDateTime.utc_now(:second)
          }
        ])
      end
    end

    test "refuses a link with two subjects", %{reference: reference, job: job, school: school} do
      assert_raise Postgrex.Error, ~r/exactly_one_subject/, fn ->
        Repo.insert_all("job_reference_links", [
          %{
            id: Ecto.UUID.dump!(Vutuv.UUIDv7.generate()),
            job_reference_id: Ecto.UUID.dump!(reference.id),
            work_experience_id: Ecto.UUID.dump!(job.id),
            education_id: Ecto.UUID.dump!(school.id),
            inserted_at: NaiveDateTime.utc_now(:second),
            updated_at: NaiveDateTime.utc_now(:second)
          }
        ])
      end
    end

    test "deleting the CV entry removes the link, not the Zeugnis", %{
      reference: reference,
      job: job
    } do
      {:ok, _linked} = References.put_links(reference, [{:work_experience, job.id}])

      Repo.delete!(job)

      assert Repo.get(Vutuv.References.JobReference, reference.id)
      assert Repo.all(from(l in Link, where: l.job_reference_id == ^reference.id)) == []
    end

    test "deleting the Zeugnis removes its links", %{reference: reference, job: job} do
      {:ok, _linked} = References.put_links(reference, [{:work_experience, job.id}])

      {:ok, _deleted} = References.delete_job_reference(reference)

      assert Repo.all(from(l in Link, where: l.job_reference_id == ^reference.id)) == []
    end
  end

  describe "public_references_for/2" do
    test "lists only published Zeugnisse of that CV entry", %{user: user, job: job} do
      private = insert(:job_reference, user: user)

      public =
        insert(:job_reference,
          user: user,
          public?: true,
          public_consented_at: DateTime.utc_now(:second)
        )

      {:ok, _a} = References.put_links(private, [{:work_experience, job.id}])
      {:ok, _b} = References.put_links(public, [{:work_experience, job.id}])

      ids = :work_experience |> References.public_references_for(job.id) |> Enum.map(& &1.id)

      assert public.id in ids
      refute private.id in ids
    end

    # A document still in moderation limbo must not surface on a profile, even
    # when the member already ticked "public".
    test "hides a published Zeugnis whose document is still pending", %{user: user, job: job} do
      pending =
        insert(:job_reference,
          user: user,
          public?: true,
          public_consented_at: DateTime.utc_now(:second),
          document: "zeugnis.pdf",
          document_moderation: "pending"
        )

      {:ok, _linked} = References.put_links(pending, [{:work_experience, job.id}])

      assert References.public_references_for(:work_experience, job.id) == []
    end
  end
end
