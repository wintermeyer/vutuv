defmodule Vutuv.ModerationCopyrightTest do
  @moduledoc """
  The copyright complaint (issue #2008): the one report category that carries
  legal weight rather than house-rule weight, so it is only accepted as a
  complete notice, it reaches the admin queue the moment it is filed, and the
  owner cannot rewrite their way out of it.
  """

  use Vutuv.DataCase, async: true

  alias Vutuv.Moderation
  alias Vutuv.Moderation.{Case, Report}

  setup do
    owner = insert(:activated_user)
    insert(:email, user: owner)
    reporter = insert(:activated_user)
    insert(:email, user: reporter)
    {:ok, %{owner: owner, reporter: reporter}}
  end

  defp complete_notice(attrs \\ %{}) do
    Map.merge(
      %{
        "category" => "copyright",
        "note" => "The photo is mine, the original is at example.com/photo",
        "good_faith?" => "true"
      },
      attrs
    )
  end

  # A reporter with a bad track record: an admin marked one of their past
  # reports as abusive within the trust window.
  defp make_untrusted!(reporter) do
    post = insert(:post, user: insert(:activated_user))
    {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "spam"})
    admin = insert(:activated_user, admin?: true)
    report = Repo.get_by!(Report, case_id: case_record.id)
    {:ok, _} = Moderation.reject_case(case_record, admin, [report.id])
    reporter
  end

  describe "categories_for/1" do
    test "every content type but a private message offers the copyright notice" do
      for type <- ["post", "user", "organization", "job_posting"] do
        assert "copyright" in Report.categories_for(type),
               "#{type} should offer the copyright category"
      end
    end

    test "a private message does not offer it" do
      # Nothing was published, so there is nothing for a rights holder to have
      # taken down.
      refute "copyright" in Report.categories_for("message")
    end
  end

  describe "a complete notice" do
    test "needs the explanation", %{owner: owner, reporter: reporter} do
      post = insert(:post, user: owner)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Moderation.report_content(reporter, post, complete_notice(%{"note" => "  "}))

      assert %{note: _} = errors_on(changeset)
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "needs the good-faith declaration", %{owner: owner, reporter: reporter} do
      post = insert(:post, user: owner)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Moderation.report_content(
                 reporter,
                 post,
                 Map.delete(complete_notice(), "good_faith?")
               )

      assert %{good_faith?: _} = errors_on(changeset)
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "neither is demanded of the other categories", %{owner: owner, reporter: reporter} do
      post = insert(:post, user: owner)

      assert {:ok, %Case{}} =
               Moderation.report_content(reporter, post, %{"category" => "spam"})
    end
  end

  describe "the admin queue" do
    test "carries a copyright case from the moment it is filed", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)

      assert {:ok, %Case{status: "pending_owner"} = case_record} =
               Moderation.report_content(reporter, post, complete_notice())

      # The trust ladder is untouched: a trusted reporter still freezes the
      # content and still leaves the owner their 72h self-service window ...
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
      assert case_record.owner_deadline_at

      # ... but unlike every other category the case does not wait for that
      # window to run out before an admin sees it.
      assert case_record.id in Enum.map(Moderation.list_queue(), & &1.id)
      assert Moderation.open_queue_count() == 1
    end

    test "an untrusted reporter's notice is in the queue without a freeze", %{
      owner: owner,
      reporter: reporter
    } do
      make_untrusted!(reporter)
      post = insert(:post, user: owner)

      assert {:ok, %Case{status: "flagged"} = case_record} =
               Moderation.report_content(reporter, post, complete_notice())

      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
      assert case_record.id in Enum.map(Moderation.list_queue(), & &1.id)
    end

    test "a settled copyright case leaves the queue", %{owner: owner, reporter: reporter} do
      post = insert(:post, user: owner)
      {:ok, _} = Moderation.report_content(reporter, post, complete_notice())

      Moderation.content_deleted(post)

      assert Moderation.list_queue() == []
      assert Moderation.open_queue_count() == 0
    end

    test "an ordinary pending_owner case still waits for the owner", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      {:ok, _} = Moderation.report_content(reporter, post, %{"category" => "spam"})

      assert Moderation.list_queue() == []
      assert Moderation.open_queue_count() == 0
    end
  end

  describe "content_edited/1 on a copyright case" do
    test "does not lift the freeze but hands the case to an admin", %{
      owner: owner,
      reporter: reporter
    } do
      post = insert(:post, user: owner)
      {:ok, case_record} = Moderation.report_content(reporter, post, complete_notice())

      Moderation.content_edited(Repo.get!(Vutuv.Posts.Post, post.id))

      settled = Repo.get!(Case, case_record.id)
      assert settled.status == "escalated"
      assert settled.escalated_at
      # A rewrite is not an answer to "this is not yours to publish".
      assert Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end

    test "an ordinary case still unfreezes on an edit", %{owner: owner, reporter: reporter} do
      post = insert(:post, user: owner)
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "spam"})

      Moderation.content_edited(Repo.get!(Vutuv.Posts.Post, post.id))

      assert Repo.get!(Case, case_record.id).status == "resolved_edited"
      refute Repo.get!(Vutuv.Posts.Post, post.id).frozen_at
    end
  end
end
